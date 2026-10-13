# Ayumitra

An English-speaking medical companion for Android and iOS, built for a child and intended for everyone. Reports, extraction, embeddings, and AI answers stay on the device. The local assistant can use public web search as a tool; it never sends the medical vault to a cloud model.

## First development slice

- Onboarding with date of birth and optional user-provided history; separate family profiles with editable details and confirmed deletion of their records, originals, conversations, memory and pending jobs.
- Encrypted original reports and an authenticated encrypted record/search index. A profile file library lists every stored original, including files that could not be parsed.
- Saved conversations and user-stated memory scoped to each profile. Chat updates are available immediately and across sessions, with each message’s provided date; explicit user event dates take precedence. Deleting a conversation removes its memory without deleting reports.
- File or rear-camera report import, with up to five photos grouped as one report, page-linked sources, owner-bound lost-camera recovery, and scoped temporary-copy cleanup.
- Android foreground protection for local processing and a persistent, profile-scoped retry queue. Unfinished reports retry with backoff, capped at three attempts; originals remain available. Checks run while the app process is alive and resume on reopening after termination.
- English microphone input through strictly on-device speech recognition. Experimental foreground wake listening is deferred after the S24 recognizer confused “Ayu” with “are you”; tap-to-talk remains available. Voice stops offscreen or during processing, with no cloud fallback.
- Local PDF text extraction and a local Gemma 4 vision model for scan/photo Markdown extraction; transcripts require review.
- Flexible Markdown extraction of report information and dates using the local assistant, with source references and no required fact-output schema. Files use a visible report date for sorting; dateless files receive a labelled current-day filing date.
- Report-date/category organization, DOB-based age labels, and source-linked Markdown notes.
- Source-page highlights, editable facts, and corrections retained across reprocessing. Answers retain only the files and public web sources actually cited; rejected answers clearly label retrieved excerpts as fallback evidence.
- EmbeddingGemma 2 search through a native bridge, with local keyword search available during setup/failure.
- A bounded planner that can combine private-record and public-web searches in one answer. Malformed tool plans get two structure-guided retries, with strict validation before any tool runs; exhausted plan repairs use local record search only. Invalid answer references and report-note references also receive two controlled repair attempts; report jobs remain retryable if notes fail, while answers use evidence fallback; updates must cite their conversation provenance.
- Autonomous or user-requested extended thinking for bounded research: the local model plans and assesses up to three rounds/six public searches, then answers locally from collected evidence.
- Brave Search integration with a key stored in platform secure storage; query-only requests and local result summarization.

This is a development prototype, not a finished medical application. Model quality, clinical accuracy, and performance on the Samsung S24 Ultra still need measurement. Background wake-word listening, medicine reminders, de-identified sharing, portable backup/restore, and large-history database optimization remain later work. Current report imports support PDF, PNG/JPG, and UTF-8 text up to 30 MB and 30 PDF pages.

## Run

Install dependencies with `flutter pub get`, then run `flutter run` on an Android arm64 device. Android 11/API 30 or newer is required; the first reference device is the Samsung S24 Ultra. The iOS project targets iOS 16 or newer (the official embedding runtime currently requires an Apple Silicon simulator for development); both platforms have native EmbeddingGemma 2 bridges. Real-model inference still needs device validation.

For an Android development APK:

```sh
flutter build apk --debug --target-platform android-arm64
```

For emulator tests using the Mac’s local Gemma 4 and EmbeddingGemma 2, use the [debug localhost bridge](docs/android-emulator-testing.md). It retains the native encrypted vault, but inference runs on the host computer; it does not measure phone performance. The normal app entrypoint uses on-device model files.

This build uses development signing. Store distribution and production signing are not configured.

Android automatically prepares the fixed **Gemma 4 E2B** assistant and **EmbeddingGemma 2 Text 270M** search model. The first setup downloads about 2.7 GB of public weights over Wi-Fi through Android DownloadManager; downloads survive screen locking and app restarts. Immutable revisions, exact sizes and SHA256 digests are verified before activation. Progress and retry appear in the app; no file selection is required. Models and all inference remain on-device, with no cloud fallback. iOS currently uses local `.litertlm` file import in settings. Weights are not committed to the repository. Start with synthetic reports in `docs/eval-fixtures/`; the app does not invent AI responses before models are ready.

Web search is optional for the offline record flow. Configure a Brave Search API key once in settings to let the local planner use it automatically. The planner can choose extended thinking on its own, or the user can request it. A visible status identifies that mode while the assistant checks additional general public sources within a bounded research budget; private records and identifying details remain local. Without the key or connectivity, web search reports its unavailability; it never becomes cloud inference. Retrieved web content cannot request tool calls. External source links open only when the user taps them.

Background entered at profile creation becomes the first visible user turn and seeds that profile’s conversation memory. An empty background creates no initial conversation. Deleting the seeded conversation removes its turns and derived memory; the separate editable profile background remains until changed.

User-reported updates take priority for the current explanation while original report values remain dated history. The assistant searches owned reports for corroboration; only matching findings and compatible event dates support a report reference. Without corroboration, the update remains user-reported and the assistant asks for a report. Questions and hypothetical values are not treated as clinical findings.

Native conversations, complete turns, profile memory, and originals are saved in the encrypted vault. Click the Ayumitra logo to open the profile home page, choose a person, or add a new profile with their date of birth. Each profile remembers its selected conversation when you switch people. There is no fixed conversation-count limit; memory excerpts and model context are bounded separately. Conversation memory contains user-stated context, not verified clinical evidence, and remains separate from report facts. Previous assistant statements cannot become memory used to authorize tools. Legacy age-only profiles keep their approximate age information until the user supplies a date of birth; migration does not invent one. Editing a birth date clears that person's saved report summaries so their age-at-event information can be regenerated.

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

Tests cover authenticated storage, tampering, profile/session isolation and deletion, encrypted conversation restoration, user-only contextual recall, embedding identity/dimension checks, source validation, correction persistence, age/date organization, web-query filtering, and onboarding/history UI. These checks do not measure real-model medical accuracy.

[On-device STT research](docs/research/on-device-stt.md) · [Local voice setup and limits](docs/local-voice.md) · [Product brief](docs/product-brief.md) · [Evaluation plan](docs/eval-plan.md) · [Synthetic fixtures](docs/eval-fixtures/manifest.json)

## Local browser client

The browser reuses the mobile screens and real processing prompts. It starts
empty and uses verified installed models on this computer through a loopback
Ollama-compatible server. Cloud models and redirects are refused. It never
downloads weights or calls cloud AI. See [setup](lib/preview/README.md).

Use synthetic reports first to test DOB profiles, conversations, source links,
corrections, and memory deletion. Bundled PDFium reads digital PDFs locally;
image pages are rendered before optional local vision transcription. Scans and
sparse text layers require review against the original.

Reports and conversations stay in tab memory and clear on reload. This client
does not provide native encrypted persistence. Public web research is currently
disabled here; the mobile assistant has its separately configured search tool.
Second-opinion drafts require review before copying. Opening a provider opens
only its homepage; Ayumitra never submits the draft.

```sh
flutter build web --target lib/preview/main_preview.dart --no-web-resources-cdn
```

The client tests desktop behavior with local weights. Model quality, offline
operation, camera handling, and performance still need phone trials.
