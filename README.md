# NCHU-NetGuard (興大宿網守護者)

[![macOS](https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=flat&logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Language-Swift%205.9%2B-orange?style=flat&logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

專為**中興大學（NCHU）宿舍網路**（特別是二村等每日限額 11GB 配額環境）設計的 macOS 原生常駐狀態列管理與網路防護工具。

提供**精準流量監控**、**雙網卡智慧雙軌分流（Split Tunneling）**、**計中黑名單/超流自動預警**、**P2P 違規進程攔截**，以及**闔蓋/閒置智慧流量防護（Lid & Idle Guard）**。

---

## ✨ 核心特色 (Key Features)

### 1. 📊 精準流量統計與配額預警
- 依據興大計中規範：每日總限額 **11 GB**（下載 7 GB / 上傳 4 GB）。
- 原生守護進程自動統計當日傳輸，每日 00:00 自動重設歸零。
- 當日剩餘流量百分比動態顯示於選單列（Menu Bar）與互動式 Webview Popover。

### 2. ⚡ 雙網卡智慧雙軌分流 (Split Tunneling)
- **校內高速流量**：中興大學校內網段（`140.120.*`）自動綁定千兆有線網路（Ethernet）。
- **校外對外流量**：自動分流走 Wi-Fi / 個人熱點，徹底打破 11GB 每日流量上限，享受外網不斷網、校內極速傳輸。

### 3. 🛡️ 違規防禦與計中黑名單預警 (NCHU Security)
- **P2P 主動防禦**：背景掃描常見 P2P / BT 下載工具（如 qBittorrent、Transmission、Thunder 等），主動提示與防護，防止被計中鎖卡斷網。
- **計中超流名單同步**：自動查詢興大計中 Top 100 / 鎖卡名單，提早警示。

### 4. 🌙 闔蓋與閒置保護 (Lid & Idle Guard)
- **Lid Guard**：偵測 Mac 螢幕闔蓋時，自動暫停背景串流播放與凍結高耗能傳輸，防止睡眠期間偷跑流量。
- **Idle Guard**：系統閒置達設定時間自動降級守護。

### 5. 🤖 開發者與 AI 生態保護
- 內建判定機制保護背景重要開發與 AI 代理工作流，避免切換網路時中斷連線。

---

## 🛠️ 專案架構 (Project Structure)

```text
NCHU-NetGuard/
├── src/
│   ├── main.swift              # macOS 原生狀態列 App 核心原始碼
│   ├── Info.plist              # macOS 應用程式設定
│   └── Resources/
│       └── popover.html        # 狀態列互動式面板 UI (Webview)
├── scripts/
│   ├── traffic_monitor.py      # CLI 終端機流量查詢工具
│   └── check_traffic.sh        # 便捷啟動腳本
├── Makefile                    # 一鍵編譯與打包腳本
├── LICENSE                     # MIT 開源授權條款
└── README.md
```

---

## 🚀 編譯與安裝 (Build & Run)

### 系統需求
- macOS 14.0 (Sonoma) 或更高版本
- Apple Silicon (M1/M2/M3/M4) 或 Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)

### 一鍵編譯
在專案根目錄下執行：

```bash
make
```

編譯完成後，應用程式將生成於：
`build/NCHUTraffic.app`

若要直接安裝至個人應用程式目錄並啟動：
```bash
make install
```

---

## 📜 開源協議 (License)

本專案採用 [MIT License](LICENSE) 條款開源。歡迎中興大學校友與開發者提交 PR 或回報 Issue！
