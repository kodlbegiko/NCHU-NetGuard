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

STATE_FILE = os.path.expanduser("~/.nchu_traffic_state.json")
HISTORY_FILE = os.path.expanduser("~/.nchu_traffic_history.json")
HISTORY_DB = os.path.expanduser("~/Library/Application Support/NCHU-NetGuard/history.sqlite")

def get_today_string():
    return datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m-%d")

MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_PROBE_BYTES = 1024 * 1024

def read_json_object(path):
    """No symlink, special-file or unbounded reads of local state."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_JSON_BYTES:
                return None
            raw = source.read(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                return None
        value = json.loads(raw)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, RecursionError):
        return None

def load_history():
    """Use finalized SQLite history; never create or alter the active store."""
    path = Path(HISTORY_DB)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return read_json_object(HISTORY_FILE) or {}
    except OSError:
        return {}
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_size > 64 * 1024 * 1024:
        return {}
    connection = None
    try:
        connection = sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=.25)
        deadline = time.monotonic() + 1
        connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if version not in (1, 2):
            return {}
        kind = connection.execute("SELECT type FROM sqlite_master WHERE name='history_days'").fetchone()
        if kind != ("table",):
            return {}
        rows = connection.execute("SELECT day,total,download,upload FROM history_days ORDER BY day DESC LIMIT 366")
        history = {}
        for day, total, dl, ul in rows:
            if not isinstance(day, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
                return {}
            datetime.strptime(day, "%Y-%m-%d")
            if day in history or type(total) is not int or total < 0:
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

def get_top_apps():
    try:
        out = run_probe(["/usr/bin/nettop", "-P", "-L", "1", "-J", "bytes_in,bytes_out"], timeout=5)
        app_map = {}
        for line in out.splitlines():
            parts = line.strip().split(',')
            if len(parts) >= 3 and parts[1].isdigit() and parts[2].isdigit():
                raw_name = parts[0]
                name = re.sub(r'\.\d+$', '', raw_name)
                if name.startswith("Google Chrome"):
                    name = "Google Chrome"
                elif name.startswith("Antigravity"):
                    name = "Antigravity IDE"
                b_in = int(parts[1])
                b_out = int(parts[2])
                total = b_in + b_out
                if total > 50 * 1024:
                    app_map[name] = app_map.get(name, 0) + total
        sorted_apps = sorted(app_map.items(), key=lambda x: x[1], reverse=True)[:5]
        return sorted_apps
    except Exception:
        return []

class RankingParser(HTMLParser):
    """Collect cells within a single row; never match across rows."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row, self.cell = [], None
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.row is not None and self.cell is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row, self.cell = None, None


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
        if len(row) == 6 and re.fullmatch(r"[1-9][0-9]{0,5}", row[0]) and all(
                re.fullmatch(r"[0-9]{1,12}(?:\.[0-9]{1,6})? *(?:B|KB|MB|GB|TB)", value, re.I)
                for value in row[3:]):
            recognized += 1
    if len(identity_rows) > 1:
        return unknown("ambiguous_identity")
    if not identity_rows:
        return unknown("not_listed" if recognized else "unrecognized_ranking")
    row = identity_rows[0]
    if len(row) != 6 or not re.fullmatch(r"[1-9][0-9]{0,5}", row[0]) or not all(
            re.fullmatch(r"[0-9]{1,12}(?:\.[0-9]{1,6})? *(?:B|KB|MB|GB|TB)", value, re.I)
            for value in row[3:]):
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

def query_traffic(scope=None):
    iface = ""
    ip = ""
    try:
        route_out = run_probe(["/sbin/route", "get", "default"], timeout=3)
        for line in route_out.splitlines():
            if "interface:" in line:
                iface = line.split(":")[1].strip()
                break
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,31}", iface):
            raise ValueError("No default interface")
        ip_out = run_probe(["/usr/sbin/ipconfig", "getifaddr", iface], timeout=3).strip()
        if ip_out:
            ip = ip_out
    except Exception:
        pass

    state = load_state()
    if not ip:
        return {"schema_version": 1, "status": "network_unknown", "top100": {"status": "unavailable", "in_top1000": None}}
    try:
        campus_candidate = ipaddress.ip_address(ip) in ipaddress.ip_network("140.120.0.0/16")
    except ValueError:
        return {"schema_version": 1, "status": "network_unknown", "top100": {"status": "unavailable", "in_top1000": None}}
    # A campus address alone does not distinguish campus Wi-Fi from a dorm.
    top100 = get_top100_data(ip) if campus_candidate else {"in_top1000": None, "status": "not_applicable"}
    unknown = {"schema_version": 1, "status": "local_usage_unknown", "date": get_today_string(),
               "iface": iface, "ip": ip, "top100": top100}
    if state is None or state.get("accounting_overflow") is True or (scope is None and campus_candidate):
        # Keep ranking observations available to the Swift caller independently
        # of local scope attribution. Do not guess a dorm quota from an IP.
        return unknown
    selected = scope or "external"
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
    if any(type(value) is not int or not 0 <= value <= 2**64 - 1 for value in (local_in, local_out)):
        return unknown
    local_total = local_in + local_out
    if local_total > 2**64 - 1:
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
            if type(total_b) is not int or not 0 <= total_b <= 2**64 - 1:
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
