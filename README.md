# NCHU-NetGuard（興大宿網守護者）

[![macOS](https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=flat&logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Language-Swift%205.9%2B-orange?style=flat&logo=swift)](https://swift.org)
[![License: CC0-1.0](https://img.shields.io/badge/License-CC0--1.0-blue.svg)](LICENSE)

為中興大學宿舍及校園網路設計的 macOS 本機流量觀測、配額提醒與網路診斷工具。

> 本分支是 R4–R6 工程整合候選版本（Draft PR #3），不是正式發布版本。預設唯讀觀測；不啟用自動路由變更、進程終止或特權擴充。本工具非校方官方產品，所有操作須符合校方與網路服務提供者規範。

## 目前候選能力與限制

| 功能 | 目前狀態 |
|---|---|
| 多網卡用量與歷史 | 本機介面計數、分類帳本、歷史與 CSV；實機精度、VPN 去重尚待驗證 |
| 校園／宿網配額 | 本機估計與校方榜單分開；校方實際剩餘額度未知 |
| 網路分類 | 校園 Wi-Fi 為本機推測；有線校園 IP 不足以證明宿網，手動選擇僅限當前網路 |
| 網路診斷 | 唯讀路由、連線品質及可用性觀測；IPv6、UDP、實體設備相容性仍需驗證 |
| P2P、閒置與工作流 | 觀測、提示及採樣管理；不自動終止或凍結程式 |
| 智慧自動化 | 規則編輯、預覽及復原模擬；不執行真實網路變更 |
| 原生介面 | 快速面板、歷史、設定、管理及自動化候選介面；實際可用性與無障礙驗收未結案 |

校方公告列出宿網每日下載 7G／上傳 4G、校園 Wi-Fi 下載 10G／上傳 5G。實際計費單位、歸屬及結算時間尚待確認。本機帳本換日不代表校方配額已重設。缺漏或未歸類流量不視為零，也不推論無超流或鎖卡。

- [R4.0–R6.0 開發藍圖](docs/ROADMAP.md)
- [工程追蹤與剩餘驗收](docs/audits/MASTER-ENGINEERING-TRACKER.md)
- [最近驗證紀錄](docs/audits/EXECUTION-CHECKPOINT.md)
- [校方政策證據與限制](docs/audits/R4-NCHU-POLICY-EVIDENCE.md)

## 編譯與驗證

需求：macOS 14.0 以上、Swift 5.9 以上、Xcode Command Line Tools。Apple Silicon 與 Intel 的實機相容性仍待驗證。

```bash
make test
swift test
make build
make build-module
make smoke
make smoke-module
```

預設建置產物為 `build/NCHUTraffic.app`；模組連結候選產物為 `build/module/NCHUTraffic.app`。上述測試不啟動一般互動 App，也不修改主機網路設定。尚未取得最新 SHA 的 CI 時，不應將舊結果當成最新驗證。

已實作 `make install` 的基本使用者目錄複製目標，但尚未完成安全升級、解除安裝與回滾驗收；候選版本建議先建置，不自動安裝。

## CLI 本機觀測

```bash
python3 scripts/traffic_monitor.py --scope dorm
python3 scripts/traffic_monitor.py --scope campus_wifi --json
python3 scripts/traffic_monitor.py --scope external --json
```

`--scope` 選擇本機帳本分類，不是校方身分確認。不指定時仍可取得適用的榜單查詢結果，但不自動猜測本機流量分類。校方查詢僅在符合校園位址候選條件時發送。

## 程式架構

- `src/`：macOS App 與相容 WebView。
- `Sources/`：SwiftPM 觀測、流量、復原、供應商、資料及核心模組。
- `Tests/` 與 `tests/`：Swift 與 Python 回歸測試。
- `scripts/`：CLI 與本機驗證工具。
- `docs/`：藍圖、契約、所有權與工程證據。

## 開源授權

[CC0 1.0 Universal](LICENSE)。歡迎提交 issue 或 PR；請先閱讀 [AGENTS.md](AGENTS.md) 與工程所有權規範。
