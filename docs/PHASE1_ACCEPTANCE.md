# Phase 1 — E900 到貨與原廠功能驗收

- 紀錄日期：2026-11-06（Asia/Taipei，接獲使用者完整回報）
- 裝置：E900 系列攝影耳機（型號、批次與韌體版本待實機核對）
- App：GlassX（賣家確認；使用者已安裝、配對並操作）
- 驗收來源：**使用者親自操作後回報**。尚未附測試影片、封包、BLE log 或版本截圖。

## 回報結果

| ID | 測試 | 回報 | 證據等級 |
|---|---|---|---|
| P1-01 | E900 充電與開機 | PASS | USER-REPORTED |
| P1-02 | iPhone 安裝 GlassX | PASS | USER-REPORTED |
| P1-03 | GlassX 搜尋並綁定 E900 | PASS | USER-REPORTED |
| P1-04 | 實體按鍵拍照 | PASS | USER-REPORTED |
| P1-05 | 實體按鍵錄製約 10 秒影片 | PASS | USER-REPORTED |
| P1-06 | GlassX 匯入照片及影片至 iPhone | PASS | USER-REPORTED |
| P1-07 | GlassX 提供遠端拍照、開始錄影、停止錄影功能 | PASS | USER-REPORTED |

## 能得出的結論

1. **已確認 GlassX 是可操作 E900 的手機端應用**，且可透過 App 進行遠端拍攝。
2. 已確認原廠的媒體匯入流程在此設備上可行。
3. 存在手機 → E900 的控制流程；**尚未確認這條流程使用 BLE、Wi-Fi、Bluetooth Classic、混合通道或其他實作**。

## 目前無法下結論的事項

- 第三方 App 是否能拿到相同的拍攝控制權限。
- GlassX 是否使用 E09／EYEVUE 的 `AA12/AA13/AA14` UUID 或 `0x23 / 0x24` 指令。
- 本裝置是否公開 RCSP／SDK；是否有加密／授權握手。
- 影片自動下載是否可由自製工具重現，以及 GlassX 是否能與自製 BLE client 同時連線。
- iOS 鎖屏、背景執行、被強制關閉後的可靠性。
- 影像長度、電池與儲存效能上限。

## 下一步

執行 [Phase 2 — Mac mini 唯讀 BLE 探測](PHASE2_BLE_DISCOVERY.md)。先記錄原廠 App 綁定成功時的裝置名稱／韌體資訊，再 **暫時關閉 GlassX 或中斷其與 E900 的連線**，避免搶占連線。使用工具掃描，讀取廣播與 GATT Service／Characteristic；不發送未知命令。

## 原始證據補齊模板（待實機補）

```text
Date:
E900 exact model / hardware revision:
E900 firmware revision:
GlassX App version:
iPhone iOS version:
Camera recording start/stop in GlassX: successful? Y/N
Photo/video import successful? Y/N
Observed BLE advertised name:
BLE GATT inventory reference file:
Notes / screenshots (redact secrets and IDs):
```

採用 `USER-REPORTED` 而非 `AUTOMATED-VERIFIED`，避免未來 Agent 誤把口頭驗收視為完整封包或 CI 證據。
