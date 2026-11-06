# E09 upstream protocol snapshot

- Source project: https://github.com/sctg-development/ai-smart-glasses-e09
- Author/publisher: sctg-development and upstream contributors; attribution is retained in the copied document.
- Pinned upstream commit: `c32e065ebbea769184df5abda9e43774631e1eca`
- Original document: https://github.com/sctg-development/ai-smart-glasses-e09/blob/c32e065ebbea769184df5abda9e43774631e1eca/REVERSE_ENGINEERING_EYEVUE_BLE_PROTOCOL.md
- Retrieved: 2026-11-06 (Asia/Taipei)
- Document's stated version: 2.1.
- The adjacent protocol file is a full content snapshot, not an E900-specific specification. Keep it separate from local validation findings.

## Upstream licensing notice

The upstream README explicitly states MIT License and links to `LICENSE`. At the pinned commit, that linked file returns 404 and no license file is present in the root directory listing. This copy preserves the upstream document and its original disclaimer. We do not invent a missing copyright notice or claim that the upstream document was authored by this project. Resolve the missing license text with upstream before redistributing it as a licensed dependency in a product.

## Related upstream projects

- macOS BLE probe: https://github.com/sctg-development/ai-smart-glasses-e09-reverse
- Flutter client: https://github.com/sctg-development/ai-smart-glasses-e09-flutter
- Firmware research: https://github.com/sctg-development/ai-smart-glasses-e09-firmware-downloader (reference only; not used for this test).

## E900 applicability

Validated on one E900 unit: matching GATT services, command framing, battery query response, photo trigger and actual photo, video start/stop and actual playable video. This is partial compatibility; it does not validate all commands, Wi-Fi, RTSP, audio streaming, gesture configuration, or OTA. See ../../E900_VALIDATION_2026-11-06.md.
