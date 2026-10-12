# Supplemental distribution notices

These text assets supplement Flutter's generated primary package licenses.
They must be registered in the app's readable licenses surface and included in
packaged builds. Adding source assets alone does not verify binary packaging.
Do not apply the Ayumitra app's license to third-party notice text.

- `ayumitra.txt`: verbatim repository `NOTICE` followed by official Apache-2.0
  `LICENSE`. Keep synchronized with those files.
- `image_third_party.txt`: byte-for-byte `image` 4.12.0 `LICENSE-other.md` from
  its resolved pub package. Its primary MIT license remains in Flutter notices.
- `roboto_legacy.txt`: byte-for-byte Apache-2.0 `web/assets/fonts/ROBOTO-LICENSE.txt`,
  verified against the archived `googlefonts/roboto-2` source license. Applies
  to the bundled legacy browser font, not all later Roboto releases. Keep this
  separate asset in the shared license registry for preview and native builds.
- `pdfium_android.txt`: verbatim distributor `LICENSE` and every file in
  `licenses/` from `bblanchon/pdfium-binaries` **chromium/7811**
  `pdfium-android-arm64.tgz` (19 payloads in total). Section labels identify
  original filenames; the license bodies are unmodified.
- `pdfium_ios.txt`: equivalent payload from `pdfium-ios-device-arm64.tgz`
  (16 files). The simulator ARM64 archive has identical license payloads.

## PDFium provenance

The exact Android native asset currently fetched by `pdfium_dart` 0.2.5 matches
the downloaded publisher archive's `lib/libpdfium.so` byte-for-byte. Its archive
SHA-256 is `f51539cadeb5135534305b8bdf8685ce2fbe9991dbbc5b35f553108411b9ed14`.

`pdfium_flutter` 0.2.3 pins the iOS XCFramework release
`v144.0.7811.0-20260502-190206`, ZIP checksum
`948d9257f53f01cbed74b81bb8adc8758e52ac9390751772de7889026d32d5a1`.
Its publisher identifies `bblanchon/pdfium-binaries` chromium/7811 as the source.
The installed device and simulator ARM64 binaries have the same Mach-O UUIDs
as the corresponding upstream archives:

- Device: `4c4c44a5-5555-3144-a160-f8874342ebe8`.
- Simulator: `4c4c444a-5555-3144-a116-940ee45e6a45`.

The upstream archives' `VERSION` records major version 149, build 7811, while
the XCFramework publisher's release title uses 144. The matching UUIDs establish
the native build relationship without treating these display labels as equal.
The upstream device archive SHA-256 is
`36f5b10feed4c88452517844902b5ba1530eae46dbb0d48ddd0519f841bb4224`;
simulator ARM64 archive SHA-256 is
`8be951358e21358e5436696b811b023d75653eae828cf8ac51d7fa6d8a952f6d`.

Sources:

- [PDFium upstream release](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/7811).
- [Android archive](https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-android-arm64.tgz).
- [iOS device archive](https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-ios-device-arm64.tgz).
- [iOS simulator archive](https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-ios-simulator-arm64.tgz).
- [XCFramework publisher release](https://github.com/espresso3389/pdfium-xcframework/releases/tag/v144.0.7811.0-20260502-190206).
- [Image package version](https://pub.dev/packages/image/versions/4.12.0).

## Remaining scope

This copies the publisher's complete notice payloads for these native artifacts;
it does not assert exhaustive legal coverage of every final app component.
Re-audit on dependency/native binary changes and for additional architectures.
Keep the official LiteRTLM iOS framework's own LICENSE and full
`third_party_licenses.bundle` intact. Its runtime notices are separate from these
PDFium notices. Inspect the final APK/device archive and license screen before
distributing binaries. Model weights are imported separately in the current
version; any future distributed model must carry its own publisher notices.

## Browser font provenance

The locally served Roboto WOFF2 at
`web/assets/fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2` is 63,464 bytes
and matches the declared Google Fonts source byte-for-byte. SHA-256:
`35b02ca266b79eb4996590f15817425a1ce9ebf48f84471843233ff614656bf2`.
The local upstream license and `roboto_legacy.txt` match the official repository
license bytes, SHA-256
`c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`.
Verify inclusion of both the font and its readable license in the next built
preview; source inclusion alone does not establish build packaging.

- [Exact font source](https://fonts.gstatic.com/s/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2).
- [Legacy font license](https://github.com/googlefonts/roboto-2/blob/main/LICENSE).
