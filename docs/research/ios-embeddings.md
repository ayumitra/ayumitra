# iOS EmbeddingGemma 2 integration research (MSG-022)

**Owner:** Sub (Muse Spark) | **Checked:** 2026-10-12 | **Status:** docs-verified; native linking NOT verified (needs Main at wire-up)
**Rule:** English only. On-device only. No `packages/ayumitra_embeddings_ios/` created — see §4.

## 1. Official distribution: SPM, pin 0.18.0

- Source: `https://developers.google.com/edge/litert-lm/swift` (page updated 2026-09-04) + `https://github.com/google-ai-edge/LiteRT-LM/releases` (v0.18.0 Latest, 06 Oct 2026).
- Xcode: File > Add Package Dependencies → `https://github.com/google-ai-edge/LiteRT-LM`, add **LiteRTLM** library to the Runner target (plus the Frameworks-Libraries-Embedded-Content fix documented on the page if `no such module LiteRTLM` appears).
- Package.swift: `.package(url: "https://github.com/google-ai-edge/LiteRT-LM", exact: "0.18.0")` — exact, not `from:`, for parity with Android Maven `litertlm-android:0.18.0`. Guide example shows `from: "0.12.0"`; do not use that floor.
- v0.18.0 release notes confirm EmbeddingGemma 2 (text/vision/audio, Matryoshka truncation) across **Python, Kotlin, Swift, Web, C++** — Swift embedding support ships in the same 0.18.0 line as Android.

## 2. Swift EmbeddingEngine API (official)

Source: `https://developers.google.com/edge/litert-lm/embedding_models` (Swift tab, fetched 2026-10-12):

```swift
import LiteRTLM
let engine = EmbeddingEngine(config: .init(
  modelPath: "embedding-gemma-v2.litertlm",
  backend: .gpu, visionBackend: .gpu, audioBackend: .gpu
))
try await engine.initialize()
defer { Task { await engine.close() } }
let resp = try await engine.computeEmbedding(contents: [.text("task: search query | text: ...")])
// resp.embedding — same task-prefix contract as Android/Kotlin
```

Mirror the Kotlin bridge semantics in Swift: `load(path)` validates local `.litertlm` existence; `embed(text)` trims, caps length, maps to `[Double]`; `close()` releases; serial queue (no concurrent sessions); CPU default (Metal optional later); never log text/vectors.

## 3. Conflict analysis vs `flutter_edge_ai_litertlm` bundle

- Main's finding (MSG-022, relayed, not independently verified here): the package's `native/litert_lm/include/engine.h` exposes **no embedding C API**, and its Dart `.tflite` embedding path is **v1** — therefore the Flutter plugin cannot serve EmbeddingGemma 2; a native iOS path is genuinely required.
- Risk: the plugin ships its native runtime via Native-Assets (XCFramework/static lib on iOS). If SPM `LiteRTLM` links the same C++ symbols statically, adding both to Runner can cause **duplicate-symbol link errors** (or silent ODR issues). This cannot be settled from docs — it needs the link step.
- Verification steps for Main at wire-up (Runner-owned, not mine):
  1. Inspect what `flutter_edge_ai_litertlm` embeds on iOS (static vs dynamic framework; symbol visibility).
  2. Add SPM LiteRTLM 0.18.0 to Runner, build; on duplicate symbols, check `nm -g` / link map for the colliding objects.
  3. Fallbacks in order: (a) keep both if symbols are namespaced/hidden; (b) check whether upstream `engine.h` gained embedding C API (v0.18.0 emphasizes embeddings — re-check headers at wire-up; if yes, route through the plugin instead); (c) only then consider a separate plugin dir with careful linkage.

## 4. Recommendation (decision needed from Main before any new dependency)

**Do NOT create `packages/ayumitra_embeddings_ios/` yet.** Linking is unverified and a premature separate plugin risks the exact conflict MSG-022 fears. Recommended path: Main adds SPM LiteRTLM (exact 0.18.0) to Runner + a narrow Swift bridge on channel `app.ayumitra/embeddings` (same `load`/`embed`/`close` contract as the Kotlin bridge), CPU default, and reports the link result here. I will document the outcome in this file. No iOS files touched by Sub.
