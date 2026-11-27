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

計資中心公告列出宿網每日下載 7G／上傳 4G、校園網路下載 10G／上傳 5G；較新的部分住宿規章索引文字出現不同額度，適用範圍仍待確認。程式暫維持原本本機設定額度，不視為校方確認餘額；實際計費單位、歸屬及結算時間尚待確認。本機帳本換日不代表校方配額已重設。缺漏或未歸類流量不視為零，也不推論無超流或鎖卡。

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

候選 `make install` 僅支援非 root 使用者的全新安裝：先複製至同目錄的私有暫存區、驗證應用程式結構，再以 macOS 排他性重新命名發布。若目的地已存在（包含連結），拒絕覆寫。預設路徑為 `~/Applications`；可明確指定 `INSTALL_DIR`。此流程不啟動 App、不修改網路、不執行升級或解除安裝。正式生命週期及實機驗收仍未完成；建議先建置與驗證候選版。

可先進行唯讀安裝／版本內容比對（不會建立、覆寫或刪除 App）：

```bash
python3 scripts/install_bundle.py --source build/NCHUTraffic.app --destination-dir "$HOME/Applications" --review
```

比對雜湊涵蓋目錄、檔案內容和 owner-execute 狀態；不等於簽章、版本順序、Git SHA 或執行中程式身分。不同內容一律需審查，不授權升級。全新安裝也會檢查複製前後內容一致性。

## 本機完整驗收入口

```bash
make acceptance-local
```

執行核心測試、覆蓋率、雙建置、fixture smoke、唯讀主機相容性與 TCP/UDP 觀測，生成私有、忽略於 Git 的本機報告。效能、獨立流量比對與 168 小時觀測另外提供明確參數；需人工或授權的測試不自動執行。見 [本機驗收指南](docs/acceptance/LOCAL-TEST-GUIDE.md) 與 [驗收矩陣](docs/acceptance/ACCEPTANCE-MATRIX.md)。

## 無人值守候選驗收（一次人工啟動）

```bash
caffeinate -i python3 scripts/acceptance/unattended.py
```

先自動跑核心、雙建置、主機唯讀探測及隔離生命週期演練，接著依提示正常退出舊 App，於第二個終端機執行工具顯示的候選 App 開啟指令、關閉其面板（工具自動確認程序身分）；之後自動量測三輪各 300 秒的閒置效能及 168 小時連續觀測。`caffeinate -i` 僅在命令執行期間抑制閒置系統睡眠，不修改永久設定，不保證闔蓋後維持執行。接上電源並保持上蓋開啟、終端機與 App 執行。報告留在私有 `test-results/unattended-*`，不自動上傳。完整實機與發布仍需人工及獨立證據；工具不自動修改網路或啟動、重啟、終止現有 App。

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
