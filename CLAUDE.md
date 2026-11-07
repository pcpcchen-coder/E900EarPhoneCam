# E900EarPhoneCam — Claude Code 作業說明

使用者：George，以繁體中文溝通與撰寫報告。目標是讓 Claude 在 Mac mini 上自行建置、安裝、測試 E900 Control（macOS 原生 App），除非需要本人操作（藍牙權限、耳機開機、確認照片／影片內容）否則不打擾他。

## 標準流程

1. `git pull`，讀 `docs/CLAUDE_CODE_HANDOFF.md`、`docs/APP_GUIDE.md`。
2. 改程式後：`bash scripts/test-macos.sh`。
3. 安裝並實機驗收：`bash scripts/install-and-accept.sh`（耳機需開機）。讀 `acceptance-reports/` 最新報告；FAIL 就查協定記錄、修正、重跑。
4. 只把「待人工確認」項目整理成一份清單給 George，不要逐步詢問。

## 不可做

- 不送 0x14 恢復原廠、0x15 清配對、0x43 手勢重置、`0x44 30 00` 清空媒體、0x63 OTA；不用任意 hex 做實驗。
- 不把 E09 參考協定或協定回覆寫成「E900 已驗證」；照片／影片內容只有 George 確認後才算通過。
- 不收集 API key、不上傳音訊或媒體；後續 AI 應用等 George 決定。
- 不把 `acceptance-reports/`、錄音、照片、裝置 UUID 提交到 git。
