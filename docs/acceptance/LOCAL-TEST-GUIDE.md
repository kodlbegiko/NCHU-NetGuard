# 本機驗收指南

## 前置條件
macOS 14+、Swift 5.9+、Python 3、Git、Xcode Command Line Tools。從已確認的乾淨 Git 工作樹執行，不需要 sudo、付費服務或改動網路設定。測試工具不是安全沙箱；只在已審閱的程式碼上執行。預設不啟動正式 App、不安裝、不製造測試網路流量。Smoke 使用 fixture-only App 入口；host probes 讀取當前主機本機資訊。

```bash
git switch fix/r4-closure-integration
git status --short
make acceptance-local
```

只跑核心測試及建置（不執行 host probes）：
```bash
python3 scripts/acceptance/run_all.py --profile core
```

輸出：test-results/local-*/summary.json、environment.json、logs/*.log。每一步完成即寫入 JSON，記錄精確 SHA、乾淨工作樹、系統版本、硬體型號（若可讀取）、每步結果、耗時、exit code、log SHA256。Git 狀態只記布林值，不保存路徑。日誌可能含有本機路徑或系統資訊，只保存在 700 目錄與 600 檔案中；不應提交到 GitHub。test-results 已加入 gitignore。若目錄原本不是私有目錄，先自行檢查所有者與內容，不直接覆寫。報告為本機證據，沒有簽章或防同使用者竄改保證。

直接執行 Python 的 exit code：0 = 選定的自動步驟通過；1 = 有失敗；2 = 無法確認、未執行、工作樹不乾淨或版本改變。make 會把非零子指令結果轉為自己的失敗碼。覆蓋率程式即使成功產生報告，若清單不完整或未達 90% 仍不算通過。無論哪種結果，都不授予正式實機驗收。中止執行或測試逾時僅終止這次測試自行啟動的子程序群組，不停止使用者既有程式。

## 驗證與分享測試報告
新報告 schema v2 記錄完整預定步驟與選用項目，避免只跑部分步驟卻得到成功結果。執行：

```bash
python3 scripts/acceptance/verify_report.py test-results/local-實際目錄名稱 --expected-sha "$(git rev-parse HEAD)"
```

驗證器核對 SHA、完成時間、環境資料、步驟清單、退出碼、log SHA-256、成功標記及數值門檻。輸出只包含粗略步驟狀態，不包含原始日誌、IP、PID 或裝置資訊，可先人工檢閱再分享。舊版 v1 報告缺少完整計畫，不接受為 v2 完整驗收證據，請重新執行。雜湊可檢查本機檔案一致性，不能證明報告作者身分或防範同使用者修改整份報告。

## 可選：既有 App 效能及獨立流量證據
使用者先啟動待驗收的候選 App，確認來源/版本並由活動監視器取得它的 PID。下例 PID 必須改成自己的數值；不會啟動或終止 App。
```bash
python3 scripts/acceptance/run_all.py --pid 12345 --benchmark-seconds 300
python3 scripts/acceptance/run_all.py --traffic-evidence /path/to/redacted-evidence.json
```
效能以 process CPU-time delta、RSS 為限，不涵蓋其他子程序；空閒條件與執行檔 SHA 仍需人工核對。單次自動數值驗收至少 300 秒，預設 5 秒取樣的最大間隔不得超過 15 秒；短試或取樣缺口過大只列為不確定，即使 CPU／RSS 達標。重複測量與人工審查仍為必要。舊報告若缺少最大間隔證據，不再接受為效能通過。新 benchmark JSON 額外記錄初始／最後／最低／峰值 RSS、峰值相對時間、最大採樣間隔及約 60 秒區段的 CPU/RSS 統計，不含 PID 或程序身分。區段共用邊界採樣點，不能將區段次數相加當成總採樣次數。若仍未達標，提供這些去識別數值以定位峰值區間；峰值上升本身不是記憶體洩漏證明。流量輸入依 [獨立計量規格](../audits/CONTROLLED-TRAFFIC-ACCEPTANCE.md)，僅判斷數學誤差，不能自行證明參考來源獨立或校方計費一致。不要為測試耗盡宿網配額。

## 可選：長時間觀測
```bash
python3 scripts/acceptance/soak_test.py --pid 12345 --seconds 60 --interval 5
python3 scripts/acceptance/soak_test.py --pid 12345
```
第一行只做短試；第二行預設前景執行 168h，每 60 秒採樣。輸出 test-results/soak-*/summary.json、environment.json、samples.jsonl，僅保留統計值、不保存 PID 或程序路徑。關閉終端、程序結束、身分改變、時間倒退、超過允許採樣缺口等均不能判定通過；不嘗試自動重啟 App 或改變睡眠設定。即使完整觀測 168h，仍要審查執行檔身分、功能失效與 crash 記錄。

## 人工驗收

可直接建立及記錄私有實機驗收工作階段，不必手動計算雜湊或編輯 JSON。先於乾淨 macOS checkout 執行：

```bash
python3 scripts/acceptance/manual_session.py init
```

將輸出的 test-results/manual-* 目錄代入下例，並使用自己事先去識別的實際觀察紀錄（不是樣板）：

```bash
python3 scripts/acceptance/manual_session.py record test-results/manual-實際目錄名稱 sleep_wake --outcome inconclusive --evidence /path/to/redacted-observation.txt
python3 scripts/acceptance/manual_session.py verify test-results/manual-實際目錄名稱
```

工具會複製明確指定的檔案至私有 evidence/，以 SHA-256 命名，不保存來源檔名。每個 gate 僅記錄一次，重新測試請開新工作階段；禁止執行 blocked gate。verify 會實際檢查已引用檔案內容與雜湊，不代表驗證證據真實性。請勿輸入未去識別的資料，勿提交整個目錄。所有結果都仍需獨立審查。

依 [驗收矩陣](ACCEPTANCE-MATRIX.md) 逐項在有權限且不影響重要工作之環境測試。複製 MANUAL-RESULT.template.json 到私有 test-results 目錄，填寫實際結果及去識別證據；使用 record_manual.py 驗證紀錄結構（例如：python3 scripts/acceptance/record_manual.py test-results/manual.json）。不可把樣板當作測試結果，也不可執行仍被禁用的真實復原、擴充、升級/解除安裝。正式核准需整合負責人審查。原始紀錄留本地，分享前只提供去識別摘要。

## CI 與本機驗收的區別
整合 PR 的 Foundation CI 檢查 PR head SHA 而非合併模擬 SHA，並將實際驗證的 SHA 記錄於 Actions 摘要。Hosted macOS CI 不替代你的 Mac 實機結果，也不代表合併後的內容已驗證。若整合 PR 關閉，需重新開 PR 或手動執行 workflow。手動工作階段只計算 ledger 引用的證據；磁碟寫入中斷可能留下未引用私有檔案，不代表新增有效觀察。
