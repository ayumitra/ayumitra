# Ayumitra product brief

Updated 13 October 2026. Implementation has started with a Flutter development prototype targeting Samsung S24 Ultra first. This separates the founder's vision from implementation recommendations and decisions still open.

## Purpose

Ayumitra is a personal medical companion with a lifelong memory. It should let someone speak or type naturally to add records, ask about their history, understand a report, track medicines, and prepare information to share. The project begins with a parent's needs for their child and aims to serve everyone.

Android and iOS are both target platforms. EmbeddingGemma 2 generates search embeddings on-device. Intelligence for organizing records, extracting information, and generating summaries also runs locally. Medical reports and personal history stay on the device unless the user explicitly shares or exports them.

## Requested experience

| Capability | Intended experience |
| --- | --- |
| First use | Ask for date of birth and optional previous history; the history seeds a visible first user turn and profile-scoped memory. English input/output in v1. |
| Record import | Accept medical reports from files, scans, and photographs, preserving the originals. |
| Lifelong history | Build a history organized by clinical date, age at event, and category, with source-linked Markdown summaries. |
| Search | Find records by meaning using EmbeddingGemma 2 locally. |
| Local intelligence | Use one local LLM with separate system prompts for organizing, extraction, and summarization. |
| Conversation | Use text and voice as the main interface; support “Ayu” (aa-yuh) voice commands where feasible. |
| Image understanding | Interpret images; image-based diagnosis is part of the longer-term vision. |
| Medicines | Track medicines being taken, answer information questions using internet sources, and maintain schedules. |
| Sharing | Generate an anonymized report for the user to review and share. |

## Recommended product behavior

Keep conversation central, with inline report viewers, result cards, schedule cards, and export previews. A chat interface still needs visible evidence and editable records.

Let a user tap a cited finding to open the original page and highlight the supporting text or image region. Offer simple and detailed explanations without changing the underlying facts. Support imports from the camera, file picker, and another app's share sheet so users do not need to organize folders themselves.

Show report processing states: saved, queued, processing, needs review, ready, and failed. Make extraction retryable and display which pages need attention. Provide a timeline ordered by clinical event date, with report-type filters; mark unknown dates rather than substituting the upload date.

For a child's profile, support a caregiver operating the app on the child's behalf. Support multiple family profiles and keep each person's records, conversations, memory, and searches isolated. New profiles record date of birth so age-at-event stays meaningful as the person grows; legacy age-only profiles retain their approximate reference rather than receiving an invented birth date. Mark the initial summary as user-provided history rather than a verified clinical report.

Keep saved conversations within their owning profile. User-stated context may help recall earlier conversations, but assistant-generated replies must not become remembered clinical facts or tool authorization. Deleting a conversation removes its turns and associated memory; imported reports remain independently stored. Native history is encrypted. The browser client uses temporary tab memory with verified installed models on the same computer; reload clears its data. Use synthetic reports for evaluation. Public web research is currently disabled in the browser client.

Onboarding should also capture language preference and show model-download size and progress. Allow typing, saving reports, and keyword search over available extracted text while models download. Speech recognition must use a verified on-device path; if local speech is unavailable for a device or language, retain typed input instead of silently using a remote service.

Preserve original reports as the source of truth. Store extracted facts separately, including source report, page or region, original text, date, units, and report reference ranges. Let users correct extracted facts without editing the original. Keep user corrections, reported findings, and AI interpretations distinguishable.

Generate summaries from retrieved source facts, not solely from earlier AI summaries. Link factual claims to reports and say when supporting information is missing or contradictory. Separate clinical event dates from upload dates.

Treat image description, transcription of a radiology report, and diagnosing a condition from clinical images as separate capabilities. For the initial release, prioritize the first two. Diagnostic functionality needs its own clinician-led evaluation before it can be relied upon; choosing a vision-capable LLM does not establish diagnostic accuracy.

Medicine records should preserve prescribed name, strength, dose, route, frequency, and start/end dates where available. Clarify ambiguous prescriptions before creating reminders. Keep reminders and user-confirmed taken/skipped events separate. The local LLM decides when to use web search for general medicine or medical information. It sends only a standalone public-information query, shows sources and retrieval dates, and never attaches reports or personal history. No separate per-search user tap is required. The agent should not independently change a prescribed dose or schedule. All interpretation and summarization of web results run locally; there is no cloud AI fallback.

Extended thinking performs bounded public research with the same local model: at most three research rounds and six search calls, with local assessment of collected snippets. Only filtered general public queries leave the device. Research stops when evidence suffices, connectivity is unavailable, or the budget ends. This mode does not add cloud inference or background voice activation.

Call an export a de-identified draft until reviewed. Remove identifiers from text, images, filenames, and metadata, including text burned into scanned pages. Offer a preview before sharing. Do not promise irreversible anonymity: dates and unusual medical histories can still identify someone.

Redaction must remove the underlying content from the exported file, including hidden PDF text and embedded originals. Visual blurring or covering text alone is insufficient. Preserve a local record of the export's source reports and user review without logging medical content to analytics.

## Proposed architecture

```text
Voice / text / report import
              |
     Local action coordinator
              |
   +----------+--------------------+
   |          |                    |
Record vault  Import pipeline      Medicine tools
   |          |                    |
   |     OCR / visual reading      Schedules + OS notifications
   |          |
   |     Extractor prompt -> validated structured facts
   |          |
   +---- Local facts + keyword index + vector index
                         |
                  Source retrieval
                         |
                  Summarizer prompt
                         |
                 Answer with report links

Explicit network boundary: agent-invoked public web search and optional model distribution.
The initial app imports model files locally; it has no model-download flow.
Embeddings, record retrieval, extraction, and summaries run on-device.
```

Use one local model runtime with independent prompt roles and contexts: organizer, extractor, summarizer, and action planner. Validate structured outputs in application code. Give the planner bounded tools for record search, medicine tracking, schedule changes, and export preparation. Treat report contents and web pages as data, not instructions that can authorize tool calls.

| Prompt role | Responsibility | Application enforcement |
| --- | --- | --- |
| Organizer | Propose report type, clinical date, and provider from the source. | Validate fields and preserve unknown or ambiguous values. |
| Extractor | Propose facts with original values, units, reference ranges, and page/region links. | Validate structure and source references; flag unsupported or uncertain fields for review. |
| Summarizer | Explain retrieved evidence and user-provided history in the requested language. | Check citation references and keep unsupported interpretations distinguishable from reported facts. |
| Planner | Propose calls to a small set of application tools based on the user's request. | Enforce profile scope, tool arguments, and authorization in code; clarify ambiguous actions. |

Model-reported confidence can help prioritize review, but must not be presented as a calibrated probability of medical correctness.

The vault should include encrypted original files, a local structured database, and rebuildable search indexes. Protect encryption keys using platform secure storage. Keep health content out of ordinary logs and analytics. Add an explicit encrypted backup/restore path: a lifelong record must survive a lost or replaced phone. Track model and prompt versions so extractions can be regenerated while preserving user corrections.

For numerical questions, retrieve structured results with date and unit filters; combine keyword and semantic search for narrative questions. Store the embedding model/version and dimension with each index. Provider changes require reindexing; vectors from different models must not be mixed.

Use operating-system notifications for medicine reminders rather than asking an LLM to run on a timer. Define timezone, daylight-saving, missed-reminder, and edited-schedule behavior.

## Proposed record structure

Adapted from [IDEA.md](../IDEA.md); this is a conceptual structure, not a selected database implementation.

| Entity | Essential information |
| --- | --- |
| Profile | Identifier, optional date of birth or age with reference date, caregiver relationship, language preference. |
| Report | Profile, original file, type, clinical date, upload date, processing status, pages, model/prompt versions. |
| Fact | Profile, report, original and normalized value/unit, source reference range, clinical date, page/region, review state. |
| Correction | Fact, user-provided replacement, timestamp, and link to the extraction it supersedes; retained across regeneration. |
| Search chunk | Profile, report, page/region, extracted text, embedding model/version/dimension, vector, index status. |
| Medicine | Profile, prescribed name/strength/dose/route/frequency, date range, source report, active state. |
| Reminder and dose event | Medicine, schedule, timezone, due occurrence, and separately recorded user-confirmed taken/skipped events. |
| Export | Profile, selected reports, redaction/review state, creation date. |

Enforce profile ownership across files, facts, keyword results, vectors, medicine tools, and exports. Preserve relationships so a source cannot accidentally be attached to another person's record. Do not infer that a medicine was taken merely because its reminder was delivered.

## Verified technology facts

- **EmbeddingGemma 2** is an open-weight model intended for local and offline multimodal embedding workflows. It is the selected embedding model family for Ayumitra; the variant and device performance still need evaluation. See [Google's EmbeddingGemma documentation](https://ai.google.dev/gemma/docs/embeddinggemma).
- **LiteRT-LM** documents Android and iOS support. Its Kotlin API is stable and Swift integration is currently an early preview. Evaluate runtime, model, memory, latency, and thermal behavior on actual target phones before selecting the mobile framework. See [LiteRT-LM's overview](https://developers.google.com/edge/litert-lm/overview).
- **iOS background execution is limited.** Therefore the initial design should support push-to-talk and foreground wake-word listening, and separately investigate system integrations for invocation outside the app. Always-on background “Ayu” listening should remain an unverified capability. See [Apple's background execution documentation](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes).

These technology facts were checked on 12 October 2026; model quality and device suitability have not been tested in this project.

## Document parser evaluation

Checked on 12 October 2026:

- **LlamaParse / llama-parse-py: excluded from the on-device pipeline.** The repository provides a client for the LlamaCloud REST API, and the parsing flow uploads a document before submitting a parse job. Installing the SDK locally does not make parsing local. Sources: [Python SDK](https://github.com/run-llama/llama-parse-py), [parse workflow](https://developers.llamaindex.ai/llamaparse/parse/).
- **Self-hosted LlamaParse: does not satisfy the phone-only requirement.** The documented Enterprise deployment runs on Kubernetes and uses external model APIs, including OpenAI, Anthropic, or Google. Source: [self-hosting documentation](https://developers.llamaindex.ai/llamaparse/self_hosting/).
- **LiteParse: candidate for a local parser trial.** This separate open-source project provides local PDF parsing, bounding boxes, and bundled Tesseract OCR. Its documented platforms are Linux, macOS, and Windows; Android/iOS packaging and resource use are unverified here. Any trial must use local OCR, bundle the required assets, disable external OCR endpoints, and avoid cloud fallback. Source: [LiteParse repository](https://github.com/run-llama/liteparse).

The proposed import path remains local text/layout extraction for digital PDFs, local OCR for scans, and a local model for structured medical facts. Evaluate parser correctness on lab tables, units, reference ranges, and source coordinates before selecting a library.

## Delivery sequence

1. **Prove local feasibility:** benchmark candidate extraction, summarization, EmbeddingGemma 2 variants, and voice components on one target Android phone and one target iPhone using synthetic reports. Select model variants and supported devices.
2. **Complete one end-to-end record flow:** onboarding -> import a PDF or photo -> preserve original -> extract editable facts -> search -> generate a summary with report links. Unsupported or unreadable imports should stay saved and show a clear status.
3. **Add daily support:** voice input/output, medicine tracking, user-confirmed schedules, local reminders, and sourced medicine lookups.
4. **Make records portable:** reviewed de-identified exports, encrypted backup/restore, and caregiver/profile flows.
5. **Expand after evaluation:** broader document formats, longitudinal comparisons, wake-word integrations, and separately validated clinical image capabilities.

The feasibility result should record model storage, peak memory, import time, answer latency, thermal behavior, extraction accuracy, retrieval recall, and unsupported summary claims on a fixed synthetic evaluation set. Declare target thresholds and devices before selecting the framework. Frameworks and libraries proposed in IDEA.md remain candidates until their mobile integration has been verified; its suggested week estimates are not delivery commitments.

## Acceptance criteria for the first record flow

- Import, extraction, search, and summary generation work without connectivity after models are installed.
- Every extracted fact and summary claim can be inspected against its source; uncertain or unreadable values are not silently invented.
- A fact correction survives app restart and regeneration.
- One person's records never enter another person's search or answer context.
- Offline record questions and model failures do not trigger a cloud fallback.
- Original files remain accessible when extraction fails, and interrupted processing can resume without duplicate records.
- On each reference phone, demonstrate the complete flow in airplane mode: import a synthetic PDF and photo, inspect source links, correct a fact, restart, regenerate, and verify the correction persists.
- Documents containing instructions cannot cause the agent to change a medicine, access another profile, or transmit a record.

Later medicine and export milestones add their own checks: a real OS reminder and correctly attributed dose event, and an exported file inspected for recoverable identifiers in visible content, hidden text, images, and metadata.

## Decisions still open

- Which EmbeddingGemma 2 variant best fits the target devices and report modalities?
- Samsung S24 Ultra is the first target; which iPhone, minimum device specifications, and processing-time thresholds?
- English conversation and report reading are fixed for v1; additional languages are deferred.
- Flutter is the initial framework; native inference/search integration and real-phone performance require verification.
- Several family profiles, date-of-birth onboarding, and saved profile-scoped conversations are established requirements.

EmbeddingGemma 2, on-device processing, English v1, and autonomous web-search tool use are established requirements. The first Flutter development slice implements the record vault, import/extraction pipeline, bounded agent routing, Markdown answers, and setup. Local LLM/model variants, real-phone quality/performance, and remaining voice/medicine/sharing/backup milestones are not validated or complete.
