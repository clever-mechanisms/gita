# Releasing Gitā

Gitā is distributed as a free, MIT-licensed, universal macOS direct-download archive (`Gita-<version>-macos.zip`) with
ungated Sparkle 2 updates at `https://getgita.app/appcast.xml`. It uses no licensing server and never touches the
Keychain (`SecItem*` and `import Security` are blocked by the quality gate).

## Version and tag convention

- Bump `MARKETING_VERSION` in [Config/Product.xcconfig](../Config/Product.xcconfig).
- Historical tags (`0.1.0`, `0.2.0`, `0.2.1`) used bare version numbers; releases going forward use `v<version>`
  (for example, `v0.2.2`), matching the GitHub Release enclosure URL recorded in `.release.txt`:
  `https://github.com/clever-mechanisms/gita/releases/download/v<version>/Gita-<version>-macos.zip`.

## Building and notarizing a release

1. Ensure the full quality gate is green:

   ```sh
   scripts/quality.sh
   ```

2. Build, sign with Developer ID (Hardened Runtime + secure timestamp), notarize, staple, package
   `build/Gita-<version>-macos.zip`, verify post-extraction, and sign the archive with the shared Clever Mechanisms
   Sparkle EdDSA key:

   ```sh
   GITA_SIGN_IDENTITY="Developer ID Application: … (PCZ6F8Q9DZ)" \
   GITA_NOTARY_PROFILE=gita-notary \
   CONFIG=release ARCH=universal \
   scripts/build.sh
   ```

   Pass `NO_REVEAL=1` to skip revealing the ZIP in Finder (`open -R`).

   For a local unsigned dry run of ZIP packaging and post-extraction checks:

   ```sh
   CONFIG=release ARCH=universal PACKAGE_ZIP=1 NO_REVEAL=1 scripts/build.sh
   ```

### Outputs

- `build/Gita-<version>-macos.zip` — universal (`arm64` + `x86_64`) notarized and stapled app archive
- `build/Gita-<version>-macos.zip.sha256` — SHA-256 checksum
- `build/Gita-<version>-macos.release.txt` — release metadata (`version`, `build`, `filename`, `zipPath`, `sizeBytes`,
  `sha256`, `edSignature`, `feedURL`, `downloadURL`) ready for the `getgita.app` appcast update

## Automated guards and verification

- `scripts/build.sh` strips release debug maps (`strip -S`), enforces `REQUIRE_LOCALIZATIONS=1` on release/notarized
  builds, compiles `Assets.car` + `AppIcon.icns` (`CFBundleIconName=AppIcon`), removes unneeded Sparkle sandbox
  `XPCServices` before inside-out signing, and unregisters build copies from Launch Services on `EXIT` via
  `scripts/unregister-build-apps.sh`.
- `scripts/verify-zip.sh` extracts `Gita-<version>-macos.zip` into a temporary `.noindex` folder and checks strict
  codesign, Developer ID + Hardened Runtime + `stapler validate` + `spctl --assess`, universal `arm64`/`x86_64` slices
  on `Gita` and `gita-agent`, `Assets.car`, `ThirdParty-Notices.txt`, at least 19 `.lproj` localizations, and
  `scripts/check-updater.sh`, then unregisters and removes the temp copy.
- `scripts/check-updater.sh` validates `Sparkle.framework`, universal slices, `@rpath/Sparkle.framework`,
  `SUFeedURL = https://getgita.app/appcast.xml`, a 32-byte base64 `SUPublicEDKey`, `SUEnableAutomaticChecks = true`,
  `SUSendProfileInfo = false`, `SUVerifyUpdateBeforeExtraction = true`, and strict nested signatures.
- `scripts/install.sh` atomically installs `/Applications/Gita.app` (never falling back to `~/Applications`), archives
  replaced copies as `.zip` backups (deleting the temporary `.app` only when `ditto` succeeds and produces a non-empty
  archive), rolls back and re-registers `/Applications/Gita.app` on failure, and enforces `scripts/check-one-copy.sh`.
- `scripts/perf.sh` measures installed Release CPU %, RSS MiB, and idle wakeups across `idle`, `panel`, `panel-closed`,
  `window`, and `after-close` states.

## Sparkle appcast

- Feed URL: `https://getgita.app/appcast.xml`
- Shared Clever Mechanisms EdDSA public key (`SUPublicEDKey`): `TwKjQ7USQKbkf0Q0zq6N+17GXDxhmxXlxteHJn0T4jE=`
- Signing uses Sparkle's `sign_update -p <zip>` with the default login-keychain entry (never `--account`), verified
  against `SUPublicEDKey` via `generate_keys -p`.
