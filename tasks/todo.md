# AltStore distribution + sideload

- [x] SharedInbox resolves the App Group from `ALTAppGroups` (AltStore renames it to `group.com.pagepocket.app.<TEAMID>`)
- [x] `scripts/build-ipa.sh`: Release iphoneos build, ad-hoc sign with entitlements, package `PagePocket.ipa`
- [x] `altstore/source.json` + `scripts/update-altstore-source.py`
- [x] `.github/workflows/release.yml`: on `v*` tag → build ipa → GitHub Release → update source.json on main
- [x] README: AltStore section
- [x] Verify locally: build ipa, check entitlements in signature, unit tests pass, JSON valid
- [ ] (check in) push + tag v1.0.0, add source in AltStore on phone
