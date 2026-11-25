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
    default_state = {
        "date": today,
        "today_in": 0.0,
        "today_out": 0.0
    }
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if data.get("date") == today:
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
    for row in parser.rows:
        if len(row) != 6 or row[2] != target or not re.fullmatch(r"[1-9][0-9]{0,5}", row[0]):
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

def query_traffic():
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
    is_dorm = ip.startswith("140.120.")
    if is_dorm:
        local_in = state.get("dorm_in", state.get("today_in", 0.0))
        local_out = state.get("dorm_out", state.get("today_out", 0.0))
    else:
        local_in = state.get("ext_in", 0.0)
        local_out = state.get("ext_out", 0.0)
    local_total = local_in + local_out
    
    top100 = get_top100_data(ip) if is_dorm else {"in_top1000": None, "status": "not_applicable"}
    
    in_bytes, out_bytes, total_bytes = local_in, local_out, local_total
    
    total_quota_bytes = TOTAL_QUOTA_GB * (1024**3)
    dl_quota_bytes = DL_QUOTA_GB * (1024**3)
    ul_quota_bytes = UL_QUOTA_GB * (1024**3)
    
    rem_total_bytes = max(0, total_quota_bytes - total_bytes)
    rem_dl_bytes = max(0, dl_quota_bytes - in_bytes)
    rem_ul_bytes = max(0, ul_quota_bytes - out_bytes)
    
    return {
        "schema_version": 1,
        "status": "local_estimate",
        "date": get_today_string(),
        "iface": iface,
        "ip": ip,
        "is_dorm": is_dorm,
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

def display_report():
    data = query_traffic()
    if data.get("status") == "network_unknown":
        print("網路狀態未知；無法可靠估計配額。")
        return
    top_apps = get_top_apps()
    history = load_history()
    
    is_dorm = data['is_dorm']
    net_type = "興大二村宿網" if is_dorm else ("iPhone 個人熱點" if data['ip'].startswith("172.20.10.") else "外部網路 / Wi-Fi")
    
    print("\033[1;36m============================================================\033[0m")
    print(f"\033[1;37m   🌐 網路流量監控工具 v3.2 - 【{net_type}】               \033[0m")
    print("\033[1;36m============================================================\033[0m")
    print(f" 📍 當前 IP 位址: \033[1;33m{data['ip']}\033[0m (介面: {data['iface']} • {net_type})")
    print(f" 📅 今日日期:     \033[1;32m{data['date']}\033[0m (每日 00:00 自動歸零重設)")
    print(f" 🕒 查詢時間:     {data['time']}")
    if is_dorm:
        print(f" 🏫 校方每日限額: 總額 {TOTAL_QUOTA_GB:.0f} GB (下載 {DL_QUOTA_GB:.0f} GB / 上傳 {UL_QUOTA_GB:.0f} GB)")
        print("\033[1;36m------------------------------------------------------------\033[0m")
        # 總流量
        print(f" 📊 \033[1m今日總流量剩餘: \033[1;32m{format_bytes(data['rem_total'])}\033[0m / {TOTAL_QUOTA_GB:.0f} GB")
        print(f"    今日已使用: {format_bytes(data['used_total'])}")
        print(f"    {print_progress_bar(data['used_total'], data['total_quota'], 32)}")
        print("")
        
        # 下載
        print(f" 📥 \033[1m今日下載剩餘:   \033[1;32m{format_bytes(data['rem_dl'])}\033[0m / {DL_QUOTA_GB:.0f} GB")
        print(f"    今日已下載: {format_bytes(data['used_dl'])}")
        print(f"    {print_progress_bar(data['used_dl'], data['dl_quota'], 32)}")
        print("")
        
        # 上傳
        print(f" 📤 \033[1m今日上傳剩餘:   \033[1;32m{format_bytes(data['rem_ul'])}\033[0m / {UL_QUOTA_GB:.0f} GB")
        print(f"    今日已上傳: {format_bytes(data['used_ul'])}")
        print(f"    {print_progress_bar(data['used_ul'], data['ul_quota'], 32)}")
    else:
        print(f" 📶 網路環境模式: \033[1;32m非宿舍或未確認網路（配額未確認）\033[0m")
        print("\033[1;36m------------------------------------------------------------\033[0m")
        print(f" 📊 \033[1m今日非宿網傳輸總量: \033[1;36m{format_bytes(data['used_total'])}\033[0m (\033[1;32m配額未確認\033[0m)")
        print(f"    📥 今日下載: {format_bytes(data['used_dl'])}")
        print(f"    📤 今日上傳: {format_bytes(data['used_ul'])}")
        print(f" 💡 說明: 本機統計不等同網路提供者的計費或管制紀錄。")
    print("\033[1;36m------------------------------------------------------------\033[0m")
    
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
        
    usage_pct = (data['used_total'] / data['total_quota']) * 100
    if usage_pct < 60:
        print(" 💡 \033[32m本機估計用量較低；實際校方配額仍需確認。\033[0m")
    elif usage_pct < 85:
        print(" 💡 \033[33m今日流量已過半，請注意避免進行大型遊戲/大型檔案下載。\033[0m")
    else:
        print(" 🚨 \033[1;31m警告：今日剩餘流量偏低！請暫停高頻寬操作以防被限速。\033[0m")
        
    print("\033[1;36m============================================================\033[0m")

def main():
    parser = argparse.ArgumentParser(description="NetGuard local traffic estimates")
    parser.add_argument("--json", action="store_true", help="Emit versioned JSON without ANSI escapes")
    args = parser.parse_args()
    if args.json:
        print(json.dumps(query_traffic(), ensure_ascii=False, allow_nan=False))
    else:
        display_report()

if __name__ == "__main__":
    main()
