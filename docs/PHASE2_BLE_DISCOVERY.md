# Phase 2 — Mac mini 唯讀 BLE 掃描與 GATT 盤點

- 狀態：**NOT TESTED**（操作說明已備妥，等待 Mac mini 真機輸出）
- Phase 1：原廠 GlassX 遠端攝影及媒體匯入皆由使用者回報成功。
- 目的：列出 E900 Bluetooth Low Energy (BLE) 廣播裝置、Service / Characteristic UUID 與特徵屬性，尋找後續協定研究的入口。
- **本輪不寫入 BLE、不卡住／干預 GlassX，不測試錄影指令。**

## 0. 安全準備

1. E900 充電並開機，放在 Mac mini 附近。若指示燈／配對模式需要喚醒，依原廠說明操作。
2. 原廠 GlassX 的功能已驗證；現在**暫時關閉 GlassX 或關閉 iPhone 藍牙一小段時間**，避免 E900 同時連線限制導致掃描失敗。
3. Mac mini 啟用 Bluetooth；若 macOS 提示 Terminal／Python 藍牙權限，至「系統設定 → 隱私權與安全性 → 藍牙」授權執行所需的程式。若權限剛更改，重啟 Terminal 再測。
4. **不要操作 OTA、韌體更新、恢復原廠、刪除檔案。** 只收集 Service / Characteristic UUID 和其屬性。
5. Mac BLE 掃描看不到一般 Bluetooth Classic（如 A2DP）的所有服務；無 BLE 廣播不等同裝置沒有無線連線能力。

## 1. 在 Mac mini 執行

```bash
git clone https://github.com/pcpcchen-coder/E900EarPhoneCam.git
cd E900EarPhoneCam
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install bleak
python tools/ble_scan.py --scan-seconds 15
```

輸出會顯示本次掃描的「序號、名稱、RSSI、廣播 Service UUID」。Mac 上的 address 可能是 CoreBluetooth opaque UUID，工具預設**不輸出此識別資訊**。

找到疑似 E900 的那一列後，假如序號為 3：

```bash
python tools/ble_scan.py --scan-seconds 15 --connect 3
```

上面的 `3` 必須換成**實際當次輸出的序號**；工具會重掃，所以如排序變動應再次確認其名稱和廣播 UUID。掃描到的名稱可能是 `E900`、`JL_*`、`DH_*` 或完全不顯示，**這些都是假設，不要因名稱不同直接判定失敗**。

## 2. 結果如何看

| 若看到 | 代表 | 下一步 |
|---|---|---|
| `0000aa12-0000-1000-8000-00805f9b34fb` 和 `AA13 / AA14` | 與 E09 參考協定 GATT 表面相似 | 只做比對；不能直接傳 E09 指令 |
| JieLi / RCSP 類型自訂 Service | 可能與 JieLi 設備控制協定有關 | 對照晶片 SDK 的 GATT 定義、原廠包裝與韌體 |
| 僅標準 `1800/1801/180A/180F` | 目前看到的是基本資訊／電池 | 確認是否選錯音訊端點、設備是否綁定或未進入可廣播狀態 |
| 同時出現多個 E900 / JL / DH / Unknown | 可能不同裝置或 BLE / Classic 多端點 | 逐一記錄，不要隨機寫入 |
| `ERROR` 或無法連線 | 可能被 GlassX 佔用、電力不足、權限拒絕、macOS 限制等 | 先確認裝置、權限與 iPhone 連線，再重試 |

E09 公開對照：[EYEVUE BLE 協定](https://github.com/sctg-development/ai-smart-glasses-e09/blob/main/REVERSE_ENGINEERING_EYEVUE_BLE_PROTOCOL.md)。該逆向專案的 `RECORD_VIDEO 0x23`、`STOP_RECORD 0x24` **都還不是 E900 經證實可用的封包**。

## 3. 第一輪 BLE 驗收門檻

- G2-BLE-01：Mac mini 可以掃描到疑似 E900 的 BLE 裝置（或明確記錄未掃描到與環境因素）。
- G2-BLE-02：若允許連線，列出 Service UUID。
- G2-BLE-03：若允許連線，列出至少每個 Service 的 Characteristic UUID 及 read/write/notify 等屬性。
- G2-BLE-04：保存執行日期、macOS／Python／Bleak 版本、設備與 GlassX 連線狀態、掃描結果（去識別化）。
- G2-BLE-05：整個過程**無任何 GATT 寫入或 OTA**。

**本輪成功不等於「已成功錄影控制」**。那會是 Phase 3：在確認正確的傳輸、授權與完整封包規格後，對自己的設備使用可復原的拍攝指令；核對實際生成的影片。

## 4. 請提供給後續 Agent 的資料

你可以直接把 Terminal 中的序號、裝置名稱（若非個人化）、Service UUID、Characteristic UUID、特徵屬性和錯誤訊息貼回對話。請不要貼藍牙位址、完整序號、個人影像、配對密鑰或可識別他人的資料。

```text
Mac mini model / macOS:
Python version / Bleak version:
GlassX was disconnected during scan?:
BLE scan result names and services:
Selected scan index:
GATT service UUIDs:
GATT characteristic UUIDs and properties:
Errors:
```
