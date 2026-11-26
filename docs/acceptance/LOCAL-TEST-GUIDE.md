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

## 可選：既有 App 效能及獨立流量證據
使用者先啟動待驗收的候選 App，確認來源/版本並由活動監視器取得它的 PID。下例 PID 必須改成自己的數值；不會啟動或終止 App。
```bash
python3 scripts/acceptance/run_all.py --pid 12345 --benchmark-seconds 300
python3 scripts/acceptance/run_all.py --traffic-evidence /path/to/redacted-evidence.json
```
效能以 process CPU-time delta、RSS 為限，不涵蓋其他子程序；空閒條件與執行檔 SHA 仍需人工核對。流量輸入依 [獨立計量規格](../audits/CONTROLLED-TRAFFIC-ACCEPTANCE.md)，僅判斷數學誤差，不能自行證明參考來源獨立或校方計費一致。不要為測試耗盡宿網配額。

## 可選：長時間觀測
```bash
python3 scripts/acceptance/soak_test.py --pid 12345 --seconds 60 --interval 5
python3 scripts/acceptance/soak_test.py --pid 12345
```
第一行只做短試；第二行預設前景執行 168h，每 60 秒採樣。輸出 test-results/soak-*/summary.json、environment.json、samples.jsonl，僅保留統計值、不保存 PID 或程序路徑。關閉終端、程序結束、身分改變、時間倒退、超過允許採樣缺口等均不能判定通過；不嘗試自動重啟 App 或改變睡眠設定。即使完整觀測 168h，仍要審查執行檔身分、功能失效與 crash 記錄。

## 人工驗收
依 [驗收矩陣](ACCEPTANCE-MATRIX.md) 逐項在有權限且不影響重要工作之環境測試。複製 MANUAL-RESULT.template.json 到私有 test-results 目錄，填寫實際結果及去識別證據；使用 record_manual.py 驗證紀錄結構（例如：python3 scripts/acceptance/record_manual.py test-results/manual.json）。不可把樣板當作測試結果，也不可執行仍被禁用的真實復原、擴充、升級/解除安裝。正式核准需整合負責人審查。原始紀錄留本地，分享前只提供去識別摘要。
