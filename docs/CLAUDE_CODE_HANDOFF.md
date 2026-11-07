# Claude Code 接手文件：E900 Control

更新：2026-11-07（Asia/Taipei）

## 先理解使用者真正要什麼

George 已收到 **E900 攝影耳機**，原廠 iPhone App 是 **GlassX**。他要一個自己能設定、操作耳機的 App，盡量涵蓋耳機全部可用功能。**後續應用還沒決定**，不要自行擴張成 AI 雲端平台，也不要把 QRing、AIOS、Nous 整合當成本輪必須完成的功能。

原話：「幫我製作一個可以設定跟操作這個耳機的 APP！所有功能都要有！怎應用我在想！」目前又要求轉交 Claude Code 接手。

他不希望持續重複手動測試，也不喜歡只停留在規劃。已有證據的部分直接沿用，能自行編譯、檢查、修正的工作請直接完成；只有實際需要本人操作耳機或系統權限時，再給一個明確步驟。

**關鍵：這次交付是 Mac 原生 App 第一版，並非全功能已實機完成，也不是 iPhone App。** 不要向使用者宣稱所有功能都已經驗證。

## Repo 與這一輪產物

- GitHub：<https://github.com/pcpcchen-coder/E900EarPhoneCam>
- 本次工作分支：`codex/e900-control-app`
- 開始工作的 upstream main commit：`409cd0ad9357ddb1197ccad6db1a8a29c03cd19b`
- Mac 本機工作目錄：`/Users/georgechen/Documents/Codex/2026-11-07/repo-https-github-com-pcpcchen-coder/E900EarPhoneCam`
- 本機成品：上述目錄的 `dist/E900 Control.app`（gitignored，clone 後需重建）。
- 已以原生 UI 自動化開啟成品，檢視總覽、裝置設定、媒體管理頁，畫面可正常呈現；最後停在總覽，未連線耳機。
- UI 顯示「藍牙已開啟，按搜尋裝置」，不是僅用 shell 推測可存取藍牙。
- 尚未用**新 App**對耳機執行實機操作；沿用的拍照／錄影證據來自之前的 Swift client。

本輪 shell 無法解析 `github.com`，不能直接 `git clone`／push 或下載 pip 套件。透過 GitHub connector 讀取原始檔；已校驗原始 blob SHA 及 tree SHA，恢復**與 upstream SHA 完全相同的 shallow Git 基底**，不是另建不相關歷史。若要完整歷史，在一般可上網 Terminal 執行 `git fetch --unshallow origin`。請先看 `git status`、`git log -1` 和 GitHub 的實際分支；不要把 shallow 狀態誤認成專案歷史遺失。

## 接手第一輪直接做

1. 讀本文件、`docs/APP_GUIDE.md`、`docs/E900_VALIDATION_2026-11-06.md`。
2. 檢查 `git status`；保留使用者與其他 agent 的改動。
3. 執行 `bash scripts/test-macos.sh` 和 `bash scripts/build-macos.sh`。
4. 先 review 下方「優先補強」，完成可自行驗證的程式修正，再安排最短的實機驗收。
5. 如果 George 要 iPhone App，明確釐清平台後再新增 iOS target；不要默默改寫掉現有 Mac 工具。既有 repo 原始長期目標提過 iPhone Bridge，但這輪先沿用已成功的 Mac 控制路徑。

```bash
cd /Users/georgechen/Documents/Codex/2026-11-07/repo-https-github-com-pcpcchen-coder/E900EarPhoneCam
git status --short
bash scripts/test-macos.sh
bash scripts/build-macos.sh
open "dist/E900 Control.app"
```

需要 Apple 的 Swift 工具鏈；無第三方 Swift 套件。

## 已有的硬體證據：不要重做整輪探索

權威文件是 `docs/E900_VALIDATION_2026-11-06.md`。目前只有一台 E900 的證據，硬體／韌體版本尚未獨立確認。

| 項目 | 證據與可信範圍 |
|---|---|
| GlassX | 使用者已綁定；可遙控拍照、錄影；可匯入照片與可播放影片 |
| E900 BLE 身分 | 開／關機比較找到目標，已列舉 GATT |
| 指令通道 | AA12 service，AA13 write-with-response，AA14 notify |
| 檔案通知 | AA15 notify；看過 PHOTO_START／JPEG chunks／PHOTO_END，舊工具未重建完整照片 |
| 電量查詢 | `AB 55 00 03 17 00 17` 有有效回覆；標準 2A19 曾回空內容 |
| 高畫質拍照 | `AB 55 00 03 22 31 53`；耳機回覆、狀態與實際照片已確認 |
| 開始錄影 | `AB 55 00 02 23 23`；錄影狀態與實際影片已確認 |
| 停止錄影 | `AB 55 00 02 24 24`；錄影旗標 1→0，有可播放影片 |
| Wi-Fi 原檔下載 | **未驗證**；曾準備測試工具與文件，不能視為已成功 |
| 其餘設定、語音、live、OTA | 主要來自 E09 參考，**不是這台 E900 的實機結論** |

AE00／AE01／AE02 也存在，但用途未知，本 App 不使用。

## 參考協定：已有完整副本

檔案：`docs/references/e09/REVERSE_ENGINEERING_EYEVUE_BLE_PROTOCOL.md`，版本 2.1。

來源：`sctg-development/ai-smart-glasses-e09`，固定在 `c32e065ebbea769184df5abda9e43774631e1eca`。授權與來源說明見 `docs/references/e09/NOTICE.md`，不要移除署名／注意事項。上游 README 說 MIT，但固定版本缺少其連結的 LICENSE；既有文件已說明此狀況。

使用者先前說「就當作它一樣」：可依 E09 開發候選功能，**不等於新增 E900 實機證據**。請避免再要求他把所有 E09 命令先驗完才動工。

### 必須保留的協定細節

- TX SOF `AB55`，RX `AC55`；16-bit big-endian length，計算 command + payload + checksum；checksum 是 command/payload 加總 modulo 256。
- 每個 characteristic 各用獨立 parser；處理分包、合包、雜訊與錯誤 checksum。
- `0x17` response 的電量是 E09 BCD nibble：`(p0 & 15)*10 + (p1 & 15)`；`p2` 是充電旗標。這台 E900 回覆曾是 `39 37 00`，App 顯示 97% 時明標 E09 解碼，沒有獨立電量量測。
- `0x53` push 不同：`p0` 充電、`p1` raw percentage，不能套用上述 BCD。
- `0x45` ACTION_SYNC：byte0 拍照、byte1 錄音、byte2 錄影；byte8 佩戴、byte9 匯入（後兩者目前未完整呈現）。
- `0x25` 是 UTF-8 SSID，要去尾端 NUL 並檢查長度／控制字元。
- `0x95` 四位元組 BE capability mask；bit0 live、bit7 wake word、bit8 offline voice，其餘見參考文件。
- `0x97/98/99` 在不同通道有不同語意；不要把 AA14 喚醒通知當 AA15 JPEG。
- 縮圖 `0x98` 前四 bytes 是**位元組 offset**，不是 chunk index；要按 offset 放資料。重送 chunk 不可直接串接。
- `0x97` 宣告的 JPEG size 在 E09 實測曾比實際少 500 bytes，不可硬要求相等。
- AA15 也有 `52 58 ... 58 52` 包裝，和 AC55 command frame 不同；本版只識別並記錄此格式，尚未完整解碼。
- `0x22` ack 通常回 `01`，不 echo `30/31` 畫質參數。
- **0x39 是 OPEN_WIFI，0x63 是 OTA，完全不同。**
- **0x44 payload `30 00` 可能清除耳機內全部媒體；`30 01` 才是保留原檔。** 不要用清空命令做下載結束清理。
- `0x34` 是本機錄音，不是 BLE mic stream；音檔走 Wi-Fi。
- `0x57 [00]` 啟動 mic stream，`0x56 [00]` 停止；`0x0A` 也會觸發串流，沒有可靠自動停止事件，必須有 timeout／停止策略。
- `0x71` E09 response 的語音開關是反向 bit；0 代表開。不能直接把它當一般布林值。

## 程式架構與已做範圍

Swift Package executable，SwiftUI + AppKit + CoreBluetooth + URLSession + AVFoundation；macOS 13+，目前在 Apple Silicon 編譯。沒有 Xcode project、沒有 App Store signing／notarization、沒有 iOS target、沒有後端。

| 檔案 | 責任 |
|---|---|
| `app/Package.swift` | executable 與 XCTest target |
| `app/Info.plist` | bundle identity、藍牙／區域網路使用描述、允許本地 HTTP |
| `app/Sources/E900Control/App.swift` | sidebar 七頁、概覽、攝影、語音、診斷、操作確認 |
| `Headset.swift` | 掃描、手動選裝置、GATT、通知、command queue、timeout、狀態、raw voice 匯出 |
| `Protocol.swift` | frame encode/parser、JPEG offset assembler、hex／BCD、已知命令 catalog |
| `SettingsView.swift` | 設定選單、五手勢、時間、語音開關、進階 hex 控制 |
| `Media.swift` | file list JSON/XML、private IPv4/path 檢查、拒 redirect、下載、媒體驗證 |
| `MediaView.swift` | AP/P2P、SSID、Wi-Fi 設定入口、多選下載、RTSP 外部播放器 |
| `app/Tests/E900ControlTests/ProtocolTests.swift` | 九項協定／媒體解析單元測試 |
| `scripts/build-macos.sh` | release build、建立 .app、ad-hoc codesign |
| `scripts/test-macos.sh` | 可在本環境運行的 XCTest 命令 |
| `Launch E900 Control.command` | 首次 build、開啟 .app 的便捷入口 |
| `docs/APP_GUIDE.md` | 操作步驟、完整功能覆蓋表、實機驗收 checklist |

### App 現有操作

1. **總覽**：掃描所有附近廣播、手動選自己的裝置、連線、電量、錄影／錄音狀態、資訊查詢。
2. **攝影與錄音**：高畫質／縮圖拍照、開始／停止影片與本機錄音、縮圖數量、索引狀態、拉圖、預覽。
3. **裝置設定**：亮度、佩戴、模式、方向、同步時間；前／後滑及單／雙／三擊配置；離線語言及語音開關。
4. **音樂與通話**：播放、暫停、上下首、音量、三種音量查詢、接聽／掛斷、A2DP 配對請求。
5. **媒體管理**：AP/P2P、實際 SSID、手動加入 Wi-Fi、JSON/XML 清單、選資料夾、多選下載、取消、本機開啟、RTSP 啟動／外部播放器入口。
6. **語音助手**：狀態、mic stream 開始／停止／取消、AI 回覆取消、拍照辨識觸發、封包計數與匯出。
7. **診斷與進階**：raw reply、已知命令白名單＋hex payload、維護操作確認、記錄匯出、OTA 限制說明。

只有 battery/photo/videoStart/videoStop 標記為既有 E900 verified；其餘需手動開啟候選模式。選單上的設定是**準備送出的值**，不是讀回後的裝置真實值。破壞性操作與任意 hex 寫入要求再輸入「確認」。

### 媒體下載行為

- 只接受使用者輸入的 RFC1918 私有 IPv4，候選預設 `192.168.169.1`，另一候選 `192.168.49.207`。
- GET `/app/getfilelist`；JSON `result=0`, `info[].files[].name`；XML fallback `<File><NAME>...`。
- `name` 已含 folder，不再把 group folder 加一次。
- 拒絕絕對路徑、dot segment、空 segment、反斜線、控制字元、`%`、冒號及外部 URL；不跟 HTTP redirect。
- filename 以 UUID 前綴另存至使用者選的資料夾，不覆寫原有檔案。音訊／影片用 AVFoundation 檢查有效 duration 與對應 track，圖片檢查能否解碼。
- 不假設 file-list size 欄位是 byte，不盲做 size 相等驗證。
- 成功／失敗分開列出；原檔不清除；未實作自動 join Wi-Fi、斷點續傳或內嵌 RTSP decoder。

## 本輪驗證結果

- Swift debug build 成功。
- release `.app` 成功，`codesign --sign -` 完成。
- 九項 XCTest 全部通過（既有硬體封包、每個分包位置、合包／雜訊／checksum、BCD／hex、縮圖亂序／重複／缺塊／惡意 offset、host/path isolation、JSON/XML、verified/destructive 標記）。
- 原生 UI 成功開啟，總覽／設定／媒體頁可讀，未連線時操作有 disable，狀態保持未知。
- 未完成新的耳機實機驗收，沒有執行 reset/delete/OTA。
- 沒有 HTTP 真機或 mock server 整合測試、沒有 CoreBluetooth mock／command lifecycle 自動測試；不要把九項 parser tests 說成端到端驗證。

編譯環境細節：Swift 6.4.2 預設 swiftbuild 的 release `dsymutil` 在受限 shell 出現 `Operation not permitted`；build/test script 改用 `--build-system native` 才成功。這個選項在 Swift 6.4 有 deprecated warning，未來需評估移除限制或新版 backend，不能忽略未來相容性。module／SPM cache 指向 `/tmp/e900-*`，避免寫入受限的使用者快取。舊版 Swift 是否接受全部 script 參數尚未另驗。

shell 的 `open` 曾出現 `kLSNoExecutableErr`，但檢查 Mach-O／Info.plist 正常，使用 native app launcher 成功開啟；不要憑 shell 那條錯誤認定 .app 無法啟動。真正畫面已確認 Bluetooth poweredOn。

## Claude Code 接手進度（2026-11-07）

已完成（程式與自動測試；**皆未做新的耳機實機驗收**）：

- **P0 全部**：`CommandCoordinator`（逾時／遲到回覆／斷線／GATT 錯誤／停止插隊與搶先）、停止類按鈕連線後一律可用、`VoiceSession`（停止確認前維持作用中、重送上限、token 化 auto-stop、被動喚醒）、媒體以清單＋主機＋檔名對應、XML 錯誤處理、`MediaDownloader` 與 URLProtocol 整合測試。
- **P1**：依固定上游反編譯 `SendCommandViaBle`／`ModBleResponse` 補齊 0x02、0x35、0x32、0x70、0x72、0x59 編碼及查詢參數位元組；修正音量增減誤用 0x70；AA15 `52 58` 包裝完整解碼（照片預覽可組裝）；能力位元具名顯示、能力未知不啟動 live；0x48 回讀對應手勢／佩戴／方向／錄影時長選單；Ogg Opus 匯出（已用 opusinfo／opusdec 驗證 muxer）。
- **P2 部分**：macOS CI（測試＋建置＋上傳 .app zip）；build script 相容不支援 `--build-system` 的舊 Swift。

仍未完成：0x03 麥克風值域、0x35 位元組意義實機確認、內嵌 RTSP、Developer ID 簽署／公證、icon、iOS client、OTA（維持不做）。

## 優先補強：請先做 P0，再擴充功能

### P0 — 控制與下載狀態可靠性

- **command queue 測試與設計**：目前依 commandId match 回覆，5 秒逾時不重送；遲來的同 commandId 回覆可能誤配下一筆同類指令。請抽出可測 command coordinator，定義 timeout／late reply／disconnect／GATT error。不可把協定 echo 直接當設定已生效。
- **停止操作保證可用**：Headset.run 已允許候選模式關閉時送 stop 並將 stop 插隊，但多處 UI 仍整體 disable 候選按鈕；queue 滿 20 筆也會拒絕 stop。請讓錄影／錄音／mic stop 在已啟動後始終可用；自動 30 秒停止不能被一般候選命令排隊拖太久。新實機測試前先修。
- **串流 session lifecycle**：檢查停止回覆、下一個 queued start、斷線、晚到回覆及 `voiceActive` 的更新順序；不能讓 auto-stop 還在作用但 UI 誤認已停止。現在聲音只保存有主動啟動的 session，沒有完整被動 wake-word pipeline。
- **媒體跨主機狀態**：`saved` 目前用 `name` 當 key；重新列另一台／另一個 host 同名檔可能顯示舊本機「開啟」。需要以 host+name/session 管理，或換清單時清掉 display mapping。
- **XML 錯誤回應**：JSON 有檢查 result；XML fallback 目前主要檢查 root/File，需完整處理 XML result/error，避免錯誤文件誤當空清單成功。
- 增加 URLSession mock／本地 test server，涵蓋 redirect、HTTP 非200、空檔、下載取消、壞圖片／影片、不同 host、部分失敗及保留原檔。不需要每輪重寫一堆鏡像實作的測試。

### P1 — 補齊真正可用的設定與資料通道

- 查固定上游實作的**實際 sender 編碼**，補齊 `0x02` 錄影時長、`0x03` 麥克風、`0x35` 畫質／比例、`0x32` AI volume；目前沒有亂猜 byte width／順序，只有進階手動 hex。
- 語音助手 `0x72` sender 編碼及手勢回讀對 UI 的映射需核實；目前讀回 raw bytes，選單預設不是裝置真值。
- 實作 AA15 `52 58` 的完整 deframe／checksum 行為，確認和 AC55 子幀的關係；完整 JPEG 才顯示，可保存 preview，但要標低解析。
- capability mask 解碼與更完整 status（佩戴／匯入等），主動更新 UI；能力未知時先 query，再啟動 live，而不是把未知當支援。
- Opus 現在是封包存檔，不可播放。若要「串流錄音可聽」，新增正確 Opus→Ogg mux／decode，驗證取樣率、channel、packet duration；不要把 `.opuspackets` 改副檔名冒充音檔。
- 若實際使用需要內嵌 RTSP，先選可靠 macOS decoder；目前只開外部 VLC 等 handler，沒有把 Safari/AVPlayer 當通用 RTSP 支援。

### P2 — 發行與未定需求

- `.app` icon、Developer ID signing／notarization、安裝／更新方式、可重現 CI、release archive。
- 需要時新增 iOS client，處理 BLE 權限、background、加入耳機網路、手機媒體匯入與 A2DP/HFP 行為。
- ASR／LLM／TTS、R08／AIOS／Nous integration 留待 George 決定應用；現在不收集 API key、不上傳音訊。
- **OTA 尚未可安全完成**：缺可信 E900 firmware、板號／版本識別、完整性與相容性驗證、失敗復原方法。不解鎖 0x63 或用 E09 firmware 假充支援。

## 下一輪最短實機驗收

使用者開機並處理必要權限後，先只驗新 App 的連線與既有拍照／影片控制；不要求重新做全部 BLE 探索。若他不想測，不要改寫為已驗證，繼續可離線完成的 P0/P1 工作。

| Gate | 通過條件 |
|---|---|
| 連線 | 只連使用者選的 E900，AA13 write + AA14/15 subscribe 成功，收到有效電量回覆 |
| 拍照 | 有協定回覆／狀態，且真正有新增照片；不以 TX log 作驗收 |
| 影片 | 開始後 isTakeVideo=1，停止後=0，能取得並播放真正影片 |
| 斷線 | 清掉 ready／writer／queue／未完成 session，狀態回未知，重新連線不重播舊快門 |
| Wi-Fi | 耳機回報真 SSID→加入→真正 file list→照片及影片成功下載與驗證，原檔仍在 |
| 候選設定 | 逐項讀回／實際效果確認，失敗保留原始回覆與未驗證標記 |

不要為了驗收而實機執行恢復原廠、清配對、清空媒體或 OTA。

## 可直接交給 Claude Code 的起始 prompt

```text
請接手 pcpcchen-coder/E900EarPhoneCam 的 codex/e900-control-app 分支。
先完整讀 docs/CLAUDE_CODE_HANDOFF.md、docs/APP_GUIDE.md 與既有 E900 實機報告。
這是 Mac 原生控制 App 第一版，並非所有功能已通過實機；不要重頭搭架構。
先跑測試與 release build，review 既有程式，完成 handoff 的 P0 狀態／停止控制／下載可靠性修正，補有意義的 lifecycle 與 HTTP 整合測試。
再依固定上游 sender 補齊未確定的設定編碼與 AA15 資料通道。
盡量直接操作，只有需要我處理實體耳機或權限時才給我一個明確步驟。
不要執行實機刪除、重置或 OTA，也不要把 E09 推測冒充 E900 已驗證。
應用用途、AI 服務與是否做 iPhone App 等我決定；先把耳機控制工具做完整、可靠。
```
