# Local runtime research — Flutter + LiteRT-LM + EmbeddingGemma 2 + small vision LLM

**Owner:** Sub (Muse Spark) | **Date checked:** 2026-10-12 | **Status:** cited findings, nothing tested on our phones yet
**Scope:** integration path only. No model selected. Real-phone numbers still require user's devices — do not invent.

## 1. LiteRT-LM status (official overview)

Source: `https://developers.google.com/edge/litert-lm/overview` (fetched 2026-10-12; page last-updated 2026-10-06 UTC per footer).

- Production-ready orchestration layer over LiteRT; cross-platform Android / iOS / Web / Desktop / IoT; CPU everywhere; GPU on Android/iOS/macOS/Windows/Linux; NPU Android + early Windows.
- Multimodal support (vision + audio) and **multimodal embeddings** for on-device RAG; function calling with constrained decoding for agentic tool use.
- Language-API maturity (same page): CLI stable, Python stable, **Kotlin stable**, **Swift early preview**, JavaScript early preview, **Flutter community** (`flutter_gemma`), C++ stable.
- Reference offline showcase: Google AI Edge Gallery (Play + App Store + `https://github.com/google-ai-edge/gallery`) — useful as integration reference, not a dependency.

Implication for AyuMitra: Kotlin path is lowest-risk; Swift path must be trialed as early-preview; Flutter path inherits both plus community-package risk — verify on both reference phones before locking framework (matches brief).

## 2. EmbeddingGemma 2 variants (same official page)

| Variant | Modalities | Size |
|---|---|---|
| EmbeddingGemma 2 740M | text + image + video + audio | 485 MB |
| EmbeddingGemma 2 Text-Vision 440M | text + image | 388 MB |
| EmbeddingGemma 2 Text 270M | text | 165 MB |

Model cards under `https://huggingface.co/litert-community/` (org linked from same overview). Published latencies on that page (examples): Pixel 11-class TPU text ~8ms; S26-Ultra-class CPU text ~27ms; iPhone-class CPU text ~42ms / GPU ~12ms; text+vision ~50–190ms depending on device/backend; Raspberry Pi CPU text ~161ms. Treat as vendor reference, not our measurement.

Trial order proposal: **Text 270M (165 MB) first** (smallest, text-only lanes A/B), then Text-Vision 440M if image-region search needs it, then 740M omnimodal only if justified — each step re-records MB/RAM/latency/recall@3 on eval fixtures. Store `model/ver/dim` per chunk; never mix.

Note: direct EmbeddingGemma doc page fetch failed today (transport error); rely on LiteRT overview + HF model cards above until re-checked.

## 3. Small chat / vision LLM candidates (same overview table)

| Model | Size on disk | Notes from page |
|---|---|---|
| Qwen3-0.6B | 586 MB | smallest general chat listed |
| Qwen2.5-0.5B | 521 MB | small, text |
| Gemma3-1B | 1005 MB | small Gemma chat |
| Qwen2.5-1.5B | 1598 MB | balanced |
| Gemma4-E2B | 2583 MB | flagship chat, fastest decode in table |
| Gemma-3n-E2B / E4B | 2965 / 4235 MB | multimodal (vision per model family; verify per card) |
| phi-4-mini | 3906 MB | large for phones |
| FunctionGemma 270M | 289 MB | function-calling specialist, not general chat |

Vendor perf (same page, flagship example): Gemma4-E2B S26-Ultra GPU prefill ~3808 tok/s, decode ~52 tok/s, TTFT 0.3s; iPhone-17-Pro-class GPU similar band; CPU-only an order slower. Older small models (S24-Ultra-class): 1B models ~30 tok/s decode CPU. Again: reference only.

Trial order proposal: Qwen3-0.6B → Gemma3-1B → Gemma4-E2B for organizer/extractor/summarizer/planner prompts; vision understanding via Gemma-3n family **only after** confirming the exact `.litertlm` bundle's vision encoder + measuring on-device (vision encoders keep model-file precision; text-decoder GPU float32 note below applies to text side).

## 4. Flutter integration path (community packages — trial, not lock)

Sources (fetched via search 2026-10-12): `https://pub.dev/packages/flutter_gemma_litertlm`, `https://fluttergemma.dev/docs/litertlm`, `https://github.com/thereisnotime/flutter_litert_lm`, `https://pub.dev/packages/lib_litert_lm`.

- Primary community route: `flutter_gemma` + `flutter_gemma_litertlm` via `dart:ffi`. Register `LiteRtLmEngine()` at init; declare `ModelFileType.litertlm` explicitly when installing (default routes to MediaPipe `.task` otherwise). Models install from HF URLs (e.g. `litert-community/...litertlm`) with progress; keep model for app lifetime; pick `preferredBackend` (cpu/gpu/npu) per device.
- Embeddings in same stack: `LiteRtEmbeddingBackend` runs Gecko/EmbeddingGemma `.tflite` via LiteRT C API; pipeline + worker isolate live in `flutter_gemma`; tokenizers from `flutter_gemma_embeddings`. Native lib bundled at build via Native-Assets hook (SHA256-verified per docs).
- Android manifest needs (per `lib_litert_lm` docs): `largeHeap=true`, optional `libvndksupport/libOpenCL` entries; GPU needs real device (emulator lacks OpenCL — use CPU there).
- Known issues to re-verify at trial (from package changelogs/issues quoted in search):
  - Mali GPUs (Samsung A-series/MediaTek/Tensor): GPU-backend crash fixed in 1.8.2 — retest on our Android reference phone.
  - Garbled/empty streams when embedding before first generation — fixed 1.5.2; still load `libLiteRtLm` correctly (RTLD_GLOBAL note).
  - Wrong digits on GPU ≥~2000 prompt tokens (Adreno/Metal) — fix `activationDataType: float32` on `getActiveModel` (needs ≥1.8.3), at prefill cost; verify with lab-number fixtures F01/F08.
  - NPU verified for Gemma 4 bundles; Gemma 3 on NPU reported silent wrong answers — do not use NPU for Gemma 3; expect CPU/GPU fallback and check `activeBackend`.
  - Alt plugin `flutter_litert_lm` notes iOS CPU-only (Metal GPU dylib not shipped for iOS in that runtime) + iOS sampler knobs ignored — if Main trials that package, confirm against `flutter_gemma_litertlm` behavior on our iPhone; do not assume GPU on iOS.
- Alternative: `lib_litert_lm` is Android-only FFI + local OpenAI-compatible server for testing — useful for trial harness, not shipping path.

## 5. What Main should trial first (proposal)

1. `flutter_gemma` + `flutter_gemma_litertlm` on both reference phones (devices TBD): load Qwen3-0.6B `.litertlm` CPU, run F01 organizer+extractor prompts, record TTFT/decode/RAM.
2. Same harness, EmbeddingGemma-2-Text 270M: embed row-chunks vs context-chunks (T3), record ms/chunk + recall@3 on N1–S4.
3. GPU rerun on Android; CPU-only on iOS until Metal path verified; note digit-fidelity on F01/F08 values.
4. Vision: only after 1–3 pass — Gemma-3n `.litertlm` on F02/F03/F10 regions; compare vs ML Kit/Tesseract OCR baseline; vision is fallback for difficult regions (per MSG-011), not default.

## 6. Open / unverified

- Exact `.litertlm` bundle + tokenizer files for the chosen EmbeddingGemma variant in Flutter build (verify from HF card at trial time).
- Swift early-preview API surface if Main goes native iOS instead of Flutter.
- Thermal + background-OS limits for long extractions (chunk work, resume without duplicates).
- Hindi/Hinglish STT path still needs human locale lock (T5) — separate from this doc.

*All sizes/latencies above are vendor-published references from the cited pages, not AyuMitra measurements. Phase-0 must replace them with our numbers on the fixed synthetic set.*

## 7. Addendum 2026-10-12 (tick 2 — verified, not substituted)

- **Rename confirmed:** `flutter_gemma_litertlm` 1.8.6 on pub.dev is marked discontinued: "Moved to `flutter_edge_ai_litertlm`, part of Flutter Edge AI." Migration = replace dep, change import to `package:flutter_edge_ai_litertlm/...`, `dart fix --apply`; installed models/app data carry over. Main's MSG-014b claim verified — use `flutter_edge_ai` core (2.2.0 per Main) + `flutter_edge_ai_litertlm` engine for any Flutter-side trial. No v1 TFLite/tokenizer API substituted for v2 anywhere in this doc.
- **Android Maven pinned:** Google Maven metadata for `com.google.ai.edge.litertlm:litertlm-android` lists latest release **0.18.0** (metadata lastUpdated 20261006154905), matching CLI `litert-lm==0.18.0` in the embedding guide. Bridge requests pinned `0.18.0`, not `latest.release`, for reproducible builds.
- **iOS Swift equivalent (report only, no iOS edits):** per the same embedding-models page (Swift tab): `import LiteRTLM`; `EmbeddingEngine(config: .init(modelPath:visionBackend:audioBackend:))`; `try await engine.initialize()`; `computeEmbedding(contents:)`; `close()`. Distribution/packaging (SPM/XCFramework) to be confirmed by Main at scaffold time against the Swift guide; Swift API remains early preview per overview.
