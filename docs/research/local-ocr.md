# Local OCR research — LiteParse vs open-source mobile OCR vs vision-LLM transcription (MSG-027)

**Owner:** Sub (Muse Spark) | **Checked:** 2026-10-12 | **Status:** docs-verified; on-device numbers still require S24 Ultra trials
**Rule:** English v1. All inference local. Source images preserved. Uncertain transcription flagged for review. Tesseract is never selected as a default (see §1).

## 0. Human question first: "why Tesseract instead of LiteParse?"

LiteParse **bundles Tesseract** as its built-in OCR engine (zero setup). LiteParse is a *parser integration* (PDFium text + layout + boxes + Markdown); Tesseract is the *OCR model inside it*. The real choice is: which OCR/transcription engine reads scans on the phone, and which parser structures digital PDFs. Evidence below, guesses labeled.

## 1. LiteParse mobile packaging (verified from official README)

Source: `https://github.com/run-llama/liteparse` (fetched 2026-10-12; Apache-2.0).

- **What it is:** Rust workspace, PDFium spatial text (~2–5 ms/page), bounding boxes, layout blocks, Markdown/JSON/text, screenshots, `is-complex` routing predicate, worker-pool mode.
- **Platforms (documented):** Linux, macOS (Intel/ARM), Windows. **Bindings:** Node (napi-rs), Python (PyO3), WASM, CLI. **No Android, no iOS, no Dart/Kotlin/Swift packaging.** Mobile port = Rust core + PDFium + OCR engine to both phones — a project, not a dependency.
- **OCR inside:** built-in Tesseract (bundled); HTTP OCR API with `ocr/` wrappers for EasyOCR and **PaddleOCR**; `ocr/rapidocr` runs PaddleOCR PP-OCRv5-mobile on ONNX Runtime, 20–40× faster per CPU page than their baseline.
- **Benchmarks (their harness, M2 Max, 2026-09-09):** LiteParse+PaddleOCR beats LiteParse+Tesseract on every suite (ParseBench 0.389 vs 0.380; table TEDS 0.832; old_scans 46.4 vs 42.5; long_tiny_text 54.0 vs 54.1 ≈ tie). PaddleOCR's edge concentrates in scans — exactly our Lane B/C.
- **Verdict:** desktop eval/reference + `is-complex`-style routing concept only. Use it to generate/check fixtures and to benchmark parsers on a workstation; **not a phone dependency**.

## 2. Modern open-source mobile OCR: PaddleOCR + ONNX Runtime (verified from official sources)

Sources: `https://github.com/PaddlePaddle/PaddleOCR` README (Apache-2.0, 70k+ stars) + `https://onnxruntime.ai/docs/tutorials/mobile/` (both fetched 2026-10-12).

- **PP-OCRv6 (2026-06, 3.7.0):** tiny **1.5M** / small 7.7M / medium 34.5M tiers explicitly positioned for **edge, mobile, server**; 50 languages, single unified model (covers English v1 trivially); 5.2× CPU speedup claim; models on HuggingFace/ModelScope; ONNX export supported; high-perf inference via ONNX Runtime.
- **PP-OCRv5 evidence:** 2M-param multilingual recognizer; LiteParse benches above show it beating Tesseract on scans. PP-OCRv6 claims +4.6% detection / +5.1% recognition over v5.
- **ONNX Runtime mobile (official):** Android `onnxruntime-android` (Java/C/C++, NNAPI/XNNPACK), iOS `onnxruntime-c` / `onnxruntime-objc` (CoreML/XNNPACK), CPU default; custom minimal builds cut AAR 24 MB → 7.5 MB. No Flutter plugin out of the box — integration = platform channels + native ORT session, **same pattern as our shipped embeddings bridge**.
- **Verdict:** strongest open-source phone-OCR candidate: **PP-OCRv6-tiny ONNX via ORT mobile** behind `app.ayumitra/ocr` channels. Trial next on F02/F03/F10 measuring word accuracy, per-page latency, MB, and peak RAM on the S24 Ultra before any selection. Nothing installed or chosen by default (per MSG-027).

## 3. Local vision-LLM transcription (already in app — Phase-1 path)

Evidence: LiteRT-LM overview multimodality + `flutter_edge_ai` stack (see `local-runtime.md`); Main's direction in MSG-027.

- **Shape:** already-local Gemma-class VLM with vision backend transcribes scan/camera pages to text; digital PDFs keep native text/layout extraction (pdfrx, already a dependency).
- **Strengths (claimed):** zero new dependencies; emits structured rows the extractor can validate.
- **Unmeasured hypothesis — not evidence:** any VLM tolerance of skew/glare/handwriting over classical OCR is unproven on our phones; the choice awaits S24 Ultra fixture trials (F02/F03/F10). Do not present it as established.
- **Costs/risks:** GB-scale model RAM, seconds-per-page latency, hallucination risk. Exact-text validators check extraction **against the transcript only** — they do not establish transcript accuracy against the image and must never be presented as sufficient anti-hallucination mitigation. Every scan stays `needsReview`; no guessed coordinates, no plaintext scratch. Transcription is data, never instructions.
- **Verdict:** correct Phase-1 default for scans (already implemented direction). OCR-trial (PP-OCRv6-tiny) is the challenger, judged on fixtures — not the other way round.

## 4. Recommendation matrix (device/integration evidence vs guesses)

| Lane | Now (verified in-app) | Challenger (trial on S24 Ultra) | Rejected / deferred |
|---|---|---|---|
| A digital PDF | native text/layout extraction (pdfrx) | LiteParse **desktop-side** eval of table fidelity | LiteParse on-device (no mobile packaging — evidence §1) |
| B scan / C camera | local vision-LLM transcription + validators + review flags | PP-OCRv6-tiny ONNX via ORT mobile channels | Tesseract default (older, loses to PaddleOCR on scans — evidence §1); ML Kit (closed SDK + telemetry — removed per MSG-027) |

**Licensing (corrected per MSG-029):** LiteParse code Apache-2.0; PaddleOCR code Apache-2.0; ONNX Runtime **MIT** (upstream microsoft/onnxruntime/LICENSE) — not Apache. Model-weights licenses (PP-OCRv6-tiny etc.) must be verified separately on their HF/ModelScope pages at selection time. ML Kit removal already justified on licensing + telemetry grounds.

**Why not Tesseract (human answer, retained):** it is LiteParse's bundled fallback, not a competing parser; benchmarks show PaddleOCR open models beat it where it matters (scans); and nothing in our pipeline needs it once vision-LLM + PP-OCR-ONNX trials run. No Tesseract install, no default.

## 5. Open trial protocol (for Main's build queue)

On S24 Ultra, synthetic F02 (clean) / F03 (camera-degraded) / F10 (partial): word-error-rate vs manifest text, per-page ms, added MB, peak RSS, and extraction F1 downstream. Promote challenger only on measured wins; keep vision-LLM as fallback for difficult regions either way. LiteParse and PaddleOCR code are Apache-2.0; ONNX Runtime is MIT. Verify selected model-weight licenses separately. These open-source code licenses support the project intent; ML Kit removal already justified on licensing + telemetry grounds.

## 6. Unlimited-OCR (record-only, deferred — human request)

- **What it is:** Baidu `baidu/Unlimited-OCR` (June 2026, arXiv 2606.23050, DeepSeek-OCR lineage), image-text-to-text document parsing VLM. Verified via HF API 2026-10-12: **3.336B params BF16 (~6.77 GB)**, license **MIT**, `custom_code` (`trust_remote_code=True`, custom `modeling_unlimitedocr.py`), inference via transformers-on-CUDA / vLLM / SGLang (all server-grade). Community GGUF quants exist (no official mobile story).
- **Phone verdict: not viable for V1.** GB-scale resident memory, CUDA-only official path, no ONNX/LiteRT export, no Android/iOS bindings; multimodal GGUF on mobile is slow and battery-hostile. It competes with the vision-LLM transcription role, not with parser integrations — and loses on deployability to the already-shipped path and the PP-OCRv6-tiny challenger.
- **Desktop verdict: eval candidate (recorded, not trialed).** MIT + multilingual + strong ParseBench/OmniDocBench numbers make it a candidate for workstation-side transcription benchmarking on F02/F03/F10 to set the quality ceiling. No runtime, weights, or dependency changes; no cloud calls from the app. Fixtures are synthetic, so even a hosted trial would touch no real data — prefer a local-GPU run regardless.
- **Status:** idea recorded like decision models — deferred until after POC. Revisit only if a tiny/mobile-exportable variant appears.
