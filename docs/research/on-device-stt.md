# English on-device speech recognition for Ayumitra

Research checked on 2026-10-13. This is a benchmark and integration recommendation; no candidate was installed, downloaded, integrated, or measured on the Galaxy S24 Ultra. English is the v1 language. Audio and transcription stay on the device, with no cloud fallback. Wake-word work is outside this scope.

## Recommendation

Benchmark **Moonshine Voice Small Streaming English first**, then **Tiny Streaming English** for lower memory and energy use. Compare both with an **int8 streaming English Zipformer through sherpa-onnx** and **whisper.cpp base.en**. Include **whisper.cpp small.en** as a slower accuracy reference. If the lighter streaming models miss medicine names or quantities, benchmark **Nemotron Speech Streaming English 0.6B**, using its current sherpa-onnx export. Select the smallest candidate that passes the medical transcription and sustained-device gates below.

This ordering is an engineering judgment: Moonshine offers native mobile bindings and streaming updates, while sherpa-onnx offers a direct Flutter route. It is not a finding that Moonshine is the most accurate model for this user. A voice experience that feels fluid also needs stable partial text, endpointing, interruption handling, and quick response playback; WER alone cannot establish that experience.

## Candidates and deployment facts

### Moonshine Voice: primary streaming candidate

The current official English table lists **Tiny Streaming 34M**, **Small Streaming 123M**, and **Medium Streaming 245M** parameters, all **MIT**. The older non-streaming English Tiny is 26M and Base is 58M; those are different architectures. The reported average WER values for the streaming models are respectively **12.00%, 7.84%, and 6.65%**, measured on floating-point references across eight Open ASR datasets. These are publisher results, not quantized mobile or medical-dictation measurements. English currently defaults to Medium Streaming, so explicitly select Small or Tiny rather than relying on that default. [Official model table](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/)

The official quickstart provides an Android Java API, currently using `ai.moonshine:moonshine-voice:0.1.5`, and an iOS Swift package at `moonshine-ai/moonshine-swift`. Both expose incremental text and completed-line callbacks. Ayumitra would need a native platform-channel bridge or another separately validated Flutter binding. [Mobile quickstart](https://moonshine-voice.readthedocs.io/en/latest/quickstart/)

For storage planning, summing all nine files listed in each English `quantized_26_08_21` directory gives approximately:

| Variant | Published directory bytes | Decimal MB |
| --- | ---: | ---: |
| Tiny Streaming | 77,748,675 | 77.75 |
| Small Streaming | 224,067,582 | 224.07 |
| Medium Streaming | 415,954,967 | 415.95 |

These are calculations from the official asset manifest. Each directory includes both decoder variants; these totals are not necessarily the minimal application bundle, SDK binary size, or runtime RAM. Pin the SDK and exact asset catalog/checksums together. [Asset manifest](https://huggingface.co/moonshine-ai/moonshine-voice-assets/blob/main/FILES.tsv), [catalog and release-tag explanation](https://moonshine-voice.readthedocs.io/en/latest/models/huggingface/)

Current quantization separates the frontend compute graph from stored int8 frontend weights, reconstructing floating-point weights once at load. Disk savings therefore do not imply equally small working memory. [Quantization details](https://moonshine-voice.readthedocs.io/en/latest/models/quantization/)

Avoid the quickstart's automatic first-load fetching in the production transcription path. The documented low-level file/assets/memory loading paths can operate without networking; stage approved assets explicitly and verify airplane-mode operation. [Model-loading behavior](https://moonshine-voice.readthedocs.io/en/latest/using/downloading-models/)

### sherpa-onnx streaming English Zipformer: Flutter baseline

`sherpa_onnx` documents Flutter support for Android and iOS arm64. Its runtime is Apache-2.0, and the specific `csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26` model card also declares Apache-2.0. Check the exact selected model's license rather than applying the runtime license to every model. [Flutter platform support](https://pub.dev/packages/sherpa_onnx), [runtime repository](https://github.com/k2-fsa/sherpa-onnx), [specific model card](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26)

For that English checkpoint, the documented int8 inference combination uses a roughly **68M encoder file**, **2.0M float decoder file**, **254K int8 joiner file**, and tokens. Those are the documentation's rounded file-size labels, not RAM measurements. It is a genuinely online recognizer with microphone decoding and endpoint configuration. Its LibriSpeech training makes it a useful lightweight baseline; performance on conversational Indian English and medical names remains an open question. [English Zipformer files and online usage](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html#csukuangfj-sherpa-onnx-streaming-zipformer-en-2023-06-26-english)

### whisper.cpp: mature offline reference

Use English-only `tiny.en`, `base.en`, and `small.en`. The runtime documents iOS and Android support, CPU inference, integer quantization, Vulkan, and Apple Metal/Core ML paths. Its reference memory table lists tiny **75 MiB disk / ~273 MB memory**, base **142 MiB / ~388 MB**, and small **466 MiB / ~852 MB**. These are generic reference figures for the model sizes; backend, quantization, conversion, and mobile process overhead change the actual result. Code is MIT. [whisper.cpp runtime, platforms, and memory table](https://github.com/ggml-org/whisper.cpp)

Whisper is a useful accuracy comparison and finished-utterance option. Repeatedly decoding overlapping audio can produce partial text, but that does not provide the same cached streaming architecture as Moonshine or a streaming transducer. Benchmark the whole buffering policy, including duplicate words and boundary errors. OpenAI publishes Whisper code and weights under MIT. [Whisper repository and license](https://github.com/openai/whisper)

### NVIDIA: distinguish Parakeet TDT from Nemotron streaming

**Parakeet TDT 0.6B v3** is a 600M multilingual FastConformer-TDT model under **CC BY 4.0**, with punctuation and timestamps. It is an offline/batch-oriented reference; its model card also demonstrates buffered/chunked streaming with two-second chunks and two-second right context. That wrapper should not be confused with native cache-aware low-latency streaming. NVIDIA's documented NeMo deployment is Linux/GPU oriented and specifies at least **2GB RAM to load**, which is not a smartphone peak-memory estimate. [Parakeet v3 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)

**Nemotron Speech Streaming English 0.6B** uses cache-aware FastConformer-RNNT and supports **80, 160, 560, and 1120ms** chunks. The English checkpoint was updated in March 2026; its license is the **NVIDIA Open Model License**, distinct from Parakeet's CC BY license. NVIDIA also released multilingual Nemotron 3.5 in June 2026, but English-only is sufficient for this v1 shortlist. Chunk size is algorithmic context, not a measured end-to-end phone latency. [English streaming model card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)

sherpa-onnx now documents current English int8 exports dated **2026-04-25**, one for each chunk size, plus an Android arm64 streaming APK. Its example 560ms export has rounded file sizes **623M encoder + 6.9M decoder + 1.7M joiner** plus tokens. This is a concrete mobile evaluation route, not evidence that it meets Ayumitra's memory or battery budget. Try 160ms and 560ms separately. [sherpa-onnx Nemotron exports and Android example](https://k2-fsa.github.io/sherpa/onnx/nemo/nemotron-streaming.html)

NVIDIA also publishes the Apache-2.0 **NeMo-Speech.cpp** native C/C++ runtime, supporting these ASR models and CPU/Metal/Vulkan paths. Its official documentation is presently centered on desktop CLI/native SDK integration; an Ayumitra Android/iOS build, Flutter bridge, and phone measurements still need validation. Do not interpret desktop CPU or GPU vendor throughput as an S24 benchmark. [Official native runtime](https://github.com/NVIDIA/NeMo-Speech.cpp)

## Voice interaction design to evaluate

Use microphone frames, local resampling, local VAD, and a streaming recognizer. Show changing partial text in the composer while keeping final segments stable. Stop from an explicit user action or an endpoint detector; allow deliberate pauses and resumed speech. A practical first experiment is a 400–700ms silence hangover, compared against 300ms and 1000ms settings. Those are proposed tuning values, not verified defaults. Test the tradeoff between clipped turns and slow completion.

Measure VAD decisions separately from recognizer delay. Silence is not always the end of a thought: include pauses before medicine names, decimals, and self-corrections. Start with local energy/VAD plus recognizer endpointing; evaluate a separate local turn-end model only if that baseline cuts users off. Cancel capture immediately when the user cancels, changes profile, or leaves the screen. Discard stale callbacks, and require the user to review the completed draft before sending. Never convert partial speech directly into saved medical facts.

For spoken responses, measure answer generation and local TTS independently. Turn-taking and interruption controls matter even with excellent transcription. A shorter STT delay cannot compensate for slow first audio from the response pipeline. Keep all benchmark audio local; use synthetic fixtures or recordings from consenting evaluators, and keep model setup downloads separate from speech processing.

## Evaluation set

Create a versioned set of **600 human recordings**, with an additional **100 non-speech clips**. Use 20 speakers across Indian English regions, UK/US English, and other English accents represented by expected users; balance pitch, age, pace, and microphone distance. Hold out at least five speakers for final selection. Split utterances among short commands, 5–15s observations, and 30–60s dictation. Each reference should be checked by two humans, with an adjudicated transcript and explicit critical fields.

These are synthetic transcription fixtures, not treatment instructions:

| Category | Example spoken fixture | Required checks |
| --- | --- | --- |
| Decimals and units | “Hemoglobin twelve point seven grams per deciliter.” | `12.7`, hemoglobin, `g/dL`; never `127` |
| Dose and frequency | “Metformin five hundred milligrams, once daily.” | metformin, `500 mg`, once daily |
| Small quantities | “Levothyroxine twenty-five micrograms.” | medicine spelling, `25 µg`; never milligrams |
| Blood pressure | “One twenty over eighty; pulse seventy-two.” | `120/80`, `72`, field boundaries |
| Dates | “The report was from October thirteenth, twenty twenty-six.” | complete date `2026-10-13` |
| Negation | “I do not have chest pain.” | negation retained |
| Correction | “Fifteen milligrams—sorry, fifty milligrams.” | retain the correction in the transcript; no silent clinical rewrite |
| Similar drug names | human-read pairs such as hydroxyzine/hydralazine | substitutions reported separately |
| Spelling and abbreviations | “H B A one C was six point two percent.” | `HbA1c`, `6.2%` |
| Numbers in noise | “Temperature thirty-seven point eight degrees Celsius.” | `37.8 °C` |

Record quiet room, fan/traffic noise at approximately 20/10/5dB SNR, reverberant room, distant microphone, soft speech, and masks where relevant. Include silence, coughing, breathing, music, and unrelated background speech. Do not use TTS-only accuracy measurements: synthesized speech misses human pronunciation and hesitation patterns. Include natural regional pronunciations and brand/generic medicine names expected in India; a locally scoped vocabulary may be evaluated as a separate condition without borrowing another profile's data.

## Measurements and proposed release gates

The following are **initial engineering targets**, to be adjusted against measured usability and device budgets. They are not current results or a medical accuracy guarantee.

| Measure | Initial gate |
| --- | --- |
| WER = (substitutions + deletions + insertions) / reference words | ≤8% quiet; ≤15% moderate noise; report per accent and speaker, not just pooled average |
| Exact critical quantity + unit + date fields | ≥99% quiet and ≥97% moderate noise; report each error and denominator |
| Exact medicine-name accuracy | ≥98% quiet and ≥95% moderate noise; publish substitution confusion pairs |
| Negation and correction preservation | Zero missed-negation cases in the fixed critical suite; extend the suite after every failure |
| First useful partial | p95 ≤700ms from speech onset |
| Partial freshness | p95 ≤500ms behind the speech represented; report revision frequency and duplicated text |
| Final transcript delay | p95 ≤700ms from human-labelled speech end, including endpoint hangover |
| Endpoint behavior | Premature cutoffs <1% of turns; explicitly inspect pauses and final quiet words |
| Processing real-time factor | p95 ≤0.5 alone, ≤0.75 with the chosen Gemma4 and EmbeddingGemma2 resident; RTF = processing time / audio duration |
| STT memory | Prefer incremental peak PSS ≤750MB; review any candidate above 1.25GB rather than assuming it fits |
| 12GB device coexistence | Initial total app/model PSS target ≤7.5GB, accounting for native/GPU allocations separately; verify OS headroom, no low-memory kills, no model reload thrashing |
| Sustained operation | 20-minute real-time capture, <20% latency degradation, no severe thermal throttling or audio-frame loss |
| Energy | Initial incremental target ≤5 battery percentage points per 20 minutes over matched screen/microphone baseline; also record mWh where instrumentation permits |
| Silence/non-speech | Zero invented medical words on the fixed non-speech suite; log false positives separately |

Report raw and normalized WER. Normalization may equate “five hundred” and `500` for readability scoring, but never equate different quantities or units. Score medicine names and structured critical fields separately so a small overall WER cannot hide a dose error. Report confidence intervals and individual-speaker failures; a finite test set does not prove every future utterance is correct.

Run warm and cold starts, airplane mode, and 1/2/4-thread settings. Record exact phone SKU/SoC, OS, model revision, precision, chunk size, VAD settings, build mode, battery state, temperature, and microphone path. Compare STT alone, STT with Gemma4/EmbeddingGemma2 loaded but idle, and speech interruption during answer generation. Keep the chosen Gemma4 variant and context length explicit: 12GB physical RAM is not 12GB available to the app.

The next actionable step is a controlled local benchmark of Moonshine Small/Tiny Streaming against Zipformer int8 and Whisper base.en on the actual target device. A product model choice and any claim of a ChatGPT-like experience should follow those measurements.
