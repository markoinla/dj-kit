# Releasing

Signed with Developer ID, notarized, shipped as a DMG on GitHub Releases. Installed copies update
through Sparkle from `https://github.com/markoinla/dj-kit/releases/latest/download/appcast.xml`
(`SUFeedURL` in `app/project.yml`), so every release must be marked **latest** and carry
`appcast.xml`. The script does that.

```bash
scripts/release.sh --dry-run 0.2.0                   # unsigned end-to-end check, no credentials
scripts/release.sh --publish 0.2.0                   # build, notarize, commit, tag v0.2.0, release
scripts/release.sh --publish --notes notes.md 0.2.0  # with your own notes (else generated from commits)
```

Run on main with a clean tree (only `app/project.yml` may differ). Output: `app/build/release/`.

What it does: bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (Sparkle's build number; up
by one per new version) → `xcodegen` → archive Release, arm64 only, Developer ID → export
(`app/ExportOptions.plist`) → notarize + staple the app → DMG (`dmgbuild` via `uvx`,
`scripts/dmg/settings.py`) → sign, notarize, staple the DMG → Sparkle `sign_update` → append to
the live appcast → commit, tag, push → `gh release create` (draft with the DMGs, then the
appcast, then published as latest).

Assets per release: `DJ-Kit-<version>.dmg` (the appcast points here), `DJ-Kit.dmg` (same file;
`releases/latest/download/DJ-Kit.dmg` is the stable download link), `appcast.xml`.

## One-time setup (done on the release Mac)

- **Developer ID Application** certificate for team `M44R9APYMG` in the login keychain.
- **Notary**: keychain profile `djkit-notary`, made from the App Store Connect Team API key
  `KEYID` (`~/.appstoreconnect/private_keys/AuthKey_KEYID.p8`):
  `xcrun notarytool store-credentials djkit-notary --key <p8> --key-id KEYID --issuer <issuer id>`.
  Or set `NOTARY_KEY_PATH` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID`.
- **Sparkle key**: login keychain, account `djkit` (separate from Wax Studio's). Public key is
  `SUPublicEDKey` in `app/project.yml`. Made with
  `app/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account djkit`;
  backed up in a password manager .
  `SPARKLE_PRIVATE_KEY_FILE` overrides the keychain. **If the key is lost, installed copies can
  never be updated again.**
- `gh` logged in with push access; `uv` (for `uvx dmgbuild`).

Debug builds never start the updater (`Updater.isEnabled`); `-uiPreviewUpdate 0.2.0` shows the
sidebar card.
