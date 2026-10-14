# AyuMitra — IDEA.md
**Status:** Flutter prototype in development — English v1, DOB profiles/sessions, local Markdown extraction, readings/trends, local drafts, and optional cloud model selection with a one-time privacy disclosure; current-round live provider and hardware-quality checks are not claimed
**Date:** 14 Oct 2026 (updated after user testing and Muse review)
**Author intent:** Built for my child, designed for everyone. A local-first medical companion for Android + iOS, **fully open-source and community-contributable (github.com/ayumitra)**.
**Source of truth for requirements:** `docs/product-brief.md`. This file is the implementation plan that follows it.

## 1. Vision in one paragraph

AyuMitra is a lifelong, private medical companion that lives on your phone. You can speak or type naturally — “Add this blood report”, “what was my HbA1c trend?”, “remind me for medicines at 8pm” — and it keeps every report, photo, prescription, and note as a searchable personal history. It understands reports and images locally, explains them in simple language, tracks medicines and schedules, and can produce a clean, anonymised summary you can share with a doctor. On first start it asks for date of birth and an optional past-history summary to bootstrap memory. Wake-word work is parked; tap-to-talk and typing remain the current interaction paths.

Agentic means the companion can file, extract, search and draft from a conversation. A dedicated profile Files library also lets users add originals or scan up to five pages without creating a conversation turn. Medicine reminders and other roadmap tools remain separate work.

Long-term, AyuMitra is a companion for life: it keeps each person's owned context — reports, readings, medicines, conversations — across decades on their own devices, with no app sign-in and no AyuMitra user backend or central vault. On-device capability improves over time through fine-tuned edge models; private records are never training data by default. Optional direct provider keys remain strictly opt-in.

## 2. Core principle: local by default, explicit cloud model choice

**Private record processing and ordinary answers stay local. Only an explicitly selected cloud chat mode, after a one-time privacy acknowledgment, sends questions and selected health text directly to the chosen OpenAI or Anthropic provider; it is never a fallback.**

That means:

1. **Default = zero network for health data.** Organize / extract / search / summarize all run on-device. This includes embeddings — see §5.
2. **Network touchpoints have separate boundaries:**
   - (a) Model downloads (system setup, progress shown, no health data).
   - (b) Web search for general public information — invoked **autonomously by the local planner LLM** (no per-search tap). App code enforces query-only: standalone generic query, never vault/history/reports; `publicQueryAllowed` gate; results are untrusted data; no remote inference, no sharing. Brave API key configured once in settings.
   - (c) Export / Share — only after user taps Export / “Open in …”, after preview + review.
   - (d) Optional cloud chat — the user saves an OpenAI or Anthropic key in secure storage, acknowledges the privacy warning once, and selects the cloud model. Send routes the question and selected health text directly to that provider without repeated confirmation popups. The provider receives the API key and text. No gateway URL or separate server setup is needed. No original files/images or automatic fallback. Provider retention policies and charges apply.
3. **No silent fallback.** If local models/STT fail offline, show degraded state + typed input + keyword search. Never quietly switch to a cloud API. Web search degrades to local-only answers with a notice. Only an explicitly selected cloud chat mode may use cloud inference; saving keys does not activate it.
4. **Original = truth.** Preserve encrypted originals. Extracted facts are a separate layer with source links (report → page → span). User corrections survive re-extraction and restart.
5. **Evidence-linked answers.** Personal findings cite their available report, user-stated conversation, history or reading provenance. Say when evidence is absent or conflicting instead of inventing values. Explain general medical topics using model knowledge and corroborating public sources; a missing uploaded report is not a reason to refuse a history draft or general explanation.
6. **One person, one vault.** Strict `profile_id` isolation across files, facts, vectors, medicines, exports.
7. **Safety over cleverness.** Image describe/transcribe first. Image-based diagnosis is a gated V2 with clinician-led evaluation, always with disclaimer.
8. **Honest cloud privacy.** Default is local and stays local. Optional cloud chat transmits the selected question and text context to the chosen provider — the app cannot prevent provider-side retention from an API key alone. Zero-data-retention (ZDR) holds only where the provider account or organization is approved for it under that provider's terms; request flags such as `store:false` are not a ZDR guarantee and the app must never present them as one. See `docs/research/cloud-data-retention.md` (internal research agent).

## 3. What the user experiences

### 3.1 Onboarding (60 seconds)
- Who is this profile for? (self / child / other). Child = caregiver mode.
- **Date of birth (required)** via picker or strict YYYY-MM-DD; future/invalid refused. Legacy age+reference-date profiles keep working with estimated labels; DOB is never invented.
- A separate Profiles manager handles create / edit / switch across people; each profile keeps an isolated vault, sessions, and memory.
- “Any past history summary?” — free text/voice, stored as `user_provided_history`, clearly marked NOT a verified report.
- Privacy screen: “Your records and ordinary answers stay on this phone. Optional cloud chat sends questions and selected health context after a one-time warning and model choice.” Embedding search remains on-device; the cloud model choice stays visible and can be switched back to Local.
- Model-download screen with size + progress. App remains usable with typing + saved reports + keyword search while models download.

### 3.2 Main interface — agent + evidence
- **Center:** voice/text chat (push-to-talk mic, typed input, TTS playback).
- **Around chat:** inline cards — Report viewer, Lab table, Trend, Medicine schedule, Export preview. Tap any AI claim → opens source page highlight.
- **Wake word:** development is parked after recognition experiments. Use the microphone button for on-device tap-to-talk; do not represent wake listening as a shipped feature. Background/locked-screen invocation remains later investigation.

Example commands:
- “Add this report” + PDF/photo → saved → queued → ready, with status chip.
- “What medicines is Aarav on?”
- “Summarize last 6 months for the pediatrician.”
- “Make a shareable version without name.”
- “What is Azithromycin 200mg used for?” → local planner autonomously adds a generic web query (no tap, query-only, no history) → answer with sources + retrieval date.

### 3.3 Reports & lifelong history
- Current imports: PDF, PNG/JPG, UTF-8 text, and camera capture; the profile Files library works independently of chat and groups up to five camera pages into one encrypted original with page references. HEIC/share-sheet support remains roadmap work.
- Status pipeline: `saved → queued → processing → needs_review / ready / failed`. Failed stays accessible + retryable, never blocks vault.
- Timeline uses a visible report date where available; dateless/ambiguous reports use the current calendar day labelled as a filing-date fallback. Date-aware questions retrieve matching owned reports. Filter by type.
- Tap citation → original page + highlighted span / image region.

### 3.4 Search (fully local)
- Hybrid: FTS keyword + vector semantic (EmbeddingGemma 2, on-device) + structured query for numeric questions.
- Narrative Q (“iron deficiency reports”) = FTS + vector. Numeric Q (“Hb < 11 in 2025?”) = SQL over `facts` with date/unit filters.
- Store `embedding_model + version + dim` per chunk. Never mix providers. Re-index on model change (local rebuild, no upload).
- Chunking: ~300–500 tokens with overlap, keep `report_id, page, char_span`. Images: caption + OCR text indexed; multimodal embedding only if local embedder supports it on-device.

### 3.5 Summaries
The same local LLM uses separate prompt roles (§8), with bounded owned report context, dated user history, current conversation and readings. Report extraction is flexible source-linked Markdown of key information and dates, not a mandatory JSON fact schema. Health reports and messages follow the requested format; user-stated history is usable even without an uploaded report and remains labelled unverified. Local drafts are editable and require review before copying. A late generation cannot overwrite edits or switch profile/session ownership. General explanations can use model knowledge and public-source corroboration.

Answer, draft and report-note validation allows up to ten total generation attempts, including the first response, with controlled repair guidance. Network/provider errors stop immediately rather than entering this loop. The independent planner keeps its three-attempt tool-plan bound.

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
2. App locally generates an editable Markdown draft from owned records, dated user statements, history and readings; a static source pack remains available if generation fails. It is not automatically anonymized, and missing uploaded reports do not invalidate user-reported context. No network call is needed for this draft.
3. Preview screen, editable, with identifier checklist.
4. User taps `Open in ChatGPT / Open in Claude` → app fires explicit share intent / universal link / copies markdown to clipboard and opens target app. **This copy/open path does not call provider APIs or submit a message; the user decides what to paste and send. The separate optional frontier path below uses its own one-time privacy acknowledgment and explicit cloud model choice.**
5. Local audit: `export id, date, target (chatgpt/claude/file), report_ids, reviewed` — no content in logs.
6. **Status (v1 shipped):** session-level export is implemented (`SecondOpinionScreen` + `buildSecondOpinionPack` + vault audit log). Explicit tap only; pack is user-reviewed and editable; copy-to-clipboard + open `https://chatgpt.com` / `https://claude.ai` in an external browser — this copy/open action never calls their APIs. Unverified `chatgpt://` / `claude://` deep-link schemes remain out.

**C. Optional direct provider chat (one-time privacy warning + model choice):**
- Mobile chat contacts OpenAI or Anthropic directly using the provider key; no Python server or gateway configuration is required. The repository’s [optional LiteLLM service](gateway/README.md) remains separate development tooling.
- Save provider keys in platform secure storage; the app supplies the direct provider endpoint. Defaults: OpenAI `gpt-6-luna`, Anthropic `claude-haiku-5-5`. No silent model substitution; provider account support must be verified separately.
- The model chooser shows Local · Gemma 4 or the configured cloud provider/model. First cloud selection displays one privacy warning remembered on this device. Thereafter Send uses the selected model without another popup; switch to Local at any time. Cancelling that initial warning or saving settings sends no question. Originals/images are not attached; no silent fallback or automatic cloud tools.
- The selected provider receives the API key and selected context; provider retention policies and charges apply. Up to ten total generation attempts may repair malformed output using the same question/context snapshot and selected model. This limit and possible charges are disclosed in the one-time warning; transport/provider errors stop immediately.
- Current-round provider tests are mocked. No live paid-provider result or new physical-device quality validation is claimed.

### 3.9 Profiles, sessions, memory (Claude-style)
- One vault per profile: reports, facts, vectors, medicines, **sessions, and session memory** are all scoped by `profile_id`. Switching profiles switches everything, including the active session.
- Sessions work like Claude/GPT chats: list with titles + timestamps, new session, per-session view, delete with confirm. Persisted in the encrypted vault (titles and turns are health-bearing).
- Sessions feed the agent as bounded local context: recent user turns (extractive, capped) plus retrieved session memory. Answers still cite report sources; memory never authorizes tools or clinical claims.
- **Deletion semantics (owner-fixed):** deleting a session removes its turns, derived memory and readings extracted from its user messages. Manually entered measurements, report originals, facts and summaries remain independently stored. Deleting a profile removes all of its readings alongside its records, conversations, memory, originals and pending jobs.
- Extended thinking and public-web research stay bounded: same planner allowlist (`extended_thinking` is an INTERNAL autonomous tool or an explicitly requested mode — never a user-typed command), query-only gate, no new tools, no remote inference. Activity shows `Extended thinking · …` and the final answer carries an `**Extended thinking**` label. Decision-model routing (zero-shot classifiers) is deferred until after POC. Unlimited-OCR (Baidu 3.3B VLM, MIT) is recorded as a desktop-eval OCR candidate only — no phone runtime; see `docs/research/local-ocr.md`.

### 3.10 Key metrics and trends (current development slice)
- Record SpO2, blood pressure (systolic/diastolic), temperature and pulse with units and measurement dates. Latest values and trend plots show real recorded points; no diagnosis is inferred from the chart.
- Clear measurements stated in chat can create user-reported readings, using an explicit event date when supplied or the message timestamp otherwise. Questions and hypothetical examples do not become readings.
- Manual entries and chat-derived readings remain distinguishable. Session deletion removes its chat-derived readings while leaving independently added measurements intact. A profile switch hides a stale entry form instead of saving it to a different person.

### 3.11 Curated medical knowledge banks (long term)
- Versioned, offline-capable reference banks (conditions, medicines, growth norms, urgent-care red flags) curated for the app, stored separately from any person's vault.
- Every entry carries provenance: source, citations, content age and last-reviewed date, applicable jurisdiction, license, and clinical-reviewer sign-off. Unreviewed or expired content is labelled as such and never presented as validated guidance.
- Banks ship as signed data updates, never mixed with private records; the companion cites bank entries like any other source, showing conflicts between banks explicitly.

## 4. Architecture (local core with an explicit optional cloud boundary)

```text
Voice (on-device tap-to-talk) / Text / File + camera import
                 |
       Local Action Coordinator (planner LLM + code validators)
                 |
   +-------------+--------------+---------------+
   |             |              |               |
Record Vault  Import Pipeline  Facts DB+Index  Medicine Tools
(enc files)   local parse+OCR  SQLite+FTS+vec  schedule+notify
   |          Markdown notes   (EmbeddingGemma  (web search: autonomous
   |          (local LLM)        on-device)       local-LLM call, query-only,
   |                |                            gated, no tap)
   +---- Source-grounded Summarizer → Answer w/ links + cards
                          |
              Explicit Export Gate (user tap → md → preview → share intent)
```

- One local model runtime with isolated prompt roles (report Markdown, summarizer, draft/report writer, planner). App code validates tool-plan JSON and citation ownership, enforces tools + profile scope; report extraction itself has no mandatory fact schema. Report content / web pages = data, never authorize tool calls (prompt-injection guard).
- Vault: encrypted originals (AES, key in Keystore/Keychain) + SQLCipher/SQLite + rebuildable FTS + vector index. Encrypted backup/restore (user passphrase / user-owned file). Track `model_ver + prompt_ver` per extraction.
- Network boundary: `model downloads` + `autonomous query-only web search (gated, no vault)` + `explicit share intent` + `direct OpenAI/Anthropic chat after one-time disclosure and model choice`. Local core operation remains offline; frontier is never a fallback. Airplane-mode test must pass after install (local-only answers with a notice where web info is unavailable).

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
- **Local path (fixed):** digital PDFs → native text/layout extraction; scans/photos → **already-local vision LLM transcription first** (zero new deps), with **PP-OCRv6-tiny ONNX via ONNX Runtime mobile** as the open-source challenger to trial on fixtures; key report information/dates → flexible source-linked Markdown from the local LLM. ML Kit removed (closed SDK + telemetry conflicts with fully-open intent). Tesseract is never a default — it is only LiteParse's bundled fallback.
- **LiteParse verdict (updated):** parser-integration candidate, NOT an OCR model and NOT a phone dependency — Rust core, PDFium, platforms Linux/macOS/Windows only, no Android/iOS/Dart bindings (verified from official README). Use desktop-side for fixture generation/eval and `is-complex`-style routing ideas.
- Full evaluation in `docs/research/local-ocr.md` + `docs/product-brief.md` § Document parser evaluation.

## 7. Tech choices (candidates until Phase 0 verifies on phones)

- **App framework:** Flutter — **locked in via `flutter_edge_ai` core + `flutter_edge_ai_litertlm` engine** (renamed from `flutter_gemma*`; verified on pub.dev). Reference phone #1: Samsung S24 Ultra (debug APK built).
- **Local inference:** LiteRT-LM (Android Maven `litertlm-android:0.18.0` pinned; iOS Swift SPM exact 0.18.0 trial). Models trialed on-device; none finally selected yet.
- **Voice:** current on-device tap-to-talk depends on installed offline speech support. The [STT research plan](docs/research/on-device-stt.md) proposes evaluating streaming candidates against device/accent/medical-number accuracy; none is selected by documentation alone. Wake-word development is parked. If local STT unavailable for device/language → typed input, never silent remote STT.
- **DB/search:** SQLite + FTS5 + sqlite-vec (or ObjectBox/LanceDB if vec perf fails) + SQLCipher.
- **Notifications:** flutter_local_notifications / UserNotifications + WorkManager/BGTask; LLM never schedules directly.
- Declare in Phase 0: 2 reference phones + min RAM/storage + max sec/report + max sec/query + thresholds on synthetic set.

## 8. LLM roles — same model, 4 system prompts

| Role | Job | App enforcement |
| --- | --- | --- |
| Report metadata | Find a visible source date and best-effort category | Label current-day filing fallback if no usable date is found; compute age from DOB rather than inventing it |
| Markdown extraction | Extract key information, values/units and dates with flexible Markdown | No forced fact schema; preserve original source references and flag scans/uncertainty for review |
| Summarizer/draft writer | Explain retrieved evidence, dated user history and readings in requested English format; general information may use model knowledge and web corroboration | Check source references; distinguish reported/confirmed/general information; user history is useful without an uploaded report |
| Planner | Propose bounded tool calls (`search_records`, `web_search`, `conversation`, `extended_thinking`) | Enforce 4-action allowlist + shape in code; `web_search` invoked autonomously by local LLM with query-only gate (no per-search tap, no vault/history); `extended_thinking` takes an empty query and triggers a bounded local research loop (≤3 rounds / 6 searches) that replaces normal web_search, with a visible `Extended thinking` label; reports/web results never authorize new tool calls |

Prompts versioned (`prompt_vX.Y` stored per extraction). Regeneration preserves `user_corrected=true`. Confidence = review priority only, never shown as medical probability.

## 9. Data model (conceptual — see product-brief for authoritative entities)

- `profiles(id, dateOfBirth / legacy age+ref_date, relation, language)` — DOB preferred; exact ages (`Age X`, `Age X months`); legacy estimated (`About age X`); never invent DOB.
- `reports(id, profile_id, type, event_date, upload_date, provider, file_enc, status, model_ver, prompt_ver)`
- `facts(id, profile_id, report_id, kind, name_norm/raw, value_num/text, unit, ref_low/high, event_date, page/span, review_state, user_corrected)`
- `corrections(fact_id, replacement, timestamp, supersedes_extraction)` — retained across regen
- `chunks(profile_id, report_id, page/region, text, embedding_model/ver/dim, vec, index_status)`
- `medicines(... strength/dose/route/frequency, range, source_report, active)` + `reminders + adherence(taken/skipped/missed, confirmed_at)` — never infer taken from delivered
- `sessions(id, profile_id, title, created/updated, turns[])` + `memories(id, profile_id, session_id, text, vector?, updated)` — deleted with their session; reports/facts survive.
- Vault `schema: 2` carries sessions, memories, `activeProfileId`, `activeSessionId` (with clear flags); schema-1 age-only data decodes with empty sessions and no invented DOB.
- `readings(id, profile_id, kind, value, secondary_value, unit, measured_at, source, source_message)` — chat-derived entries are removed with their source session; manual entries remain.
- `exports(id, profile_id, report_ids, redaction_log, target: file/chatgpt/claude, reviewed, created_at)`

Enforce `WHERE profile_id=?` everywhere including vectors, sessions, and memories.

## 10. Privacy, security, safety

- Keys in Android Keystore / iOS Keychain; no health in logs/crash/analytics.
- Biometric gate for caregiver/child profile; no ads/trackers.
- Med lookup: autonomous generic query only, sources + date shown, history never attached.
- Disclaimer on summaries/image outputs; emergency symptoms → urgent-care advice.
- No app account and no central vault backup by default: records live on the user's devices plus their own encrypted backup files. Any future assisted-recovery offering must be explicit, opt-in, and never a silent upload.
- Give practical general advice with cited sources, show conflicts between sources, and escalate to urgent care when red flags fit — but avoid blanket refusals. Nothing in the app is a validated clinical claim; diagnostic features stay gated (§2.7).
- Backup: explicit encrypted backup/restore file user owns (survive lost phone). No AyuMitra server.

## 11. Delivery plan

- **Phase 0 — Prove local feasibility (no week commitment):** benchmark LLM/VLM + EmbeddingGemma 2 variants + voice on 1 Android + 1 iPhone with synthetic reports. Record storage, peak RAM, import time, answer latency, thermal, extraction accuracy, retrieval recall, unsupported claims. Select variants + devices.
- **Phase 1 — One record flow (MVP):** onboarding → import PDF/photo → vault → editable facts → search → summary with links. Offline after install.
- **Phase 2 — Daily support:** improve voice I/O, meds + OS reminders + adherence + autonomous query-only web lookup (no tap). Wake-word development remains parked.
- **Phase 3 — Portable:** de-id export preview + Export-to-ChatGPT/Claude gate + encrypted backup/restore + caregiver flows.
- **Ayumitra edge models (long term):** use existing Gemma 4 + EmbeddingGemma 2 first; develop our own fine-tuned edge models after POC/device evaluation. Optimize local report organization/extraction, tool use and grounded summaries; measure RAM, latency, exact numbers and citation quality against the baseline. Never silently collect private records for training; inference remains local.
- **Curated knowledge banks (long term):** versioned offline banks with provenance, citations, review dates, jurisdiction and licensing (§3.11); cite entries like any source and show conflicts.
- **Phase 4 — Expand (after eval):** more formats, growth charts and richer longitudinal comparisons, background wake investigation, gated V2 image-differential. Basic recorded-reading trends already exist in the development slice.

## 12. Acceptance for first record flow (airplane mode after install)

- Import synthetic PDF + photo → inspect source links → correct a fact → restart → regenerate → correction persists.
- Profile B never leaks into Profile A search/answer.
- Local failure never triggers cloud fallback.
- Originals accessible when extraction fails; resume without duplicates.
- Prompt-injection test: document with instructions cannot change meds, access other profile, or transmit record.
- Later gates: real OS reminder + correct dose event; exported file inspected for recoverable identifiers in visible text, hidden text, images, metadata.

## 13. Open decisions

**Locked since last review:** reference phone #1 = Samsung S24 Ultra (APK built); language = English v1; fully open-source under github.com/ayumitra; web search = autonomous local-LLM invocation, query-only, no per-search tap; extended thinking = autonomous-or-toggle deep research (empty-query action, normal web skipped, ≤3 rounds / 6 searches, visible label); OCR = vision-LLM first, PP-OCRv6-tiny ONNX challenger, ML Kit removed, Tesseract never default; profiles = DOB-first with manager; sessions = Claude-style with session-scoped memory, deletion removes turns + derived memory while originals/facts survive; decision-model routing deferred post-POC; Unlimited-OCR recorded as desktop-eval candidate only.

1. Which EmbeddingGemma 2 variant fits target phones/modalities?
2. iPhone reference device + min specs + latency thresholds?
3. Caregiver-only V1 or multi-profile day one?

On-device embedding/search and local-default inference, with autonomous query-only public search and explicit cloud model selection with a remembered privacy disclosure, are fixed requirements. No model variant, iOS wiring, or diagnostic behavior selected/implemented yet.

---
*Next: S24 Ultra trial numbers on fixtures → iOS SPM wiring + link check → lock remaining §13 → longitudinal + sharing milestones.*
