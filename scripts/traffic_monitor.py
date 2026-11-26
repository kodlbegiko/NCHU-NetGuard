#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
中興大學 宿舍網路 (興大二村) 每日流量監控工具 (流量包) v3.1
- 讀取 NCHUTraffic 本機觀測用量；非校方計費
- 校方配額單位與計費邊界未驗證時，不推算剩餘流量
- 同步查詢 top100.nchu.edu.tw 官方榜單
"""

import sys
import os
import re
import subprocess
import selectors
import stat
import sqlite3
from pathlib import Path
import urllib.request
import urllib.error
import ssl
import json
import time
import argparse
from datetime import datetime, timezone, timedelta
from html.parser import HTMLParser
from urllib.parse import urlparse
import ipaddress
import unicodedata

STATE_FILE = os.path.expanduser("~/.nchu_traffic_state.json")
HISTORY_FILE = os.path.expanduser("~/.nchu_traffic_history.json")
HISTORY_DB = os.path.expanduser("~/Library/Application Support/NCHU-NetGuard/history.sqlite")

def get_today_string():
    return datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m-%d")

MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_PROBE_BYTES = 1024 * 1024
MAX_EXACT_BYTES = 9_007_199_254_740_991

def strict_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON field')
        result[key] = value
    return result

def reject_json_constant(_value):
    raise ValueError('non-finite JSON constant')

def valid_daily_counters(state):
    overflow = state.get('accounting_overflow', False)
    if type(overflow) is not bool or overflow:
        return False
    keys = ('dorm_in', 'dorm_out', 'wifi_in', 'wifi_out', 'ext_in', 'ext_out', 'unattributed_in', 'unattributed_out')
    aliases = {'dorm_in': 'today_in', 'dorm_out': 'today_out'}
    values = [state.get(key, state.get(aliases[key], 0) if key in aliases else 0) for key in keys]
    return all(type(value) is int and 0 <= value <= MAX_EXACT_BYTES for value in values) and sum(values) <= MAX_EXACT_BYTES

def safe_history_sidecars(path):
    # Preflight only: SQLite opens by pathname, so this is not race-free
    # protection against another process replacing a file after validation.
    for suffix in ('-wal', '-shm', '-journal'):
        try:
            info = path.with_name(path.name + suffix).lstat()
        except FileNotFoundError:
            continue
        except OSError:
            return False
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
            return False
    return True

def read_json_object(path):
    """No symlink, special-file or unbounded reads of local state."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                    info.st_uid != os.geteuid() or info.st_size > MAX_JSON_BYTES):
                return None
            raw = source.read(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                return None
        value = json.loads(raw, object_pairs_hook=strict_json_object,
                           parse_constant=reject_json_constant)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, RecursionError):
        return None

def valid_history_day(day):
    if not isinstance(day, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", day):
        return False
    try:
        datetime.strptime(day, "%Y-%m-%d")
        return True
    except ValueError:
        return False

def validated_legacy_history(raw):
    """Reject a corrupt legacy document rather than exposing raw keys or counts."""
    if not isinstance(raw, dict) or len(raw) > 36_600:
        return {}
    def valid_count(value):
        return type(value) is int and 0 <= value <= MAX_EXACT_BYTES
    result = {}
    for day, row in raw.items():
        if not valid_history_day(day):
            return {}
        if isinstance(row, dict):
            total = row.get("total")
            if not valid_count(total) or ("dl" in row) != ("ul" in row):
                return {}
            if "dl" in row:
                dl, ul = row["dl"], row["ul"]
                if not valid_count(dl) or not valid_count(ul) or dl + ul != total:
                    return {}
                result[day] = {"total": total, "dl": dl, "ul": ul}
            else:
                result[day] = {"total": total}
        elif valid_count(row):
            result[day] = row
        else:
            return {}
    return {day: result[day] for day in sorted(result, reverse=True)[:366]}

def load_history():
    """Use finalized SQLite history; never create or alter the active store."""
    path = Path(HISTORY_DB)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return validated_legacy_history(read_json_object(HISTORY_FILE))
    except OSError:
        return {}
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_size > 64 * 1024 * 1024:
        return {}
    if not safe_history_sidecars(path):
        return {}
    connection = None
    try:
        connection = sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=.25)
        deadline = time.monotonic() + 1
        connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if version not in (1, 2, 3):
            return {}
        kind = connection.execute("SELECT type FROM sqlite_master WHERE name='history_days'").fetchone()
        if kind != ("table",):
            return {}
        rows = connection.execute("SELECT day,total,download,upload FROM history_days ORDER BY day DESC LIMIT 366")
        history = {}
        for day, total, dl, ul in rows:
            if not valid_history_day(day):
                return {}
            if day in history or type(total) is not int or not 0 <= total <= MAX_EXACT_BYTES:
                return {}
            if (dl is None) != (ul is None) or (dl is not None and
                    (type(dl) is not int or type(ul) is not int or min(dl, ul) < 0 or dl + ul != total)):
                return {}
            history[day] = {"total": total, "dl": dl, "ul": ul}
        return history
    except (OSError, ValueError, sqlite3.Error):
        return {}
    finally:
        if connection is not None:
            connection.close()

def load_state():
    data = read_json_object(STATE_FILE)
    if data is not None and data.get("date") == get_today_string() and type(data.get("schema_version", 1)) is int and data.get("schema_version", 1) == 1:
        return data
    return None

def run_probe(argv, timeout, max_bytes=MAX_PROBE_BYTES):
    """Bound stdout, wall-clock wait, and direct-child lifetime; no shell."""
    deadline = time.monotonic() + timeout
    with subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                result = bytearray()
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise TimeoutError("probe timed out")
                    chunk = os.read(proc.stdout.fileno(), min(65536, max_bytes + 1 - len(result)))
                    if not chunk:
                        break
                    result.extend(chunk)
                    if len(result) > max_bytes:
                        raise ValueError("probe output exceeds limit")
            if proc.wait(timeout=max(0, deadline - time.monotonic())) != 0:
                raise OSError("probe failed")
            return result.decode("utf-8", errors="strict")
        finally:
            if proc.poll() is None:
                proc.kill()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def parse_top_apps(output):
    """Bounded, process-lifetime snapshot. No raw control or bidi characters."""
    if not isinstance(output, str) or len(output.encode("utf-8", errors="replace")) > MAX_PROBE_BYTES:
        return []
    limit = 2**64 - 1
    by_pid = {}
    ambiguous = set()
    for line in output.split("\n"):
        parts = line.rstrip("\r").split(",")
        if len(parts) == 4 and parts[-1] == "":
            parts.pop()
        if len(parts) != 3:
            continue
        match = re.fullmatch(r"(.+)\.([1-9][0-9]{0,9})", parts[0].strip(" \t"))
        if not match:
            continue
        name, pid = match.groups()
        if int(pid) > 2**31 - 1:
            continue
        if pid not in by_pid and pid not in ambiguous and len(by_pid) + len(ambiguous) >= 4096:
            return []
        if pid in by_pid or pid in ambiguous:
            ambiguous.add(pid)
            by_pid.pop(pid, None)
            continue
        if len(name.encode("utf-8", errors="replace")) > 128 or any(
                unicodedata.category(c).startswith("C") or unicodedata.category(c) in ("Zl", "Zp") for c in name):
            ambiguous.add(pid)
            continue
        if not all(re.fullmatch(r"[0-9]{1,20}", x) for x in parts[1:]):
            ambiguous.add(pid)
            continue
        rx, tx = map(int, parts[1:])
        if rx > limit or tx > limit or rx + tx > limit:
            ambiguous.add(pid)
            continue
        by_pid[pid] = (name, rx + tx)
    totals = {}
    overflow = set()
    for name, count in by_pid.values():
        if name in overflow:
            continue
        value = totals.get(name, 0) + count
        if value > limit:
            overflow.add(name)
            totals.pop(name, None)
        else:
            totals[name] = value
    return sorted(((name, total) for name, total in totals.items() if total > 50 * 1024),
                  key=lambda row: (-row[1], row[0]))[:5]

def get_top_apps():
    try:
        out = run_probe(["/usr/bin/nettop", "-P", "-L", "1", "-J", "bytes_in,bytes_out"], timeout=10)
        return parse_top_apps(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return []

class RankingParser(HTMLParser):
    """Bounded explicit row/cell structure; reject ambiguous nested markup."""
    MAX_ROWS = 4096
    MAX_CELLS = 32
    MAX_CELL_CHARS = 1024

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self.row = None
        self.cell = None
        self.cell_tag = None
        self.cell_chars = 0
        self.row_spanned = False
        self.invalid = False

    def handle_starttag(self, tag, attrs):
        if self.invalid:
            return
        if tag == "tr":
            if self.row is not None or len(self.rows) >= self.MAX_ROWS:
                self.invalid = True
                return
            self.row = []
            self.row_spanned = False
            if any(key == "hidden" or (key == "aria-hidden" and value == "true") for key, value in attrs):
                self.invalid = True
        elif tag in ("td", "th"):
            if self.row is None or self.cell is not None or len(self.row) >= self.MAX_CELLS:
                self.invalid = True
                return
            if any(key == "hidden" or (key == "aria-hidden" and value == "true") or
                   (key == "rowspan" and value != "1") for key, value in attrs):
                self.invalid = True
                return
            if any(key == "colspan" and value != "1" for key, value in attrs):
                self.row_spanned = True
            self.cell, self.cell_tag, self.cell_chars = [], tag, 0
        elif self.row is not None and (tag in ("table", "script", "style", "template", "noscript", "iframe", "object") or
                any(key == "hidden" or (key == "aria-hidden" and value == "true") for key, value in attrs)):
            self.invalid = True
        elif tag == "br" and self.cell is not None:
            self.handle_data(" ")

    def handle_data(self, data):
        if self.invalid or self.cell is None:
            return
        self.cell_chars += len(data)
        if self.cell_chars > self.MAX_CELL_CHARS:
            self.invalid = True
            return
        self.cell.append(data)

    def handle_endtag(self, tag):
        if self.invalid:
            return
        if tag in ("td", "th"):
            if self.row is None or self.cell is None or tag != self.cell_tag:
                self.invalid = True
                return
            self.row.append("".join(self.cell).strip())
            self.cell, self.cell_tag, self.cell_chars = None, None, 0
        elif tag == "tr":
            if self.row is None or self.cell is not None:
                self.invalid = True
                return
            # Keep original identity cell positions; a spanned row cannot
            # accidentally be accepted as six separate cells.
            self.rows.append(self.row + ([""] * 7 if self.row_spanned else []))
            self.row = None

    @property
    def complete(self):
        return not self.invalid and self.row is None and self.cell is None


def valid_ranking_row(row):
    return len(row) == 6 and re.fullmatch(r"[1-9][0-9]{0,5}", row[0]) is not None and all(
        len(value.encode("utf-8")) <= 32 and
        re.fullmatch(r"[0-9]{1,12}(?:\.[0-9]{1,6})? *(?:B|KB|MB|GB|TB)", value, re.I | re.ASCII) is not None
        for value in row[3:])

def parse_ranking(html, ip_addr):
    """Provisional six-column format; absence is never a safety decision."""
    def unknown(code, status="not_found_or_unrecognized"):
        return {"status": status, "in_top1000": None, "error_code": code}
    try:
        target = ipaddress.ip_address(ip_addr)
    except ValueError:
        return unknown("invalid_identity", "invalid_identity")
    if not isinstance(html, str) or len(html) > 2_000_000:
        return unknown("response_limit", "unavailable")
    parser = RankingParser()
    parser.feed(html)
    parser.close()
    if not parser.complete:
        return unknown("unrecognized_ranking")
    identity_rows = []
    recognized = 0
    for row in parser.rows:
        if len(row) < 3:
            continue
        try:
            address = ipaddress.ip_address(row[2])
        except ValueError:
            continue
        if address == target:
            identity_rows.append(row)
        if valid_ranking_row(row):
            recognized += 1
    if len(identity_rows) > 1:
        return unknown("ambiguous_identity")
    if not identity_rows:
        return unknown("not_listed" if recognized else "unrecognized_ranking")
    row = identity_rows[0]
    if not valid_ranking_row(row):
        return unknown("malformed_row")
    return {"status": "listed", "in_top1000": True,
            "rank": int(row[0]), "download_display": row[3],
            "upload_display": row[4], "total_display": row[5],
            "units_verified": False}


def get_top100_data(ip_addr):
    today = get_today_string()
    url = f"https://top100.nchu.edu.tw/nchubody2.php?date={today}"
    def failed(code):
        return {"in_top1000": None, "status": "unavailable", "error_code": code}
    try:
        ctx = ssl.create_default_context()
        req = urllib.request.Request(url, headers={"User-Agent": "NCHU-NetGuard/4.0"})
        opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ctx))
        with opener.open(req, timeout=3) as response:
            if response.geturl() != url or response.status != 200:
                return failed("unexpected_response")
            raw = response.read(2_000_001)
            if len(raw) > 2_000_000:
                return failed("response_limit")
            try:
                html = raw.decode("utf-8")
            except UnicodeDecodeError:
                try:
                    html = raw.decode("big5", errors="strict")
                except UnicodeDecodeError:
                    return failed("invalid_encoding")
            result = parse_ranking(html, ip_addr)
            result["requested_date"] = today
            result["retrieved_at"] = datetime.now(timezone.utc).isoformat()
            return result
    except urllib.error.HTTPError as exc:
        return failed("rate_limited" if exc.code == 429 else ("redirect_rejected" if 300 <= exc.code < 400 else "http_error"))
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, ssl.SSLError):
            return failed("tls_error")
        if isinstance(exc.reason, TimeoutError):
            return failed("timeout")
        return failed("network_error")
    except ssl.SSLError:
        return failed("tls_error")
    except TimeoutError:
        return failed("timeout")
    except OSError:
        return failed("network_error")
    except Exception:
        return failed("unexpected_response")

def format_bytes(b):
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024**3):.2f} GiB"
    elif b >= 1024 * 1024:
        return f"{b / (1024**2):.2f} MiB"
    elif b >= 1024:
        return f"{b / 1024:.2f} KiB"
    else:
        return f"{b:.0f} B"

def print_progress_bar(used, total, length=30):
    ratio = min(max(used / total, 0.0), 1.0)
    filled_len = int(length * ratio)
    bar = "█" * filled_len + "░" * (length - filled_len)
    pct = ratio * 100
    
    if ratio > 0.85:
        c = "\033[91m"
    elif ratio > 0.65:
        c = "\033[93m"
    else:
        c = "\033[92m"
    reset = "\033[0m"
    
    return f"{c}[{bar}] {pct:5.1f}%{reset}"

def default_ipv4_interface(output):
    """Accept exactly one bounded numeric default-route interface observation."""
    if not isinstance(output, str) or len(output.encode("utf-8", errors="replace")) > 65536:
        return None
    names = []
    for line in output.splitlines():
        key, sep, value = line.strip().partition(":")
        if not sep:
            continue
        if key.strip() == "interface":
            names.append(value.strip())
        if key.strip() == "flags" and set(re.split(r"[,<>\s]+", value)) & {"REJECT", "BLACKHOLE"}:
            return None
    if len(names) != 1 or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,31}", names[0]):
        return None
    return names[0]

def query_traffic(scope=None):
    def unknown_network():
        return {"schema_version": 1, "status": "network_unknown",
                "top100": {"status": "unavailable", "in_top1000": None}}
    try:
        route_out = run_probe(["/sbin/route", "-n", "get", "-inet", "default"], timeout=3, max_bytes=65536)
        iface = default_ipv4_interface(route_out)
        if iface is None:
            return unknown_network()
        ip_out = run_probe(["/usr/sbin/ipconfig", "getifaddr", iface], timeout=3, max_bytes=4096).strip()
        address = ipaddress.IPv4Address(ip_out)
        if (str(address) != ip_out or address.is_unspecified or address.is_loopback or
                address.is_multicast or address.is_link_local or address.is_reserved):
            return unknown_network()
        ip = str(address)
    except (OSError, ValueError, subprocess.SubprocessError):
        return unknown_network()

    state = load_state()
    campus_candidate = address in ipaddress.ip_network("140.120.0.0/16")
    # A campus address alone does not distinguish campus Wi-Fi from a dorm.
    top100 = get_top100_data(ip) if campus_candidate else {"in_top1000": None, "status": "not_applicable"}
    unknown = {"schema_version": 1, "status": "local_usage_unknown", "date": get_today_string(),
               "iface": iface, "ip": ip, "top100": top100}
    if state is None or not valid_daily_counters(state) or scope is None:
        # Keep ranking observations available to the Swift caller independently
        # of local scope attribution. Do not guess a dorm quota from an IP.
        return unknown
    selected = scope
    prefix = {"dorm": "dorm", "campus_wifi": "wifi", "external": "ext"}.get(selected)
    if prefix is None:
        return unknown
    # A present zero counter is not proof of a measured interval. Older state
    # without an affirmative coverage marker stays unknown, including explicit scope.
    observed = state.get("observed_scopes")
    scope_label = {"dorm": "dorm", "campus_wifi": "campusWifi", "external": "external"}[selected]
    measured = state.get("measured_sample_count")
    if (state.get("scoped_history_eligible") is not True or
            type(measured) is not int or not 0 < measured <= 9_007_199_254_740_991 or
            not isinstance(observed, list) or len(observed) > 3 or
            any(not isinstance(x, str) or x not in ("dorm", "campusWifi", "external") for x in observed) or
            len(set(observed)) != len(observed) or scope_label not in observed):
        return unknown
    local_in = state.get(prefix + "_in")
    local_out = state.get(prefix + "_out")
    if any(type(value) is not int or not 0 <= value <= MAX_EXACT_BYTES for value in (local_in, local_out)):
        return unknown
    local_total = local_in + local_out
    if local_total > MAX_EXACT_BYTES:
        return unknown
    is_dorm = selected == "dorm"
    in_bytes, out_bytes, total_bytes = local_in, local_out, local_total
    # Published G limits do not yet establish bytes-per-G. Do not produce a
    # provider balance; the CLI reports the selected local accounting bucket.
    total_quota_bytes = dl_quota_bytes = ul_quota_bytes = None
    rem_total_bytes = rem_dl_bytes = rem_ul_bytes = None
    
    return {
        "schema_version": 1,
        "status": "local_estimate",
        "date": get_today_string(),
        "iface": iface,
        "ip": ip,
        "is_dorm": is_dorm,
        "scope": selected,
        "scope_user_selected": scope is not None,
        "quota_units_verified": False,
        "time": time.strftime('%Y-%m-%d %H:%M:%S'),
        "total_quota": total_quota_bytes,
        "dl_quota": dl_quota_bytes,
        "ul_quota": ul_quota_bytes,
        "used_total": total_bytes,
        "used_dl": in_bytes,
        "used_ul": out_bytes,
        "rem_total": rem_total_bytes,
        "rem_dl": rem_dl_bytes,
        "rem_ul": rem_ul_bytes,
        "top100": top100
    }

def display_report(scope=None):
    data = query_traffic(scope)
    if data.get("status") == "network_unknown":
        print("網路狀態未知；無法可靠估計配額。")
        return
    if data.get("status") == "local_usage_unknown":
        print("本機用量或網路歸屬未知；不估算校方剩餘配額。")
        if scope is None:
            print("如要查詢本機帳本，請指定 --scope dorm、campus_wifi 或 external。")
        ranking = data.get("top100", {})
        if ranking.get("status") == "listed":
            print(f"校方榜單第 {ranking['rank']} 名（單位與統計時間未驗證）")
        return
    top_apps = get_top_apps()
    history = load_history()
    
    is_dorm = data['is_dorm']
    net_type = {"dorm": "宿網觀測分類", "campus_wifi": "校園 Wi-Fi 觀測分類", "external": "外部網路觀測分類"}[data["scope"]]
    
    print("\033[1;36m============================================================\033[0m")
    print(f"\033[1;37m   🌐 網路流量監控工具 v3.2 - 【{net_type}】               \033[0m")
    print("\033[1;36m============================================================\033[0m")
    print(f" 📍 當前 IP 位址: \033[1;33m{data['ip']}\033[0m (介面: {data['iface']} • {net_type})")
    print(f" 📅 今日日期:     \033[1;32m{data['date']}\033[0m (本機日期，非校方重設證明)")
    print(f" 🕒 查詢時間:     {data['time']}")
    print(f" 本機觀測分類：{data['scope']}（非校方計費）")
    print(f" 今日觀測總量：{format_bytes(data['used_total'])}")
    print(f" 下載：{format_bytes(data['used_dl'])} / 上傳：{format_bytes(data['used_ul'])}")
    print(" 實際剩餘配額：未知（政策計量單位、計費邊界尚未確認）")
    
    # Top Apps
    if top_apps:
        print(" 📱 \033[1m程序觀測快照（非今日累計）:\033[0m")
        for idx, (app_name, b_val) in enumerate(top_apps[:4], 1):
            print(f"    {idx}. {app_name:<20}: {format_bytes(b_val)}")
        print("\033[1;36m------------------------------------------------------------\033[0m")
        
    # 近期歷史
    if history:
        print(" 📅 \033[1m近期歷史紀錄:\033[0m")
        for d in sorted(history.keys())[-3:]:
            rec = history[d]
            total_b = rec.get("total") if isinstance(rec, dict) else rec
            if type(total_b) is not int or not 0 <= total_b <= MAX_EXACT_BYTES:
                continue
            print(f"    • {d}: {format_bytes(total_b)}")
        print("\033[1;36m------------------------------------------------------------\033[0m")
        
    if not data['ip'].startswith("140.120."):
        print(" 💡 \033[1;32m目前網路歸屬及實際配額請向服務提供者確認。\033[0m")
    elif data['top100'].get("in_top1000"):
        rank = data['top100'].get("rank")
        print(f" ⚠️  \033[1;33m校內 Top 1000 狀態: 已列入榜單第 {rank} 名\033[0m")
    else:
        print(" ⚠️ \033[1;33m校內榜單：未取得可驗證的匹配資料，狀態未知\033[0m")
        
    # No billing-risk claim can be derived from local bytes alone.
        
    print("\033[1;36m============================================================\033[0m")

def main():
    parser = argparse.ArgumentParser(description="NetGuard local traffic estimates")
    parser.add_argument("--json", action="store_true", help="Emit versioned JSON without ANSI escapes")
    parser.add_argument("--scope", choices=["dorm", "campus_wifi", "external"],
                        help="Select a local accounting bucket, not a verified network identity")
    args = parser.parse_args()
    if args.json:
        print(json.dumps(query_traffic(args.scope), ensure_ascii=False, allow_nan=False))
    else:
        display_report(args.scope)

if __name__ == "__main__":
    main()
