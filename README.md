# E900EarPhoneCam

**E900 攝影耳機 × GlassX × QRing R08 × iPhone Bridge × Mac mini AI Agent**

目標：以 QRing R08 觸控事件作為輸入，經自製 iPhone App 將命令傳至 E900 攝影耳機執行拍照、開始／停止錄影；將原始媒體匯入手機，必要時轉交 Mac mini AI Agent 進行 OCR、場景理解與事件摘要。

## 最新狀態（2026-11-06）

**已到貨；原廠 App 驗收 7/7 完成（使用者操作回報）。第三方 BLE 控制尚未驗證。**

- [x] E900 充電、開機
- [x] iPhone 安裝 GlassX
- [x] GlassX 搜尋並綁定 E900
- [x] 使用耳機實體按鍵拍照
- [x] 使用耳機實體按鍵錄製約 10 秒影片
- [x] 透過 GlassX 將照片、影片匯入 iPhone
- [x] GlassX 支援遠端拍照、開始錄影、停止錄影（使用者回報）
- [ ] Mac mini 掃描 E900 BLE advertisement、GATT UUID
- [ ] 確認 GlassX 的遠端攝影命令是否走 BLE
- [ ] 自製 BLE client 執行 E900 拍照／錄影
- [ ] QRing R08 → iPhone → E900 串接
- [ ] 背景鎖屏可靠性與媒體自動同步

> **證據等級提醒**：上面已勾選的是「使用者直接操作並回報成功」，不是本 Repo 已取得 BLE封包、錄影檔或自動化測試數據。E09／EYEVUE 與 E900／GlassX 可能有不同協定。不得直接把 E09 的 `0x23` / `0x24` 當作 E900 指令。

## 第二輪：Mac mini BLE 只讀偵測

請依 [docs/PHASE2_BLE_DISCOVERY.md](docs/PHASE2_BLE_DISCOVERY.md) 操作。提供 [tools/ble_scan.py](tools/ble_scan.py) 供 Mac mini 本地執行，列出 BLE 廣播、Service / Characteristic UUID、屬性；**不傳送任何 GATT Write**。

```bash
git clone https://github.com/pcpcchen-coder/E900EarPhoneCam.git
cd E900EarPhoneCam
python3 -m venv .venv
source .venv/bin/activate
python -m pip install bleak
python tools/ble_scan.py --scan-seconds 15
# 依掃描輸出的序號選擇 E900，再做唯讀 GATT 列舉
python tools/ble_scan.py --scan-seconds 15 --connect 1
```

其中 `--connect 1` **只是例子**；請依當次掃描結果所顯示的 E900 序號選擇，不能假設 1 一定是 E900。

## 文件

- [Phase 1 實機驗收與證據等級](docs/PHASE1_ACCEPTANCE.md)
- [Phase 2 BLE 掃描操作與判讀](docs/PHASE2_BLE_DISCOVERY.md)
- [工具程式：唯讀 BLE 掃描](tools/ble_scan.py)

## 相關研究

- [E900 與 R08 早期研究檔案（舊 Repo）](https://github.com/pcpcchen-coder/HeadsetWithCam)
- [Halo-Ring：QRing R08 逆向研究](https://github.com/MRziyi/Halo-Ring)
- [EYEVUE E09：參考協定，未驗證與 E900 相容](https://github.com/sctg-development/ai-smart-glasses-e09)
- [GlassX App Store](https://apps.apple.com/us/app/glassx/id6761040357)

## 安全與隱私

專案初期只做 BLE 掃描、GATT Service/Characteristic 列舉，不進行 OTA、恢復原廠、刪除媒體、未知指令探測；實機影片僅測試合法且明確告知的拍攝場景。公開報告避免提交 BLE 裝置識別碼、私人影片、帳號、金鑰或序號。
