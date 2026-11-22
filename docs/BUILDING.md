# Building PawShot

Requires macOS 15 or later, a Swift 6 toolchain (Xcode or the Command Line Tools), and Python 3. The Swift package has no third-party dependencies.

## Local build

```bash
python3 scripts/local-signing.py init
bash scripts/build.sh
open dist/PawShot.app
```

Initialize signing once per development machine. Keep the signing directory at `~/Library/Application Support/PawShotSigning/` private and reuse it across builds. To use an existing signing directory in another location, set `SHIGUANG_SIGNING_HOME`. A new identity may require granting macOS permissions again.

`BUILD_DIR` and `OUTPUT_DIR` can override the default `.build/` and `dist/` directories. `SWIFT_BUILD_ARGS` passes extra flags to SwiftPM, such as `--arch arm64`.

## Checks

```bash
bash scripts/test.sh
bash scripts/test-editor-features.sh
bash scripts/test-auto-ocr.sh
bash scripts/test-scroll-capture.sh
bash scripts/test-permissions.sh
bash scripts/test-clipboard.sh
bash scripts/test-finder-actions.sh
bash scripts/test-configuration-export.sh
bash scripts/test-configuration-import.sh
python3 Tests/ShiguangTests/SigningChecks.py
```

Run the full checks in a normal macOS session. In an environment without Vision pixel-buffer or video-encoder access, `test-auto-ocr.sh --skip-vision` and `test-editor-features.sh --skip-video` can run the other checks separately.

To check whether macOS registered the Finder extension, run `pluginkit -m -i dev.shiguang.screenshot.finder`.

## Packages and releases

```bash
bash scripts/package-release.sh
```

The package script builds the app and produces a DMG, ZIP, and SHA-256 checksum file in `dist/`. Use `--skip-build` to package an app that is already built. If you have a Developer ID certificate, pass its full signing identity via `SHIGUANG_SIGN_IDENTITY`.

The [release workflow](../.github/workflows/release.yml) runs when a `v*` tag is pushed or when dispatched with a tag. The tag must match `CFBundleShortVersionString` in [Info.plist](../Info.plist).

| GitHub Actions secret | Purpose |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate export |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the certificate export |
| `APPLE_SIGNING_IDENTITY` | Full Developer ID signing identity |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_TEAM_ID` | Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

The workflow signs with Developer ID when configured and notarizes when the notarization credentials are available. Without a Developer ID certificate, the workflow produces an ad-hoc signed, non-notarized package. See the release page for installation details.
