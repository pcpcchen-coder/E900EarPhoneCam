# E900 Control — macOS App

2026-11-07，版本 0.2.0（Claude Code 接手：P0 可靠性修正與 P1 編碼補齊）。此版本是 Mac 原生 App（macOS 13+），不是 iPhone App。沿用本專案已驗證的 macOS/CoreBluetooth 控制路徑，無第三方套件、帳號或雲端服務需求。後續用途／AI 整合另行決定。

## 開啟

下載此分支後，在 Terminal 執行：

```bash
bash scripts/build-macos.sh
open "dist/E900 Control.app"
```

需要 Xcode Command Line Tools 或 Xcode 的 Swift 工具鏈。也可雙擊根目錄的 `Launch E900 Control.command`（首次須有執行權限，或用 `bash "Launch E900 Control.command"`）。產物在 `dist/E900 Control.app`，可自行搬到 Applications；目前採本機 ad-hoc 簽署，非 Apple 公證發行版。

首次開啟若出現藍牙／區域網路權限，允許 App 存取。這個 .app 有獨立 bundle ID 及 usage description，避免在受限的 agent shell 執行 BLE。

1. 耳機開機；若 GlassX 佔用連線，先關閉其連線。
2. 「總覽」→「搜尋裝置」→ 選擇自己的 E900 →「連線」。不自動選附近第一台、不依賴舊的 `/tmp` 掃描結果。
3. 連線並訂閱 AA14/AA15 後，只自動查詢電量，不自動變更設定。
4. 拍照、開始／停止錄影可直接使用；其餘需啟用「E09 候選功能」。此選項每次啟動預設關閉。
5. 畫面底部看指令結果，錄影／錄音狀態看 ACTION_SYNC；GATT ACK 不等於完成。

## 功能覆蓋與限制

| 領域 | App 提供 | 驗證／限制 |
|---|---|---|
| 連線 | 手動掃描與選擇、GATT 檢查、通知訂閱、中斷、逾時處理 | 已完成程式及編譯；新 .app 的實機連線仍需驗收 |
| 電池 | 查詢、BCD 候選解碼、充電狀態、推播 | E900 查詢回覆已驗證；百分比解碼沿用 E09，未獨立量測 |
| 裝置資訊 | 版本、容量、能力位元、產品資訊、狀態讀取 | E09 候選；容量不猜單位 |
| 攝影 | 高畫質／縮圖拍照、開始／停止錄影 | 高畫質拍照與影片控制有既有 E900 實機驗證；本 App 尚待重驗 |
| BLE 預覽 | 縮圖數量、索引狀態、拉圖、AA15 `52 58…58 52` 與 AC55 幀解碼、偏移重組、顯示與另存 JPEG | 包裝格式依上游 `FileDatagram` 與參考文件硬體樣本，含 footer／checksum 檢查；E900 待實機確認；缺塊或未結束不顯示殘圖；僅低解析預覽 |
| 本機錄音 | 開始、停止、錄音狀態 | 原檔走 Wi-Fi；候選功能 |
| 常用設定 | 亮度、佩戴、模式、方向、同步時間、錄影時長、畫質比例 | 候選功能；耳機回報同一指令時選單改為回報值（綠字），其餘為未確認值 |
| 依上游補齊的編碼 | 錄影時長 0x02（秒數 BE16，60/180/300/420/600）、畫質 0x35（解析度、比例兩位元組）、音量增減 0x32、絕對音量 0x70（系統／通話 0–15、媒體 0–16）、語音助手 0x72 | 來自固定上游反編譯 `SendCommandViaBle`；0x35 原廠未呼叫，位元組意義由常數推定；麥克風 0x03 值域不明，只留在進階頁 |
| 手勢 | 前滑、後滑、單／雙／三擊配置，讀回（0x48 逐項推送並對應到選單）、重置 | 不代表可憑韌體增加實體硬體沒有的手勢 |
| 音樂／通話 | 播放、暫停、上下首、音量增減（0x32，舊版誤用 0x70 已修正）、三音量讀取與顯示、接聽／掛斷、A2DP 配對請求 | 手機控制還需 OS 的 classic Bluetooth / AVRCP / HFP；Mac App 不處理 iPhone 通話框架 |
| Wi-Fi | AP/P2P 啟動、實際 SSID 顯示、系統 Wi-Fi 設定入口、保留媒體的結束命令 | 加入網路由使用者操作；IP／密碼為 E09 候選，不自動切走目前網路 |
| 媒體 | JSON／XML 清單、多選下載、取消、本機開啟 | 僅私有 IPv4，拒絕重新導向與不安全路徑；XML 錯誤／狀態非 0／未閉合文件不再當成空清單；本機「開啟」以清單＋主機＋檔名對應；UUID 檔名前綴防覆寫；照片解碼、AVFoundation 音／影片串流與時長檢查；不自動清除 |
| 即時影像 | 能力 bit0 判斷（能力未讀取時拒絕啟動）、AP 預覽啟動、兩個 RTSP 路徑 | 需要系統有 VLC 等 RTSP 播放器；未內嵌解碼；E900 待測 |
| 語音助手 | 語言、離線／喚醒開關、狀態、開始／停止／取消、拍照辨識觸發 | 沿用 E09 編碼，尚未接 ASR／LLM／TTS；不冒用原廠雲端 |
| 麥克風串流 | 0x46 接收、串流狀態（啟動中／串流中／停止中／停止未確認）、30 秒自動停止、停止最多重送 3 次、被動喚醒（AA14 0x97/0x99）接收、匯出 Ogg Opus | 每個 0x46 視為一個原始 Opus packet（E09 推定），依 TOC 計算時長；muxer 已用 opusinfo／opusdec 驗證；E900 封包是否為原始 Opus 待實機確認，不符時改存 `.opuspackets`；無內建轉錄 |
| 維護 | 手勢重置、清配對、恢復原廠、清空媒體 | 每次要求輸入「確認」；全屬未驗證候選，請有實際需要再使用 |
| OTA | 顯示限制與命令資訊 | 不執行：缺乏可信的 E900 映像、完整性及相容性驗證；不能宣稱已支援安全刷寫 |
| 指令佇列 | 一次一筆、依回覆碼配對、5 秒逾時不重送、遲到回覆不算到下一筆、停止類插隊／去重／可搶先、斷線清空不重播 | `CommandCoordinator` 單元測試涵蓋；實機時序待驗 |
| 診斷 | 限量記錄、原始回覆、匯出、進階已知命令白名單 | 不記錄照片／音訊內容；SSID 可能出現在記錄，分享前請檢查 |

參考協定列出的 inbound-only 狀態／資料事件由接收處理；0x63 OTA、0x65 版本寫入與 0x66 原廠未使用命令不在進階白名單。AE00 的用途仍未知，不使用。

## Wi-Fi 取檔

1. 啟用候選功能並按「開啟 Wi-Fi AP」，取得耳機真正回報的 SSID。
2. 開啟 Wi-Fi 設定，加入該 SSID；E09 候選密碼 `12345678`。Mac 只有 Wi-Fi 上網時，這可能中斷網際網路。
3. 填耳機的實際私有 IPv4，先候選 `192.168.169.1`。不自動搜尋其他網路。
4. 讀取清單，選下載資料夾，再多選檔案下載。原始 size 單位不明，不當作 byte 比對。
5. 成功項目顯示「開啟」；失敗清楚列出。相同名字每次另存唯一檔，不覆寫既有檔案。
6. 耳機原檔全程保留。需要時按「結束傳輸並保留原檔」，這仍是 E09 候選命令。

macOS 不支援的影片／AAC 變體可能無法通過 AVFoundation 檢查；此時顯示失敗且不清除耳機原檔。

## 驗證

```bash
bash scripts/test-macos.sh
bash scripts/build-macos.sh
```

47 項自動測試涵蓋：既有 E900 封包、每個分割位置的重組、合包／雜訊／損壞校驗、AA15 `52 58` 硬體樣本／分包／壞 footer／壞 checksum／照片端到端、BCD／hex、縮圖亂序／重複／缺塊／惡意 offset；指令佇列（配對、逾時、遲到回覆、舊 timer、停止插隊／去重／搶先、寫入失敗、斷線）；串流狀態機（停止確認、重送上限、舊 auto-stop、被動喚醒）；上游編碼（查詢參數、音量、錄影時長、畫質、語音助手、時間、能力位元、ACTION_SYNC）；下載（部分失敗、空檔、壞媒體、404、取消、不安全主機、不覆寫、URLSession＋URLProtocol 的 200／500／302／取消／端到端）；XML 錯誤文件；Ogg CRC、TOC 時長、頁面結構。

GitHub Actions（`.github/workflows/macos.yml`）在 macOS 15 上跑測試、建置 `.app` 並上傳 zip artifact。純邏輯部分也可在 Linux 的 Swift 工具鏈上測試（不含 AppKit／CoreBluetooth）。

實機驗收必須分別記錄，不以軟體測試代替：

- [ ] 新 .app 開啟並取得藍牙權限，選擇自己的 E900 連線。
- [ ] 電量查詢收到有效 0x17 回覆。
- [ ] App 拍照後確認實際照片；開始／停止錄影後確認可播放影片。
- [ ] 關耳機／中斷後狀態回到未知，無自動重送快門或重播設定。
- [ ] 逐項確認候選設定是否可讀回／生效，不成功就保留待驗證。
- [ ] 真正 SSID、IP、清單、原始照片／影片下載與解碼成功。
- [ ] 即時影像、本機錄音及語音能力逐項驗證。

沒有執行破壞性維護、刪除或 OTA 實機測試。

## 程式結構

```text
app/
  Package.swift
  Info.plist
  Sources/E900Control/
    App.swift                # 七個頁面、能力顯示與操作確認
    Headset.swift            # CoreBluetooth、通知分派、狀態處理（使用下列純邏輯）
    CommandCoordinator.swift # 指令佇列生命週期、VoiceSession 狀態機（無 UI／BLE 依賴）
    Protocol.swift           # AC55／52 58 幀解析、縮圖重組、命令清單、上游編碼、回讀解碼
    OggOpus.swift            # 0x46 Opus packet → Ogg Opus
    MediaCore.swift          # 清單解析、HTTP transport、下載流程（無 UI 依賴）
    Media.swift              # MediaStore（UI 狀態）、AVFoundation 媒體驗證
    SettingsView.swift       # 設定、手勢、音量、語音助手、進階參數
    MediaView.swift          # 媒體管理與 RTSP 入口
  Tests/E900ControlTests/    # Protocol / CommandLifecycle / MediaDownload 測試
scripts/
  swift-common.sh          # 共用 SwiftPM 參數；自動偵測 --build-system
  build-macos.sh
  test-macos.sh
.github/workflows/macos.yml
```

可在此原生控制核心上另加 ring trigger 或 AI integration；此版本沒有替使用者決定後續應用。
