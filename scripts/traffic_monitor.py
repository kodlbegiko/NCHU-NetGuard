#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
中興大學 宿舍網路 (興大二村) 每日流量監控工具 (流量包) v3.1
- 讀取由 NCHUTraffic 原生守護進程精準統計的今日用量
- 依據 11GB 總限額 (下載 7GB / 上傳 4GB) 計算當日剩餘流量
- 同步查詢 top100.nchu.edu.tw 官方榜單
"""

import sys
import os
import re
import subprocess
import urllib.request
import ssl
import json
import time
import argparse
from datetime import datetime, timezone, timedelta
from html.parser import HTMLParser
from urllib.parse import urlparse
import ipaddress

TOTAL_QUOTA_GB = 11.0
DL_QUOTA_GB = 7.0
UL_QUOTA_GB = 4.0

STATE_FILE = os.path.expanduser("~/.nchu_traffic_state.json")
HISTORY_FILE = os.path.expanduser("~/.nchu_traffic_history.json")

def get_today_string():
    return datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m-%d")

def load_history():
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def load_state():
    today = get_today_string()
    default_state = None
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and data.get("date") == today and data.get("schema_version", 1) == 1:
                    return data
        except Exception:
            pass
    return default_state

def get_top_apps():
    try:
        out = subprocess.check_output(["nettop", "-P", "-L", "1", "-J", "bytes_in,bytes_out"], text=True, timeout=5)
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
    """Provisional legacy six-column format; no authoritative byte conversion."""
    try:
        target = str(ipaddress.ip_address(ip_addr))
    except ValueError:
        return {"status": "invalid_identity", "in_top1000": None}
    parser = RankingParser()
    parser.feed(html)
    matches = []
    identity_rows = [row for row in parser.rows if len(row) >= 3 and row[2] == target]
    if len(identity_rows) != 1:
        return {"status": "not_found_or_unrecognized", "in_top1000": None}
    for row in identity_rows:
        if len(row) != 6 or not re.fullmatch(r"[1-9][0-9]{0,5}", row[0]):
            continue
        values = []
        for field in row[3:]:
            match = re.fullmatch(r"([0-9]{1,12}(?:\.[0-9]{1,6})?)\s*(B|KB|MB|GB|TB)", field, re.I)
            if not match:
                break
            values.append(field)
        if len(values) == 3:
            matches.append({"status": "listed", "in_top1000": True,
                            "rank": int(row[0]), "download_display": values[0],
                            "upload_display": values[1], "total_display": values[2],
                            "units_verified": False})
    if len(matches) != 1:
        return {"status": "not_found_or_unrecognized", "in_top1000": None}
    return matches[0]


def get_top100_data(ip_addr):
    today = get_today_string()
    url = f"https://top100.nchu.edu.tw/nchubody2.php?date={today}"
    ctx = ssl.create_default_context()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "NCHU-NetGuard/4.0"})
        with urllib.request.urlopen(req, context=ctx, timeout=3) as response:
            final = urlparse(response.geturl())
            if final.scheme != "https" or final.hostname != "top100.nchu.edu.tw" or response.status != 200:
                return {"in_top1000": None, "status": "unavailable"}
            raw = response.read(2_000_001)
            if len(raw) > 2_000_000:
                return {"in_top1000": None, "status": "unavailable"}
            try:
                html = raw.decode("utf-8")
            except UnicodeDecodeError:
                html = raw.decode("big5", errors="strict")
            result = parse_ranking(html, ip_addr)
            result["requested_date"] = today
            result["retrieved_at"] = datetime.now(timezone.utc).isoformat()
            return result
    except Exception:
        return {"in_top1000": None, "status": "unavailable"}

def format_bytes(b):
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024**3):.2f} GB"
    elif b >= 1024 * 1024:
        return f"{b / (1024**2):.2f} MB"
    elif b >= 1024:
        return f"{b / 1024:.2f} KB"
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
        route_out = subprocess.check_output(["route", "get", "default"], text=True, timeout=3)
        for line in route_out.splitlines():
            if "interface:" in line:
                iface = line.split(":")[1].strip()
                break
        if not iface:
            raise ValueError("No default interface")
        ip_out = subprocess.check_output(["ipconfig", "getifaddr", iface], text=True, timeout=3).strip()
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
    if state is None or (scope is None and campus_candidate):
        # Keep ranking observations available to the Swift caller independently
        # of local scope attribution. Do not guess a dorm quota from an IP.
        return unknown
    selected = scope or "external"
    prefix = {"dorm": "dorm", "campus_wifi": "wifi", "external": "ext"}.get(selected)
    if prefix is None:
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
    print(f" 📅 今日日期:     \033[1;32m{data['date']}\033[0m (每日 00:00 自動歸零重設)")
    print(f" 🕒 查詢時間:     {data['time']}")
    print(f" 本機觀測分類：{data['scope']}（非校方計費）")
    print(f" 今日觀測總量：{format_bytes(data['used_total'])}")
    print(f" 下載：{format_bytes(data['used_dl'])} / 上傳：{format_bytes(data['used_ul'])}")
    print(" 實際剩餘配額：未知（政策計量單位、計費邊界尚未確認）")
    
    # Top Apps
    if top_apps:
        print(" 📱 \033[1m今日耗流最高的應用程式 (Top Consumers):\033[0m")
        for idx, (app_name, b_val) in enumerate(top_apps[:4], 1):
            print(f"    {idx}. {app_name:<20}: {format_bytes(b_val)}")
        print("\033[1;36m------------------------------------------------------------\033[0m")
        
    # 近期歷史
    if history:
        print(" 📅 \033[1m近期歷史紀錄:\033[0m")
        for d in sorted(history.keys())[-3:]:
            rec = history[d]
            total_b = rec.get("total", 0) if isinstance(rec, dict) else rec
            print(f"    • {d}: {format_bytes(total_b)}")
        print("\033[1;36m------------------------------------------------------------\033[0m")
        
    if not data['ip'].startswith("140.120."):
        print(" 💡 \033[1;32m目前網路歸屬及實際配額請向服務提供者確認。\033[0m")
    elif data['top100'].get("in_top1000"):
        rank = data['top100'].get("rank")
        print(f" ⚠️  \033[1;33m校內 Top 1000 狀態: 已列入榜單第 {rank} 名\033[0m")
    else:
        print(" ✅ \033[1;32m校內榜單：未取得可驗證的匹配資料，狀態未知\033[0m")
        
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
