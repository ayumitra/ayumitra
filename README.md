# Ayumitra

An English-speaking medical companion for Android and iOS, built for a child and intended for everyone. Reports, extraction, embeddings, and AI answers stay on the device. The local assistant can use public web search as a tool; it never sends the medical vault to a cloud model.

## First development slice

- Onboarding with age, its reference date, and optional user-provided history.
- Encrypted original reports and an authenticated encrypted record/search index.
- File or rear-camera report import, with scoped temporary-copy cleanup.
- Local PDF text extraction and an imported local Gemma 4 vision model for scan/photo transcription; transcripts require review.
- Local organizer/extractor/summarizer/planner prompts using one assistant model.
- Clinical-date/category organization, estimated age-at-event labels, and Markdown summaries.
- Source-page highlights, editable facts, and corrections retained across reprocessing.
- EmbeddingGemma 2 search through a native bridge, with local keyword search available during setup/failure.
- A bounded planner that can combine private-record and public-web searches in one answer.
- Brave Search integration with a key stored in platform secure storage; query-only requests and local result summarization.

This is a development prototype, not a finished medical application. Model quality, clinical accuracy, and performance on the Samsung S24 Ultra still need measurement. Voice, foreground wake word, medicine reminders, de-identified sharing, portable backup/restore, and large-history database optimization remain later work. Current report imports support PDF, PNG/JPG, and UTF-8 text up to 30 MB and 30 PDF pages.

## Run

Install dependencies with `flutter pub get`, then run `flutter run` on an Android arm64 device. Android 11/API 30 or newer is required; the first reference device is the Samsung S24 Ultra. The iOS project targets iOS 16 or newer (the official embedding runtime currently requires an Apple Silicon simulator for development); both platforms have native EmbeddingGemma 2 bridges. Real-model inference still needs device validation.

For an Android development APK:

```sh
flutter build apk --debug --target-platform android-arm64
```

This build uses development signing. Store distribution and production signing are not configured.

In the app's setup screen, choose a local `.litertlm` assistant model and its matching family (scan transcription currently requires a vision-capable Gemma 4), and a local **EmbeddingGemma 2** `.litertlm` file. The app copies weights into its own local storage. Weights are not included in the repository or downloaded by the app. Start with synthetic reports in `docs/eval-fixtures/` and the built-in synthetic text example. The app does not pretend to have AI responses when weights are absent.

Web search is optional for the offline record flow. Configure a Brave Search API key once in settings to let the local planner use it automatically. Without the key or connectivity, web search reports its unavailability; it never becomes cloud inference. Retrieved web content cannot request tool calls. External source links open only when the user taps them.

## Verification

```sh
flutter analyze
flutter test
```

Native PDF routing checks can also run with `flutter test checks/pdf_parser_test.dart`.
On macOS they use the installed PDFium package's host framework; on other hosts set
`PDFIUM_PATH` to an appropriate local PDFium library. They exercise a sparse PDF
header with vision available and unavailable, rather than treating a watermark as
complete report text.

Tests cover authenticated storage, tampering, profile isolation, embedding identity/dimension checks, source validation, correction persistence, age/date organization, web-query filtering, and onboarding/history UI. These checks do not measure real-model medical accuracy.

[Product brief](docs/product-brief.md) · [Evaluation plan](docs/eval-plan.md) · [Synthetic fixtures](docs/eval-fixtures/manifest.json)

## Browser UX preview

A separate entry point reuses the same Flutter screens with in-memory synthetic
records and clearly labelled sample responses. It does not invoke or upload to
an AI service. See [preview instructions](lib/preview/README.md).

```sh
flutter build web --target lib/preview/main_preview.dart --no-web-resources-cdn
```

The preview tests interaction design; it does not measure local model or camera
quality on a phone.
