# AltStore distribution + sideload

- [x] SharedInbox resolves the App Group from `ALTAppGroups` (AltStore renames it to `group.com.pagepocket.app.<TEAMID>`)
- [x] `scripts/build-ipa.sh`: Release iphoneos build, ad-hoc sign with entitlements, package `PagePocket.ipa`
- [x] `altstore/source.json` + `scripts/update-altstore-source.py`
- [x] `.github/workflows/release.yml`: on `v*` tag → build ipa → GitHub Release → update source.json on main
- [x] README: AltStore section
- [x] Verify locally: build ipa, check entitlements in signature, unit tests pass, JSON valid
- [x] (check in) push + tag v1.0.0, add source in AltStore on phone

## Review (2026-09-27)
- v1.0.0 released by CI; source.json live on main; IPA downloads (HTTP 200).
- 60 unit tests pass locally (5 App Group tests skip on unsigned simulator, as before).
- Bug found and fixed after the first run: actions/checkout makes the tag lightweight, so release notes used the commit message. The workflow now re-fetches the tag.
- Not yet verified: installing through AltStore on a real device.
