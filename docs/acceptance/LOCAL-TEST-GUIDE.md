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
整合 PR 的 Foundation CI 檢查 PR head SHA 而非合併模擬 SHA，並將實際驗證的 SHA 記錄於 Actions 摘要。Foundation CI 強制完整核心原始碼覆蓋率清單及至少 90% 行覆蓋率，並對兩種建置產物執行私有暫存目錄內的安裝、內容比對及拒絕覆寫驗證；不啟動 App、不安裝至使用者 Applications。Hosted macOS CI 不替代你的 Mac 實機結果，也不代表合併後的內容已驗證。若整合 PR 關閉，需重新開 PR 或手動執行 workflow。手動工作階段只計算 ledger 引用的證據；磁碟寫入中斷可能留下未引用私有檔案，不代表新增有效觀察。

## 隔離生命週期演練

`python3 scripts/verify_lifecycle_candidate.py --app build/NCHUTraffic.app` 使用工具自行建立的私有暫存目錄，對實際建置 App 的副本與合成舊版執行 Darwin 原子交換、失敗後回滾、身分衝突拒絕與非破壞性隔離移動，並比對合成歷史資料與來源內容。它不接受實際安裝目的地、不啟動程式、不修改登入項目或使用者資料。CI 閘門不等於真實跨版本遷移、斷電復原、授權升級或解除安裝驗收。

## 候選產物身分紀錄

雙版本建置後執行 `python3 scripts/candidate_inventory.py --expected-sha "$(git rev-parse HEAD)"`。需要乾淨、精確的 checkout；兩種 App 版本欄位必須一致，輸出分別為其 SHA-256 內容指紋及實際 plist 版本。這是內容比對證據，非簽章、建置因果證明、實機驗收或發布授權；輸出一律不宣告 release_authorized。既有 plist 3.0 未擅自改名或發行。

## 一次設定後的無人值守驗收

在乾淨、已審閱的候選 checkout 中執行 `caffeinate -i python3 scripts/acceptance/unattended.py`（或 `make acceptance-unattended`，但後者不抑制閒置睡眠）。先執行自動核心與 host 驗收、兩種 App 建置、隔離安裝/生命週期測試與候選指紋。依提示只需一次自行開啟候選 App、在活動監視器找到 PID，關閉 App 面板並輸入 PID；也可用 `--pid` 明確選擇已啟動且不會被建置覆寫的相同內容副本。必須可取得絕對執行檔路徑，且在磁碟上的整份 bundle 指紋吻合兩個建置產物之一；ps 路徑／啟動時間與磁碟內容比對並非已載入執行檔的簽章或密碼學證明。執行期間每次採樣核對 Git 版本、乾淨狀態及 bundle 內容；此會增加少量測試程序 CPU/I/O，效能數值只計目標程序。

三輪各 300 秒的閒置 CPU/RSS 採樣完成後，連續觀測 168 小時，每 60 秒記錄 CPU 累積時間、RSS、相對單調與牆鐘時間，逐次 fsync 私有日誌並原子更新檢查點。任何版本、程序身分、時間或採樣缺口異常均停止，不自動重啟或補寫資料。`--trial-seconds 60` 只做短時 soak 演練（仍執行三輪效能）；不可能替代 168h。每項觀測於完成後重算日誌雜湊、時間、缺口及數值摘要。總報告 `test-results/unattended-*/summary.json`，內含獨立核心驗證摘要；尚未完成的觀測仍有自己的 JSON/JSONL。保持電源、上蓋開啟及終端執行，不更新 checkout 或候選 App。退出碼 0 僅表示完整長時間觀測及效能數值達標、仍需審查，2 為短試、未達門檻或不確定。Host 不確定項目保留，不視為通過。關閉程式後不能自動接續中斷區間。

必須人工或外部驗證：校方政策及同邊界獨立流量參考、VPN/多網卡與 IPv4/IPv6 切換、睡眠/喚醒、VoiceOver 與新手操作、正式復原/升級授權及獨立安全審查。工具不擅自製造宿網流量、修改設定、執行系統網路操作或自動上傳日誌。`full_device_acceptance` 與 `release_authorized` 永遠為 false；無人值守數值與日誌只構成待審查證據。

完成後可獨立重新驗證：`python3 scripts/acceptance/unattended.py --verify test-results/unattended-實際目錄 --expected-sha <實際驗收SHA>`（將角括號整段換成 40 位 SHA）。會核對核心報告、隔離測試 marker 與日誌雜湊、完整三輪效能及 soak 取樣、時距與摘要。輸出為可人工審查的摘要，不包含原始 PID、IP、程序路徑或原始日誌；不驗證已載入二進位簽章或外部證據真實性。
