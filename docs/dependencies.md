# Dependency and model license review

Reviewed on 12 October 2026 against `pubspec.lock`, local package `LICENSE` files,
the Flutter SDK license, native plugin declarations, and `ios/Podfile.lock`.
This is a development inventory, not a completed release notice bundle or an
audit of every compiled native binary. Re-run it after dependency changes.

Ayumitra's original code is Apache-2.0. Dependencies and model weights retain
their own licenses. An open-source Flutter wrapper does not make the SDK or
model it calls open source, and on-device processing does not imply no network
traffic.

## PDF text and scan transcription

The app now extracts digital PDF text directly through its local PDF runtime
and sends scan/image transcription to the same imported **local Gemma 4 vision
model** used for assistant inference. The parser receives a local transcription
function; it has no remote OCR endpoint. Numeric values, units, and table
relationships still need evaluation on synthetic reports on the S24 Ultra and
an iPhone. Local execution alone does not establish extraction accuracy.

The MIT `google_mlkit_text_recognition` and `google_mlkit_commons` wrappers were
removed from `pubspec.yaml`, `pubspec.lock`, and the resolved Dart configuration.
This avoids introducing an engine whose official terms permit performance
metrics traffic and whose native SDK is not covered by the wrapper's open-source
license. [Official ML Kit terms and privacy](https://developers.google.com/ml-kit/terms).

The refreshed `ios/Podfile.lock` and generated CocoaPods acknowledgements no
longer contain ML Kit, MLImage, or GoogleDataTransport. Recheck the final
Android and iOS build graphs when preparing a release.

A later open-source OCR alternative is **Tesseract** with **Leptonica**, compiled
for Android/iOS with bundled English `eng.traineddata` and a small Flutter bridge.
Tesseract and `tessdata_fast` are Apache-2.0; Leptonica and enabled image codecs
need their own notices. Android build documentation and SwiftyTesseract provide
integration references, not tested Ayumitra compatibility. Tesseract is not a
current dependency or selected replacement.
[Tesseract source](https://github.com/tesseract-ocr/tesseract),
[English model repository](https://github.com/tesseract-ocr/tessdata_fast),
[Android build documentation](https://tesseract-ocr.github.io/tessdoc/Compiling.html#android),
[iOS wrapper source](https://github.com/SwiftyTesseract/SwiftyTesseract).

## Native runtimes and weights

- `flutter_edge_ai` 2.2.1 and `flutter_edge_ai_litertlm` 1.12.0 are MIT wrappers.
  Upstream LiteRT-LM is Apache-2.0, with additional third-party notices. The
  wrapper downloads native runtime artifacts during builds; preserve its
  `NOTICES` and check the exact artifacts included in release packages.
  [LiteRT-LM source and license](https://github.com/google-ai-edge/LiteRT-LM).
- An iOS native integration trial uses official **LiteRTLM 0.18.0**. Its tagged
  source and Swift wrapper are Apache-2.0. The official Swift package selects
  `CLiteRTLM.xcframework.zip` for iOS, with pinned SHA-256
  `d765b99592d4ec3d0c9e2bd69469454af06c834861340672da1891c0c121c347`.
  The checked-in Swift package resolution pins source revision
  `b2f686e2ed4718fb84ec398a61dd59ca0f0aff27`.
  The separate `LiteRTLMFoundationModels` adapter is an optional product, not
  required for running imported Gemma weights. The fetched iOS binary's notice
  payload and current simulator build were inspected as described below. This
  exact runtime release advertises EmbeddingGemma 2 support in Swift.
  [Tagged runtime license](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.0/LICENSE),
  [Tagged Swift package](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.18.0/Package.swift),
  [0.18.0 release](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.18.0).
- Qualcomm NPU support in the current LiteRT-LM wrapper is **opt-in** using
  `hooks.user_defines.flutter_edge_ai_litertlm.qualcomm_npu: true`. Its package
  README and build hook describe downloading proprietary Qualcomm QNN runtime
  2.50.0 under Qualcomm AI Stack terms. The current app does not enable this
  flag. Keep it disabled for the open runtime path; CPU/GPU runtime libraries
  still need artifact review. Platform drivers have their own terms.
- `pdfrx` and its Dart/PDFium wrappers are MIT. Native PDFium's upstream license
  contains BSD-3-Clause and Apache-2.0 material, with other bundled component
  licenses. The wrapper can acquire native binaries during builds. Preserve
  notices for the particular binary instead of treating the wrapper's MIT
  file as the entire PDF stack's license.
  [PDFium license](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/LICENSE).
- **EmbeddingGemma 2** and **Gemma 4** are Apache-2.0 according to their current
  official documentation. Earlier Gemma families and EmbeddingGemma 1 have
  different licensing; do not infer a version's license from another release.
  Record each chosen artifact's publisher, version, hash, model card, license,
  and conversion provenance before distributing it. Apache-2.0 weights still
  retain their own publisher's notices independently of the app's license.
  Check the exact converted mobile artifact as well as the original weights.
  [EmbeddingGemma 2 documentation](https://ai.google.dev/gemma/docs/embeddinggemma),
  [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4),
  [legacy Gemma terms](https://ai.google.dev/gemma/terms).
- `image` 4.12.0 has MIT primary code plus `LICENSE-other.md` for ported codecs
  and components. Preserve that additional file when preparing notices.
- `dbus` 0.8.0, a transitive Linux dependency, uses MPL-2.0. Its covered files
  retain their license; distributing modifications requires the corresponding
  source obligations. It is not evidence that the mobile app itself uses DBus.

## Before distributing a build

1. Audit the final Android and iOS dependency
   graphs, including build-hook downloads, frameworks, and bundled assets.
2. Generate and include complete third-party licenses/notices for the exact
   release. Include extra notice files and native components; a table alone
   does not satisfy attribution obligations.
3. Keep model licenses and attribution alongside artifact metadata. Establish
   whether models are bundled, explicitly downloaded during setup, or imported.
4. Test offline report ingestion and inference after setup. Observe network
   traffic to confirm that OCR and inference make no undeclared requests.
5. Review internet search independently: requests may contain general queries
   only, never private record text or identifiers. There is no cloud inference
   fallback or remote OCR endpoint.

## Camera capture dependency review

`image_picker` resolves to **1.2.4**. Its main, Android, and iOS package license
files include Flutter BSD-3-Clause code and Apache-2.0 material attributed to
Paul Burke; retain the complete files rather than reducing them to one license.
The other 10 newly resolved camera/file-selector packages use BSD-3-Clause.
These primary files should enter Flutter's generated license payload after the
next build; inspect the packaged notices following that rebuild.

The Android plugin declares AndroidX `core` 1.18.0, `annotation` 1.10.0,
`exifinterface` 1.4.2, and `activity` 1.13.0. Their exact publisher Maven POMs
declare Apache-2.0. The downloaded `core` AAR also includes
`META-INF/androidx/core/core/LICENSE.txt`. Preserve Maven/native notices for the
final resolved dependency graph; this package-level inventory is not that full
graph. The iOS plugin adds only Flutter as a pod dependency and uses platform
camera/photo APIs. Its included privacy manifest declares no tracking,
collected data types, or tracking domains.
[Core POM](https://dl.google.com/dl/android/maven2/androidx/core/core/1.18.0/core-1.18.0.pom),
[Annotation POM](https://dl.google.com/dl/android/maven2/androidx/annotation/annotation/1.10.0/annotation-1.10.0.pom),
[ExifInterface POM](https://dl.google.com/dl/android/maven2/androidx/exifinterface/exifinterface/1.4.2/exifinterface-1.4.2.pom),
[Activity POM](https://dl.google.com/dl/android/maven2/androidx/activity/activity/1.13.0/activity-1.13.0.pom).

The app currently declares Android camera permission and an optional camera
hardware feature, plus camera/photo-library usage descriptions on iOS.
Report capture does not require a microphone usage permission. Image Picker
uses temporary local cache files; cleanup after vault encryption and startup
handling of interrupted captures require app-level verification.
[Versioned Image Picker documentation](https://pub.dev/packages/image_picker/versions/1.2.4).

One integration detail affects networking: the Android plugin manifest includes
disabled Google Play services `ModuleDependencies` metadata that requests
installation of a backported photo-picker module on older Android versions.
That is a potential setup download by the platform, not remote OCR or inference.
The S24 Ultra's Android 13+ path uses the built-in picker. Review the final merged
manifest and disable the backport request if the app promises no implicit setup
downloads. Platform camera apps and photo libraries have their own behavior;
using a local capture plugin alone cannot prove the entire device makes no
network requests.

## Bundled browser font

The browser preview bundles the legacy Roboto WOFF2 file
`web/assets/fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2` so its default
English font is served locally. The 63,464-byte file matches its declared
Google Fonts source byte-for-byte, SHA-256
`35b02ca266b79eb4996590f15817425a1ce9ebf48f84471843233ff614656bf2`.
The font's source repository is the archived Apache-2.0 **Roboto 2** project;
later Roboto families may use different licensing. Its bundled license matches
that repository's license bytes. The exact text is also copied to
`assets/notices/roboto_legacy.txt` for shared app license registration.
Verify the rebuilt preview contains the font and exposes the license before
distributing it. This font asset does not add a Dart package; the current
package inventory remains unchanged.
[Exact font source](https://fonts.gstatic.com/s/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2),
[Legacy Roboto source](https://github.com/googlefonts/roboto-2),
[Legacy license](https://github.com/googlefonts/roboto-2/blob/main/LICENSE).

## Inspected iOS artifact notices

Read-only inspection of the fetched official 0.18.0 iOS XCFramework found an
Apache-2.0 `LICENSE` in both the device and simulator framework slices, plus
`third_party_licenses.bundle` with **142 HTML notice files and an index**. Every
index entry has a corresponding notice file. The current generated simulator
`Runner.app/Frameworks/CLiteRTLM.framework` carries the same 144 license/index
files, byte-for-byte. Preserve this payload in device/archive builds as well.
The upstream bundle covers a broad dependency set; a notice filename alone
does not prove that component is linked into the selected iOS binary.

The simulator app also includes Flutter's compressed `NOTICES.Z`. It contains
primary package licenses, including `cross_file`, now a direct app dependency.
It does not contain the following notices, and no separate copies were found
in that generated app:

- Ayumitra's own copyright/`NOTICE`. Include the project attribution and license
  in distribution materials or a readable app credits surface.
- Native PDFium's copyright/license and complete notices for its exact bundled
  components. `PDFium.framework` is present, but only the Dart wrappers' MIT
  licenses were found in Flutter notices; those do not cover native PDFium.
- The additional ported-code notices from `image` 4.12.0 `LICENSE-other.md`,
  including JPEG code attribution. Flutter's generated primary license payload
  does not include this additional file.

Supplemental source assets now address these observed gaps: `assets/notices/`
contains Ayumitra's license/NOTICE, the byte-for-byte `image` additional notices,
and all PDFium publisher archive license payloads for the current Android ARM64
and iOS native builds. The Android archive library matches the fetched native
asset byte-for-byte; the iOS device/simulator ARM64 UUIDs match the XCFramework
builds. See [notice provenance](../assets/notices/README.md) for archive hashes,
source URLs, and the publisher/upstream version-label discrepancy.

App asset registration and a readable license surface must still include these
texts, followed by inspection of the final APK/device archive. Source files
alone do not establish complete binary distribution coverage. User-imported
model weights are not bundled in the inspected simulator app; model metadata
and attribution still need handling for future distributed model artifacts.

## Resolved Dart/Flutter package inventory

The following license identifiers were read from the resolved package sources.
Flutter SDK packages inherit SDK licensing where a package-specific file is
absent. Version `0.0.0` denotes an SDK package rather than a hosted release.
For each hosted package, the linked version page identifies the source whose
primary `LICENSE` was checked. Additional notices and native components listed
above remain separate.

Current inventory: **129 resolved Dart/Flutter packages**.

| Package | Resolved version | Primary code license |
| --- | --- | --- |
| [android_file_picker](https://pub.dev/packages/android_file_picker/versions/2.0.1) | 2.0.1 | MIT |
| [archive](https://pub.dev/packages/archive/versions/4.5.1) | 4.5.1 | MIT |
| [args](https://pub.dev/packages/args/versions/2.7.0) | 2.7.0 | BSD-3-Clause |
| [async](https://pub.dev/packages/async/versions/2.13.1) | 2.13.1 | BSD-3-Clause |
| [background_downloader](https://pub.dev/packages/background_downloader/versions/9.5.9) | 9.5.9 | MIT; BSD-3-Clause |
| [boolean_selector](https://pub.dev/packages/boolean_selector/versions/2.1.2) | 2.1.2 | BSD-3-Clause |
| [characters](https://pub.dev/packages/characters/versions/1.4.1) | 1.4.1 | BSD-3-Clause |
| [clock](https://pub.dev/packages/clock/versions/1.1.2) | 1.1.2 | Apache-2.0 |
| [code_assets](https://pub.dev/packages/code_assets/versions/1.2.1) | 1.2.1 | BSD-3-Clause |
| [collection](https://pub.dev/packages/collection/versions/1.19.1) | 1.19.1 | BSD-3-Clause |
| [cross_file](https://pub.dev/packages/cross_file/versions/0.3.5+5) | 0.3.5+5 | BSD-3-Clause |
| [crypto](https://pub.dev/packages/crypto/versions/3.0.7) | 3.0.7 | BSD-3-Clause |
| [cryptography](https://pub.dev/packages/cryptography/versions/2.9.0) | 2.9.0 | Apache-2.0 |
| [cupertino_icons](https://pub.dev/packages/cupertino_icons/versions/1.0.9) | 1.0.9 | MIT |
| [dbus](https://pub.dev/packages/dbus/versions/0.8.0) | 0.8.0 | MPL-2.0 |
| [decimal](https://pub.dev/packages/decimal/versions/3.2.6) | 3.2.6 | Apache-2.0 |
| [email_validator](https://pub.dev/packages/email_validator/versions/3.0.0) | 3.0.0 | MIT |
| [fake_async](https://pub.dev/packages/fake_async/versions/1.3.3) | 1.3.3 | Apache-2.0 |
| [ffi](https://pub.dev/packages/ffi/versions/2.2.0) | 2.2.0 | BSD-3-Clause |
| [ffi_leak_tracker](https://pub.dev/packages/ffi_leak_tracker/versions/0.1.2) | 0.1.2 | BSD-3-Clause |
| [file](https://pub.dev/packages/file/versions/7.0.1) | 7.0.1 | BSD-3-Clause |
| [file_picker](https://pub.dev/packages/file_picker/versions/13.1.0) | 13.1.0 | MIT |
| [file_picker_darwin](https://pub.dev/packages/file_picker_darwin/versions/2.2.0) | 2.2.0 | MIT |
| [file_picker_linux](https://pub.dev/packages/file_picker_linux/versions/2.0.2) | 2.0.2 | MIT |
| [file_picker_platform_interface](https://pub.dev/packages/file_picker_platform_interface/versions/4.1.0) | 4.1.0 | MIT |
| [file_picker_web](https://pub.dev/packages/file_picker_web/versions/4.1.0) | 4.1.0 | MIT |
| [file_selector_linux](https://pub.dev/packages/file_selector_linux/versions/0.9.4+1) | 0.9.4+1 | BSD-3-Clause |
| [file_selector_macos](https://pub.dev/packages/file_selector_macos/versions/0.9.5+1) | 0.9.5+1 | BSD-3-Clause |
| [file_selector_platform_interface](https://pub.dev/packages/file_selector_platform_interface/versions/2.7.0) | 2.7.0 | BSD-3-Clause |
| [file_selector_windows](https://pub.dev/packages/file_selector_windows/versions/0.9.3+6) | 0.9.3+6 | BSD-3-Clause |
| [fixnum](https://pub.dev/packages/fixnum/versions/1.1.1) | 1.1.1 | BSD-3-Clause |
| [flutter](https://github.com/flutter/flutter/blob/3.44.1/LICENSE) | 0.0.0 | BSD-3-Clause |
| [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai/versions/2.2.1) | 2.2.1 | MIT |
| [flutter_edge_ai_litertlm](https://pub.dev/packages/flutter_edge_ai_litertlm/versions/1.12.0) | 1.12.0 | MIT |
| [flutter_lints](https://pub.dev/packages/flutter_lints/versions/6.0.0) | 6.0.0 | BSD-3-Clause |
| [flutter_markdown_plus](https://pub.dev/packages/flutter_markdown_plus/versions/1.0.12) | 1.0.12 | BSD-3-Clause |
| [flutter_plugin_android_lifecycle](https://pub.dev/packages/flutter_plugin_android_lifecycle/versions/2.0.35) | 2.0.35 | BSD-3-Clause |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0) | 11.2.0 | BSD-3-Clause |
| [flutter_secure_storage_darwin](https://pub.dev/packages/flutter_secure_storage_darwin/versions/0.4.3) | 0.4.3 | BSD-3-Clause |
| [flutter_secure_storage_linux](https://pub.dev/packages/flutter_secure_storage_linux/versions/3.0.3) | 3.0.3 | BSD-3-Clause |
| [flutter_secure_storage_platform_interface](https://pub.dev/packages/flutter_secure_storage_platform_interface/versions/2.1.1) | 2.1.1 | BSD-3-Clause |
| [flutter_secure_storage_web](https://pub.dev/packages/flutter_secure_storage_web/versions/2.1.1) | 2.1.1 | BSD-3-Clause |
| [flutter_secure_storage_windows](https://pub.dev/packages/flutter_secure_storage_windows/versions/4.2.2) | 4.2.2 | BSD-3-Clause |
| [flutter_test](https://github.com/flutter/flutter/blob/3.44.1/LICENSE) | 0.0.0 | BSD-3-Clause (Flutter SDK) |
| [flutter_web_plugins](https://github.com/flutter/flutter/blob/3.44.1/LICENSE) | 0.0.0 | BSD-3-Clause (Flutter SDK) |
| [genai_primitives](https://pub.dev/packages/genai_primitives/versions/0.2.4) | 0.2.4 | BSD-3-Clause |
| [hooks](https://pub.dev/packages/hooks/versions/2.0.2) | 2.0.2 | BSD-3-Clause |
| [http](https://pub.dev/packages/http/versions/1.6.0) | 1.6.0 | BSD-3-Clause |
| [http_parser](https://pub.dev/packages/http_parser/versions/4.1.2) | 4.1.2 | BSD-3-Clause |
| [image](https://pub.dev/packages/image/versions/4.12.0) | 4.12.0 | MIT; additional notices |
| [image_picker](https://pub.dev/packages/image_picker/versions/1.2.4) | 1.2.4 | Apache-2.0; BSD-3-Clause |
| [image_picker_android](https://pub.dev/packages/image_picker_android/versions/0.8.13+25) | 0.8.13+25 | Apache-2.0; BSD-3-Clause |
| [image_picker_for_web](https://pub.dev/packages/image_picker_for_web/versions/3.1.1) | 3.1.1 | BSD-3-Clause |
| [image_picker_ios](https://pub.dev/packages/image_picker_ios/versions/0.8.13+10) | 0.8.13+10 | Apache-2.0; BSD-3-Clause |
| [image_picker_linux](https://pub.dev/packages/image_picker_linux/versions/0.2.2) | 0.2.2 | BSD-3-Clause |
| [image_picker_macos](https://pub.dev/packages/image_picker_macos/versions/0.2.2+1) | 0.2.2+1 | BSD-3-Clause |
| [image_picker_platform_interface](https://pub.dev/packages/image_picker_platform_interface/versions/2.11.2) | 2.11.2 | BSD-3-Clause |
| [image_picker_windows](https://pub.dev/packages/image_picker_windows/versions/0.2.2) | 0.2.2 | BSD-3-Clause |
| [intl](https://pub.dev/packages/intl/versions/0.20.3) | 0.20.3 | BSD-3-Clause |
| [jni](https://pub.dev/packages/jni/versions/1.1.0) | 1.1.0 | BSD-3-Clause |
| [jni_flutter](https://pub.dev/packages/jni_flutter/versions/1.0.4+1) | 1.0.4+1 | BSD-3-Clause |
| [jni_util](https://pub.dev/packages/jni_util/versions/1.0.0) | 1.0.0 | BSD-3-Clause |
| [json_schema_builder](https://pub.dev/packages/json_schema_builder/versions/0.1.7) | 0.1.7 | BSD-3-Clause |
| [large_file_handler](https://pub.dev/packages/large_file_handler/versions/0.5.2) | 0.5.2 | MIT |
| [leak_tracker](https://pub.dev/packages/leak_tracker/versions/11.0.2) | 11.0.2 | BSD-3-Clause |
| [leak_tracker_flutter_testing](https://pub.dev/packages/leak_tracker_flutter_testing/versions/3.0.10) | 3.0.10 | BSD-3-Clause |
| [leak_tracker_testing](https://pub.dev/packages/leak_tracker_testing/versions/3.0.2) | 3.0.2 | BSD-3-Clause |
| [lints](https://pub.dev/packages/lints/versions/6.1.0) | 6.1.0 | BSD-3-Clause |
| [logging](https://pub.dev/packages/logging/versions/1.3.0) | 1.3.0 | BSD-3-Clause |
| [markdown](https://pub.dev/packages/markdown/versions/7.3.1) | 7.3.1 | BSD-3-Clause |
| [matcher](https://pub.dev/packages/matcher/versions/0.12.19) | 0.12.19 | BSD-3-Clause |
| [material_color_utilities](https://pub.dev/packages/material_color_utilities/versions/0.13.0) | 0.13.0 | Apache-2.0 |
| [meta](https://pub.dev/packages/meta/versions/1.18.0) | 1.18.0 | BSD-3-Clause |
| [mime](https://pub.dev/packages/mime/versions/2.1.0) | 2.1.0 | BSD-3-Clause |
| [mutex](https://pub.dev/packages/mutex/versions/3.1.0) | 3.1.0 | BSD-3-Clause |
| [objective_c](https://pub.dev/packages/objective_c/versions/9.5.0) | 9.5.0 | BSD-3-Clause |
| [package_config](https://pub.dev/packages/package_config/versions/3.0.0) | 3.0.0 | BSD-3-Clause |
| [path](https://pub.dev/packages/path/versions/1.9.1) | 1.9.1 | BSD-3-Clause |
| [path_provider](https://pub.dev/packages/path_provider/versions/2.1.6) | 2.1.6 | BSD-3-Clause |
| [path_provider_android](https://pub.dev/packages/path_provider_android/versions/2.3.1) | 2.3.1 | BSD-3-Clause |
| [path_provider_foundation](https://pub.dev/packages/path_provider_foundation/versions/2.6.0) | 2.6.0 | BSD-3-Clause |
| [path_provider_linux](https://pub.dev/packages/path_provider_linux/versions/2.2.2) | 2.2.2 | BSD-3-Clause |
| [path_provider_platform_interface](https://pub.dev/packages/path_provider_platform_interface/versions/2.1.3) | 2.1.3 | BSD-3-Clause |
| [path_provider_windows](https://pub.dev/packages/path_provider_windows/versions/2.3.0) | 2.3.0 | BSD-3-Clause |
| [pdfium_dart](https://pub.dev/packages/pdfium_dart/versions/0.2.5) | 0.2.5 | MIT |
| [pdfium_flutter](https://pub.dev/packages/pdfium_flutter/versions/0.2.3) | 0.2.3 | MIT |
| [pdfrx](https://pub.dev/packages/pdfrx/versions/2.4.8) | 2.4.8 | MIT |
| [pdfrx_engine](https://pub.dev/packages/pdfrx_engine/versions/0.4.7) | 0.4.7 | MIT |
| [petitparser](https://pub.dev/packages/petitparser/versions/7.0.2) | 7.0.2 | MIT |
| [platform](https://pub.dev/packages/platform/versions/3.2.0) | 3.2.0 | BSD-3-Clause |
| [plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface/versions/2.1.8) | 2.1.8 | BSD-3-Clause |
| [posix](https://pub.dev/packages/posix/versions/6.5.2) | 6.5.2 | MIT |
| [pub_semver](https://pub.dev/packages/pub_semver/versions/2.2.1) | 2.2.1 | BSD-3-Clause |
| [rational](https://pub.dev/packages/rational/versions/2.2.3) | 2.2.3 | Apache-2.0 |
| [record_use](https://pub.dev/packages/record_use/versions/0.6.0) | 0.6.0 | BSD-3-Clause |
| [rxdart](https://pub.dev/packages/rxdart/versions/0.28.0) | 0.28.0 | Apache-2.0 |
| [shared_preferences](https://pub.dev/packages/shared_preferences/versions/2.5.6) | 2.5.6 | BSD-3-Clause |
| [shared_preferences_android](https://pub.dev/packages/shared_preferences_android/versions/2.4.28) | 2.4.28 | BSD-3-Clause |
| [shared_preferences_foundation](https://pub.dev/packages/shared_preferences_foundation/versions/2.5.7) | 2.5.7 | BSD-3-Clause |
| [shared_preferences_linux](https://pub.dev/packages/shared_preferences_linux/versions/2.4.1) | 2.4.1 | BSD-3-Clause |
| [shared_preferences_platform_interface](https://pub.dev/packages/shared_preferences_platform_interface/versions/2.4.2) | 2.4.2 | BSD-3-Clause |
| [shared_preferences_web](https://pub.dev/packages/shared_preferences_web/versions/2.4.3) | 2.4.3 | BSD-3-Clause |
| [shared_preferences_windows](https://pub.dev/packages/shared_preferences_windows/versions/2.4.1) | 2.4.1 | BSD-3-Clause |
| [sky_engine](https://github.com/flutter/flutter/blob/3.44.1/LICENSE) | 0.0.0 | MPL-2.0; Apache-2.0; MIT; BSD-3-Clause |
| [source_span](https://pub.dev/packages/source_span/versions/1.10.2) | 1.10.2 | BSD-3-Clause |
| [stack_trace](https://pub.dev/packages/stack_trace/versions/1.12.1) | 1.12.1 | BSD-3-Clause |
| [stream_channel](https://pub.dev/packages/stream_channel/versions/2.1.4) | 2.1.4 | BSD-3-Clause |
| [string_scanner](https://pub.dev/packages/string_scanner/versions/1.4.1) | 1.4.1 | BSD-3-Clause |
| [synchronized](https://pub.dev/packages/synchronized/versions/3.4.2) | 3.4.2 | MIT |
| [term_glyph](https://pub.dev/packages/term_glyph/versions/1.2.2) | 1.2.2 | BSD-3-Clause |
| [test_api](https://pub.dev/packages/test_api/versions/0.7.11) | 0.7.11 | BSD-3-Clause |
| [typed_data](https://pub.dev/packages/typed_data/versions/1.4.0) | 1.4.0 | BSD-3-Clause |
| [url_launcher](https://pub.dev/packages/url_launcher/versions/6.3.3) | 6.3.3 | BSD-3-Clause |
| [url_launcher_android](https://pub.dev/packages/url_launcher_android/versions/6.3.33) | 6.3.33 | BSD-3-Clause |
| [url_launcher_ios](https://pub.dev/packages/url_launcher_ios/versions/6.4.2) | 6.4.2 | BSD-3-Clause |
| [url_launcher_linux](https://pub.dev/packages/url_launcher_linux/versions/3.2.3) | 3.2.3 | BSD-3-Clause |
| [url_launcher_macos](https://pub.dev/packages/url_launcher_macos/versions/3.2.6) | 3.2.6 | BSD-3-Clause |
| [url_launcher_platform_interface](https://pub.dev/packages/url_launcher_platform_interface/versions/2.3.2) | 2.3.2 | BSD-3-Clause |
| [url_launcher_web](https://pub.dev/packages/url_launcher_web/versions/2.4.3) | 2.4.3 | BSD-3-Clause |
| [url_launcher_windows](https://pub.dev/packages/url_launcher_windows/versions/3.1.6) | 3.1.6 | BSD-3-Clause |
| [uuid](https://pub.dev/packages/uuid/versions/4.6.0) | 4.6.0 | MIT |
| [vector_math](https://pub.dev/packages/vector_math/versions/2.2.0) | 2.2.0 | BSD-3-Clause |
| [vm_service](https://pub.dev/packages/vm_service/versions/15.3.0) | 15.3.0 | BSD-3-Clause |
| [web](https://pub.dev/packages/web/versions/1.1.1) | 1.1.1 | BSD-3-Clause |
| [win32](https://pub.dev/packages/win32/versions/6.4.0) | 6.4.0 | BSD-3-Clause |
| [windows_file_picker](https://pub.dev/packages/windows_file_picker/versions/2.0.1) | 2.0.1 | MIT |
| [xdg_directories](https://pub.dev/packages/xdg_directories/versions/1.1.0) | 1.1.0 | BSD-3-Clause |
| [xml](https://pub.dev/packages/xml/versions/7.0.1) | 7.0.1 | MIT |
| [yaml](https://pub.dev/packages/yaml/versions/3.1.4) | 3.1.4 | MIT |
