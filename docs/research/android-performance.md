# Android performance: Gemma 4 on S24 Ultra (MSG-070)

**Owner:** Sub (Muse Spark) | **Checked:** 2026-10-13 | **Status:** research only — no S24 Ultra measurements exist yet
**Rule:** labels below are strict. **PUBLISHED** = vendor docs/dependency source fetched this date. **MAIN-VERIFIED** = figures Main confirmed from official pages (not re-fetched here). **PROPOSED** = benchmark plan, no numbers. **SOURCE-VERIFIED** = current repository/dependency code. **MEASURED** is reserved for actual runtime results. Nothing here is an S24 Ultra measurement. Do not promise S24 TPS from S26 figures.

## 0. Runtime direction

- The reference phone (S24 Ultra, Snapdragon 8 Gen 3: Adreno 750 GPU + Hexagon NPU) can request CPU, GPU, and the Qualcomm NPU backend, but only CPU and GPU have vendor-published Gemma 4 numbers, and those numbers are for the **S26 Ultra**, not our phone.
- Our app today asks GPU, never checks what actually ran, and leaves MTP + float32 at defaults. The cheapest wins are all observability: read `activeBackend`, log it per report/query, then tune.
- NPU is a request, not a proof — including on Qualcomm hardware. The plugin source says so explicitly; this app has not opted into Qualcomm QNN.

## 1. PUBLISHED — Gemma 4 vendor figures (S26 Ultra, not S24)

Source: `https://developers.google.com/edge/litert-lm/models/gemma-4` (fetched 2026-10-13; page updated 2026-09-04). E2B = 2.58 GB, E4B = 3.65 GB, Apache-2.0.

| Model | Backend (S26 Ultra) | Prefill tok/s | Decode tok/s | TTFT | Peak mem |
|---|---|---|---|---|---|
| E2B | GPU | 3808 | 52 | 0.3 s | 676 MB |
| E2B | CPU | 557 | 47 | 1.8 s | 1733 MB |
| E4B | GPU | 1293 | 22 | 0.8 s | 710 MB |
| E4B | CPU | 195 | 18 | 5.3 s | 3283 MB |

MTP guidance (same page): up to 2.2x decode on mobile GPU, 1.5x on mobile CPU; universally recommended on GPU; E2B-on-CPU selectively (rewrite/summarize/coding yes, freeform maybe slower).

Why this does not transfer: S26 Ultra SoC is two generations newer than the S24 Ultra's Snapdragon 8 Gen 3. Device, model artifact, precision, and runtime settings differ. Treat S26 numbers as a reference only; the S24 results require measurement.

## 2. PUBLISHED — Android runtime routes (Kotlin guide)

Source: `https://developers.google.com/edge/litert-lm/android` (fetched 2026-10-13; updated 2026-09-04).

- Backends: `Backend.GPU()`, `Backend.CPU()`, `Backend.NPU(nativeLibraryDir = ...)` via `EngineConfig`; vision/audio backends selectable separately.
- GPU needs manifest entries (`libvndksupport.so`, `libOpenCL.so`, `required=false`) — Adreno path is OpenCL. Our pinned `flutter_edge_ai` Android library declares these, so they are supplied by manifest merging; they need not be duplicated in the app manifest.
- MTP is opt-in: `ExperimentalFlags.enableSpeculativeDecoding = true` before `Engine.initialize()`.
- Thinking models: `ThinkingConfig(enableThinking, thinkingTokenBudget, maxOutputToken)` per conversation/message.
- `engine.initialize()` can take ~10 s: background thread mandated.

## 3. PUBLISHED — EmbeddingGemma 2 API + prefixes

Source: `https://developers.google.com/edge/litert-lm/embedding_models` (fetched 2026-10-13; updated 2026-10-06).

- Task prefixes are normative, not decoration: `task: search result | text:` (index), `task: search query | text:` (query), plus classification/clustering/symmetric variants. Trim whitespace first.
- Kotlin `EmbeddingEngine` API (`EmbeddingEngineConfig`, `initialize`, `computeEmbedding(listOf(InputData.Text)).embedding`, backend + vision/audio backends) matches our bridge 1:1.
- CLI pinned at `litert-lm==0.18.0`, matching our Maven pin.

MAIN-VERIFIED (not re-fetched): overview-page EG2 text latency S26 CPU ~27.1 ms / GPU ~25.9 ms; variants 270M/165 MB, 440M/388 MB, 740M/485 MB.

## 4. SOURCE — what the pinned Flutter stack actually supports

From `flutter_edge_ai-2.2.1` + `flutter_edge_ai_litertlm-1.12.0` sources in the local pub cache (exact pinned code, read 2026-10-13):

- `PreferredBackend { cpu, gpu, npu }`; Android NPU requires Qualcomm hardware **and explicit app opt-in** (`hooks.user_defines.flutter_edge_ai_litertlm.qualcomm_npu: true`). The plugin does not ship Qualcomm QNN by default; opt-in downloads its runtime under the Qualcomm AI Stack License. Ayumitra has not enabled this. Windows has a separate Intel NPU route.
- `InferenceModel.activeBackend` reports the backend chosen by the plugin; collect it rather than assuming the requested backend ran. GPU/NPU fall back GPU→CPU without error; CPU never falls back. Quoting the source: the source describes a historical Mac request reporting `activeBackend == npu` while running elsewhere — "npu is a request, not a proof."
- `ActivationDataType.float32` is the documented fix for GPU digit corruption on long prompts (`2026/06/23` → `20226/12/17`, every run): Gemma 4 does this on Adreno (LiteRT-LM#3012) and Metal (#2814); published `.litertlm` files ask for fp16. Cost: slower prefill + more GPU memory; decode unchanged. CPU/NPU executors ignore the setting; vision/audio encoders keep the model file's precision.
- MTP is plumbable from Flutter (`enableSpeculativeDecoding` in runtime config / `FlutterEdgeAi.getActiveModel`), but nothing in our app sets it.

## 5. SOURCE-VERIFIED — what our app requests today

- `lib/services/local_intelligence.dart:63,117`: requests `preferredBackend: PreferredBackend.gpu` for both vision and text paths. Never reads `activeBackend`, never sets float32, never enables MTP.
- `android/.../LocalEmbeddingBridge.kt:103`: embeddings run `Backend.CPU()`; header notes GPU needs manifest entries + a code switch.
- Consequence: on the S24 Ultra we cannot currently tell CPU from GPU from NPU-fallback in any log, and long-prompt digit fidelity on Adreno 750 is unguarded. Fix is observability first (log `activeBackend` per session), then A/B.

## 6. PUBLISHED (vendor hardware) — S24 Ultra SoC position

- Galaxy S24 Ultra ships Snapdragon 8 Gen 3 for Galaxy in all regions (Samsung official specs: `samsung.com/global/galaxy/galaxy-s24-ultra/specs/`; Qualcomm platform page confirms the 8 Gen 3 family: Adreno 750 GPU with OpenCL, Hexagon NPU with QNN). Citation depth limited: Qualcomm page returned title-only to the fetcher on 2026-10-13, so treat the Adreno-750/Hexagon specifics as vendor-published pending a re-fetch, not as verified text.
- Positional consequence, not a measurement: the SoC qualifies for the plugin's Qualcomm-only NPU route in principle, but §1 shows no vendor NPU numbers for Gemma 4 on any phone, and §4 shows the request may silently run elsewhere. NPU stays an experiment with `activeBackend` proof required — never a plan-A for medical digits.
- Device inventory: `adb` is installed at `/Users/kritirai/Library/Android/sdk/platform-tools/adb` (not on the shell PATH). Main ran `adb devices -l`: no devices are connected. This document contains no phone performance measurements.

## 7. PROPOSED — no-cloud synthetic benchmark steps

Constraints: synthetic fixtures only (F01–F12), airplane mode after model install, model acquisition is a separate explicit setup step, no health data, S24 Ultra only.

1. **Backend truth:** log `activeBackend` after every `getActiveModel` (text + vision) and after bridge `load`; record per report import and per query. Matrix: CPU-forced, GPU-requested, NPU-requested × E2B. NPU needs a compatible artifact/runtime, reported backend, and device profiling evidence; a requested or reported label alone is insufficient proof.
2. **Latency set per cell:** TTFT, prefill tok/s (fixed 512-token synthetic prompt), decode tok/s (200 generated tokens, `think:false`-class short JSON + one 400-token summary), 3 cold + 5 warm runs, median + range. Thermal note after 10 min soak.
3. **Digit fidelity (Adreno gate):** F01/F08 lab numbers through GPU-default vs `float32` builds; exact-match rate on `Hb/WBC/Platelets` values; record prefill delta of float32. Ship criterion: 100% exact on fixtures before any GPU-default release.
4. **MTP A/B:** `enableSpeculativeDecoding` on/off × GPU/CPU on E2B organizer+extractor prompts; decode tok/s + exact-JSON validity rate (MTP must not buy speed with schema breakage).
5. **Memory:** peak RSS + GPU mem per backend (vendor claims 676 MB GPU / 1733 MB CPU on S26; record ours), APK/model-file MB on disk.
6. **Embeddings:** EG2 270M vs 440M text latency + recall@3 on `retrieval_questions.md`, per backend; record `embedding_model/ver/dim` per chunk as today.
7. **Exit rule (proposed, not committed):** publish the table; lock backend + float32 + MTP + variant only on measured S24 wins. Until then the current app requests GPU with the plugin fallback behavior; backend logging is proposed, not yet implemented.

## 8. Remaining benchmark decisions

1. Is NPU worth even the trial given no vendor numbers and the silent-fallback hazard, or CPU/GPU-only for v1?
2. E2B (2.58 GB) vs E4B (3.65 GB) on a 12 GB phone with vault growth — set a RAM ceiling before trialing E4B?
3. Who runs the S24 matrix, and where do numbers land (eval-plan appendix vs this doc)?
