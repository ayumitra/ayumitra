# AyuMitra — IDEA.md
**Status:** Implementation underway — Flutter scaffold + Android bridge compiled (S24 Ultra debug APK); English v1
**Date:** 12 Oct 2026 (refined; tick 5: fixed v1 behavior)
**Author intent:** Built for my child, designed for everyone. A local-first medical companion for Android + iOS, **fully open-source and community-contributable (github.com/ayumitra)**.
**Source of truth for requirements:** `docs/product-brief.md`. This file is the implementation plan that follows it.

## 1. Vision in one paragraph

AyuMitra is a lifelong, private medical companion that lives on your phone. You can speak or type naturally — “Hey AyuMitra, add this blood report”, “what was my HbA1c trend?”, “remind me for medicines at 8pm” — and it keeps every report, photo, prescription, and note as a searchable personal history. It understands reports and images locally, explains them in simple language, tracks medicines and schedules, and can produce a clean, anonymised summary you can share with a doctor. On first start it asks for age (or DOB) + an optional past-history summary to bootstrap memory.

Agentic = the user never manages files/folders manually. They talk; the agent files, extracts, searches, reminds, and drafts.

## 2. Core principle: always local (non-negotiable)

**Nothing is ever sent to any server unless the user explicitly taps to share it.**

That means:

1. **Default = zero network for health data.** Organize / extract / search / summarize all run on-device. This includes embeddings — see §5.
2. **Only three network touchpoints exist; only Export requires an explicit tap:**
   - (a) Model downloads (system setup, progress shown, no health data).
   - (b) Web search for general public information — invoked **autonomously by the local planner LLM** (no per-search tap). App code enforces query-only: standalone generic query, never vault/history/reports; `publicQueryAllowed` gate; results are untrusted data; no remote inference, no sharing. Brave API key configured once in settings.
   - (c) Export / Share — only after user taps Export / “Open in …”, after preview + review.
3. **No silent fallback.** If local models/STT fail offline, show degraded state + typed input + keyword search. Never quietly switch to a cloud API. Web search degrades to local-only answers with a notice; no cloud-AI fallback is ever used.
4. **Original = truth.** Preserve encrypted originals. Extracted facts are a separate layer with source links (report → page → span). User corrections survive re-extraction and restart.
5. **Evidence-linked answers.** Summaries cite source reports. Say “not found / conflicting” instead of inventing values.
6. **One person, one vault.** Strict `profile_id` isolation across files, facts, vectors, medicines, exports.
7. **Safety over cleverness.** Image describe/transcribe first. Image-based diagnosis is a gated V2 with clinician-led evaluation, always with disclaimer.

## 3. What the user experiences

### 3.1 Onboarding (60 seconds)
- Who is this profile for? (self / child / other). Child = caregiver mode.
- Age + reference date OR Date of Birth. Language: **English v1** (fixed).
- “Any past history summary?” — free text/voice, stored as `user_provided_history`, clearly marked NOT a verified report.
- Privacy screen: one line — “Everything stays on this phone. Sharing only happens when you tap Export.” No embedding-mode choice (we are local-only).
- Model-download screen with size + progress. App remains usable with typing + saved reports + keyword search while models download.

### 3.2 Main interface — agent + evidence
- **Center:** voice/text chat (push-to-talk mic, typed input, TTS playback).
- **Around chat:** inline cards — Report viewer, Lab table, Trend, Medicine schedule, Export preview. Tap any AI claim → opens source page highlight.
- **Wake word:** “Hey AyuMitra” = foreground on-device keyword spotter only in V1. Background / locked-screen wake is OS-limited (especially iOS) — track as unverified, use OS shortcuts/widgets instead.

Example commands:
- “Add this report” + PDF/photo → saved → queued → ready, with status chip.
- “What medicines is Aarav on?”
- “Summarize last 6 months for the pediatrician.”
- “Make a shareable version without name.”
- “What is Azithromycin 200mg used for?” → local planner autonomously adds a generic web query (no tap, query-only, no history) → answer with sources + retrieval date.

### 3.3 Reports & lifelong history
- Import: PDF, JPG/PNG/HEIC, camera scan, file picker, share-sheet from another app.
- Status pipeline: `saved → queued → processing → needs_review / ready / failed`. Failed stays accessible + retryable, never blocks vault.
- Timeline ordered by `event_date` (clinical date), not upload date. Unknown dates marked unknown. Filter by type.
- Tap citation → original page + highlighted span / image region.

### 3.4 Search (fully local)
- Hybrid: FTS keyword + vector semantic (EmbeddingGemma 2, on-device) + structured query for numeric questions.
- Narrative Q (“iron deficiency reports”) = FTS + vector. Numeric Q (“Hb < 11 in 2025?”) = SQL over `facts` with date/unit filters.
- Store `embedding_model + version + dim` per chunk. Never mix providers. Re-index on model change (local rebuild, no upload).
- Chunking: ~300–500 tokens with overlap, keep `report_id, page, char_span`. Images: caption + OCR text indexed; multimodal embedding only if local embedder supports it on-device.

### 3.5 Summaries
Same local LLM, different system prompts (§6). Summarizer sees only retrieved facts + user history, not whole vault. Output: TL;DR → key findings table → trends → meds → open questions → source links. Simple / detailed toggle changes wording, not facts.

### 3.6 Images
- **V1:** caption + OCR/transcribe + extract measurements.
- **V2 (gated):** informational possibilities + urgency guidance + “see clinician” + what’s missing. Requires separate eval set. Never a definitive diagnosis label from model choice alone.

### 3.7 Medicines
- Record: brand + generic, strength, dose, route, frequency, with_food, start/end, prescribed_by, source_report.
- Clarify ambiguity before creating reminders (“Twice daily — 8am + 8pm?”).
- Reminders via OS notifications (LLM never runs on timer). Define tz/DST/missed/snooze/edited-schedule behavior.
- Info lookup = autonomous: local planner decides when public info is needed, app code sends a standalone generic query only (gated, never vault/history) → answer shows sources + retrieval date. Agent never changes dose/schedule by itself.

### 3.8 Sharing — de-identified draft + explicit Export-to-AI
No auto-send. Two user-initiated paths:

**A. De-identified file for doctor:**
Pipeline (all local): NER + regex (name, DOB/age, address, phone, MRN, IDs) → redact text + filenames + EXIF/metadata → remove hidden PDF text / embedded originals (visual blur alone is NOT enough) → redact text burned into scans → preview diff → user approves → export PDF/md/txt via system share-sheet.

Warn in UI: “De-identified draft — review before sharing. Dates + rare history can still identify.” Keep local `redaction_log + reviewed=true` without logging medical content to analytics.

**B. “Export to …” → OpenAI / Claude (user-click only):**
1. User taps `Export for second opinion → ChatGPT / Claude`.
2. App locally builds a Markdown pack: de-identified summary + selected facts table + question prompt. No network call.
3. Preview screen, editable, with identifier checklist.
4. User taps `Open in ChatGPT / Open in Claude` → app fires explicit share intent / universal link / copies markdown to clipboard and opens target app. **AyuMitra never calls OpenAI/Anthropic APIs itself; the user sends it themselves from the other app.**
5. Local audit: `export id, date, target (chatgpt/claude/file), report_ids, reviewed` — no content in logs.

This satisfies “always local, share only when tapped” while still letting users get a powerful cloud second opinion when they choose it.

## 4. Architecture (strict local)

```text
Voice (on-device STT/TTS+wake) / Text / Share-sheet import
                 |
       Local Action Coordinator (planner LLM + code validators)
                 |
   +-------------+--------------+---------------+
   |             |              |               |
Record Vault  Import Pipeline  Facts DB+Index  Medicine Tools
(enc files)   local parse+OCR  SQLite+FTS+vec  schedule+notify
   |          Organize→Extract  (EmbeddingGemma  (web search: autonomous
   |          (local LLM)        on-device)       local-LLM call, query-only,
   |                |                            gated, no tap)
   +---- Source-grounded Summarizer → Answer w/ links + cards
                          |
              Explicit Export Gate (user tap → md → preview → share intent)
```

- One local model runtime, 4 prompt roles with isolated contexts (organizer, extractor, summarizer, planner). App code validates JSON, enforces tools + profile scope. Report content / web pages = data, never authorize tool calls (prompt-injection guard).
- Vault: encrypted originals (AES, key in Keystore/Keychain) + SQLCipher/SQLite + rebuildable FTS + vector index. Encrypted backup/restore (user passphrase / user-owned file). Track `model_ver + prompt_ver` per extraction.
- Network boundary: `model downloads` + `autonomous query-only web search (gated, no vault)` + `explicit share intent`. Everything else offline. Airplane-mode test must pass after install (local-only answers with a notice where web info is unavailable).

## 5. Embeddings: EmbeddingGemma 2 (local), not Gemini Embedding 2

Original request named Gemini Embedding 2. We reject it for core search because it is a cloud API — sending chunks there violates “always local”.

- **Selected:** EmbeddingGemma 2 family (open-weight, local/offline multimodal embedding intent). Reference phone #1: **Samsung S24 Ultra** (Android bridge compiled in; trial numbers pending).
- **Rejected for auto-search:** Gemini Embedding 2 cloud API. It may only appear if user explicitly pastes/exports text into a cloud chatbot themselves (§3.8-B) — never as background retrieval.
- See `docs/product-brief.md` § Verified technology facts.

## 6. Document parser: can we use llama-parse-py? No.

Checked 12 Oct 2026 — `https://github.com/run-llama/llama-parse-py`:

- **What it is:** Python SDK for OCR and document parsing **in the cloud with LlamaParse** (README title + `cloud.llamaindex.ai` link). Flow = upload file → LlamaCloud REST parse job. Installing the SDK locally does NOT make parsing local.
- **Self-hosted LlamaParse:** documented Enterprise path runs on Kubernetes + uses external model APIs (OpenAI/Anthropic/Google). Not phone-only.
- **Verdict: EXCLUDED from on-device pipeline.** Using it would send every medical report to a server by default — direct violation of §2.
- **Local path (fixed):** digital PDFs → native text/layout extraction; scans/photos → **already-local vision LLM transcription first** (zero new deps), with **PP-OCRv6-tiny ONNX via ONNX Runtime mobile** as the open-source challenger to trial on fixtures; structured medical facts → local LLM extractor with validators. ML Kit removed (closed SDK + telemetry conflicts with fully-open intent). Tesseract is never a default — it is only LiteParse's bundled fallback.
- **LiteParse verdict (updated):** parser-integration candidate, NOT an OCR model and NOT a phone dependency — Rust core, PDFium, platforms Linux/macOS/Windows only, no Android/iOS/Dart bindings (verified from official README). Use desktop-side for fixture generation/eval and `is-complex`-style routing ideas.
- Full evaluation in `docs/research/local-ocr.md` + `docs/product-brief.md` § Document parser evaluation.

## 7. Tech choices (candidates until Phase 0 verifies on phones)

- **App framework:** Flutter — **locked in via `flutter_edge_ai` core + `flutter_edge_ai_litertlm` engine** (renamed from `flutter_gemma*`; verified on pub.dev). Reference phone #1: Samsung S24 Ultra (debug APK built).
- **Local inference:** LiteRT-LM (Android Maven `litertlm-android:0.18.0` pinned; iOS Swift SPM exact 0.18.0 trial). Models trialed on-device; none finally selected yet.
- **Voice:** verified on-device STT/TTS path (offline packs where available) + Whisper.cpp trial; wake: openWakeWord / Porcupine / platform phrase, foreground only V1. If local STT unavailable for device/language → typed input, never silent remote STT.
- **DB/search:** SQLite + FTS5 + sqlite-vec (or ObjectBox/LanceDB if vec perf fails) + SQLCipher.
- **Notifications:** flutter_local_notifications / UserNotifications + WorkManager/BGTask; LLM never schedules directly.
- Declare in Phase 0: 2 reference phones + min RAM/storage + max sec/report + max sec/query + thresholds on synthetic set.

## 8. LLM roles — same model, 4 system prompts

| Role | Job | App enforcement |
| --- | --- | --- |
| Organizer | Propose `type` (lab/prescription/radiology/discharge/vaccination/growth/note/other), clinical `eventDate`, provider from source | Validate category allowlist + date-evidence grounding; keep unknown/ambiguous as unknown; age-at-event is estimated, never a DOB |
| Extractor | Propose facts with original value/unit/range + page/region + confidence | Validate schema + source refs + exact numeric grounding; flag unsupported/uncertain for review; never invent |
| Summarizer | Explain retrieved evidence + user history in English Markdown (Overview/Findings/Medicines/Open questions) | Check citations; keep AI interpretation distinct from reported facts; clear stored summary on correction |
| Planner | Propose bounded tool calls (`search_records`, `web_search`, `conversation`) | Enforce 3-tool allowlist + shape in code; `web_search` invoked autonomously by local LLM with query-only gate (no per-search tap, no vault/history); reports/web results never authorize new tool calls |

Prompts versioned (`prompt_vX.Y` stored per extraction). Regeneration preserves `user_corrected=true`. Confidence = review priority only, never shown as medical probability.

## 9. Data model (conceptual — see product-brief for authoritative entities)

- `profiles(id, dob / age+ref_date, relation, language)`
- `reports(id, profile_id, type, event_date, upload_date, provider, file_enc, status, model_ver, prompt_ver)`
- `facts(id, profile_id, report_id, kind, name_norm/raw, value_num/text, unit, ref_low/high, event_date, page/span, review_state, user_corrected)`
- `corrections(fact_id, replacement, timestamp, supersedes_extraction)` — retained across regen
- `chunks(profile_id, report_id, page/region, text, embedding_model/ver/dim, vec, index_status)`
- `medicines(... strength/dose/route/frequency, range, source_report, active)` + `reminders + adherence(taken/skipped/missed, confirmed_at)` — never infer taken from delivered
- `exports(id, profile_id, report_ids, redaction_log, target: file/chatgpt/claude, reviewed, created_at)`

Enforce `WHERE profile_id=?` everywhere including vector search.

## 10. Privacy, security, safety

- Keys in Android Keystore / iOS Keychain; no health in logs/crash/analytics.
- Biometric gate for caregiver/child profile; no ads/trackers.
- Med lookup: autonomous generic query only, sources + date shown, history never attached.
- Disclaimer on summaries/image outputs; emergency symptoms → urgent-care advice.
- Backup: explicit encrypted backup/restore file user owns (survive lost phone). No AyuMitra server.

## 11. Delivery plan

- **Phase 0 — Prove local feasibility (no week commitment):** benchmark LLM/VLM + EmbeddingGemma 2 variants + voice on 1 Android + 1 iPhone with synthetic reports. Record storage, peak RAM, import time, answer latency, thermal, extraction accuracy, retrieval recall, unsupported claims. Select variants + devices.
- **Phase 1 — One record flow (MVP):** onboarding → import PDF/photo → vault → editable facts → search → summary with links. Offline after install.
- **Phase 2 — Daily support:** voice I/O + foreground wake, meds + OS reminders + adherence + autonomous query-only web lookup (no tap).
- **Phase 3 — Portable:** de-id export preview + Export-to-ChatGPT/Claude gate + encrypted backup/restore + caregiver flows.
- **Phase 4 — Expand (after eval):** more formats, growth/trend charts, background wake integrations, gated V2 image-differential.

## 12. Acceptance for first record flow (airplane mode after install)

- Import synthetic PDF + photo → inspect source links → correct a fact → restart → regenerate → correction persists.
- Profile B never leaks into Profile A search/answer.
- Local failure never triggers cloud fallback.
- Originals accessible when extraction fails; resume without duplicates.
- Prompt-injection test: document with instructions cannot change meds, access other profile, or transmit record.
- Later gates: real OS reminder + correct dose event; exported file inspected for recoverable identifiers in visible text, hidden text, images, metadata.

## 13. Open decisions

**Locked since last review:** reference phone #1 = Samsung S24 Ultra (APK built); language = English v1; fully open-source under github.com/ayumitra; web search = autonomous local-LLM invocation, query-only, no per-search tap; OCR = vision-LLM first, PP-OCRv6-tiny ONNX challenger, ML Kit removed, Tesseract never default.

1. Which EmbeddingGemma 2 variant fits target phones/modalities?
2. iPhone reference device + min specs + latency thresholds?
3. Caregiver-only V1 or multi-profile day one?

Embedding on-device + always-local (with autonomous query-only search) are fixed requirements. No model variant, iOS wiring, or diagnostic behavior selected/implemented yet.

---
*Next: S24 Ultra trial numbers on fixtures → iOS SPM wiring + link check → lock remaining §13 → longitudinal + sharing milestones.*
