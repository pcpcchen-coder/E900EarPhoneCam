# Phase 4 — Wi-Fi media download (E900 NOT YET TESTED)

Reference: [pinned E09 protocol](references/e09/REVERSE_ENGINEERING_EYEVUE_BLE_PROTOCOL.md), section 10. Partial BLE compatibility is confirmed; Wi-Fi compatibility is a hypothesis.

## 1. Open the AP

Keep E900 powered on and iPhone Bluetooth off. In normal macOS Terminal:

```bash
swift -module-cache-path /tmp/e900-swift-cache tools/e900_wifi_open.swift 2>&1 | tee /tmp/e900-wifi-open.log
```

This session helper expects `/tmp/e900-ble-candidates.json` from our local comparison scan, with exactly one `second_scan` record named E900-1928 and its locally saved CoreBluetooth identifier. It does not embed that identifier in the repo and does not connect to arbitrary nearby peripherals. If that file is missing or the unit changes, re-run discovery and adapt the helper before continuing. It is a session helper, not a general E900 SDK.

Sequence: connect saved unit → subscribe AA14/AA15 (CCCD changes) → validated battery query response → send one `AB 55 00 03 39 30 69` OPEN_WIFI/AP candidate → validate `0x25` UTF-8 SSID. It will not guess another mode or retry unknown commands. It logs and saves SSID locally in `/tmp/e900-wifi-info.json` and keeps BLE connected for up to ten minutes. It does not join Wi-Fi automatically, send download-finish commands, delete files, alter capture settings, or invoke OTA. AP behavior after disconnect is not yet known.

When WIFI READY appears, leave the process running and return to chat before switching networks. We first inspect its actual response.

## 2. Join only the actual SSID

After inspecting the response, join that SSID through macOS Wi-Fi settings. E09 candidate password is `12345678`; it is not an E900-verified credential. Do not try unrelated nearby networks. If Mac has only Wi-Fi Internet, joining a camera AP may temporarily interrupt chat; keep Ethernet or another way to return to the original network available. Do not change Wi-Fi until the response is reviewed.

## 3. Read-only HTTP checks

E09 candidates only: `192.168.169.1`, then `192.168.49.207`. Identify the actual interface/routing and do not probe external hosts.

In a second Terminal tab after joining:

```bash
curl --noproxy '*' --connect-timeout 3 --max-time 10 --fail --show-error \
  http://192.168.169.1/app/getfilelist -o /tmp/e900-filelist.json
```

If the candidate fails, preserve the error and check local routing before testing the other documented IP. Do not assume an empty/error response is a successful listing.

Reference response: JSON `result=0`, `info[]` groups containing `files[]`; filenames already contain their folder prefix. An XML variant is possible. Treat all filenames as untrusted data: reject absolute paths, dot/dot-dot components, control characters, and cross-host URLs. Never paste an unescaped returned filename into a shell command.

## 4. Download and verify

Select one listed JPEG and one listed video. Download via HTTP GET only, save originals to an ignored local `captures/` directory, do not overwrite existing files, and verify successful HTTP status, nonzero length, image decoding, and video streams/duration. The upstream size field's units are not established, so do not equate it blindly with bytes. Preserve returned metadata separately. Do not publish raw SSIDs, peripheral identifiers, media, or file lists containing personal information.

## 5. End without deletion

Do not send arbitrary finish commands during discovery. E09 `0x44` payload `[0x30,0x00]` deletes media; it is prohibited in this test. The documented non-delete variant is `[0x30,0x01]`, frame `AB 55 00 04 44 30 01 75`, but E900 cleanup compatibility must be verified separately. Keep original media on the headset throughout this test. Never use OTA `0x63` in place of OPEN_WIFI `0x39`.

Acceptance: actual SSID observed; actual file list read; at least one photo and video downloaded without GlassX; both readable; originals retained; no OTA/deletion operations. Mark each gate separately.
