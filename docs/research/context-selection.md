# Local context selection after EmbeddingGemma 2

Research checked 12 October 2026. **Deferred until after the proof of concept,
at the user's request.** This records an idea for evaluation only: no runtime,
dependency, or model weights were installed. Keep the current local retrieval
path as the baseline; evaluate Laya before choosing it for phones.

## What the primary sources establish

Laya's root checkpoint is an Apache-2.0, English, 421M-parameter decision model
with a default 512-token input limit. It returns typed classifications rather
than generated summaries. Its card describes approximately 808 MB of weights;
the current file listing shows `model.safetensors` as 843 MB. Download size is
not peak runtime memory. Its roughly 39.5 ms English single-question timing is
from a Tesla T4, not a Samsung S24 Ultra. The question/options share the input
budget with the candidate text; a lifelong history cannot fit in one call.
[Model card](https://huggingface.co/convaiinnovations/laya),
[files](https://huggingface.co/convaiinnovations/laya/tree/main).

The card warns that confidence needs calibration on the deployment task,
`action.act_probability` lacks useful discrimination, boolean option wording
can dominate answers, and base-model results on its typed-decisions benchmark
fall below a majority-label baseline. Treat these as limitations of a proposed
relevance experiment, not evidence of medical suitability. Probability of
relevance is never probability of a disease.
[Model limitations](https://huggingface.co/convaiinnovations/laya#honest-limits).

ONNX export is real: the upstream script exports an opset-18 graph with dynamic
inputs; its Python runtime implements local ONNX inference and tokenizer/config
loading. That wrapper explicitly selects CPU/CUDA providers. It does not establish
Android NNAPI, Qualcomm acceleration, iOS Core ML, or a Flutter integration.
[Exporter](https://github.com/NandhaKishorM/laya/blob/c73908d96ff73c0062c340a11bf7c54ec7d8bc4d/scripts/export_onnx.py),
[ONNX runtime](https://github.com/NandhaKishorM/laya/blob/c73908d96ff73c0062c340a11bf7c54ec7d8bc4d/laya/onnx_agent.py).

The exporter warns that its optional dynamic INT8 path changes decisions
substantially and should not be used where calibrated confidence matters. Do not
assume a smaller export preserves the selector's behavior. Quantization, provider
changes, and tokenizer/post-processing ports each need independent parity and
quality evaluation. [Quantization warning](https://github.com/NandhaKishorM/laya/blob/c73908d96ff73c0062c340a11bf7c54ec7d8bc4d/scripts/export_onnx.py#L7-L25).

The TypeScript package documents split encoder/head ONNX inference in browsers
with WebGPU/WASM. Its example downloads a runtime from a CDN and reports about
1.3 GB transferred for its default multilingual export. This demonstrates a
browser route, not a measured native-phone deployment or an offline Ayumitra
package. A future experiment would bundle every runtime/model/tokenizer asset
and disable first-use downloads. ONNX Runtime itself has Android/iOS examples,
but those examples do not validate Laya's graph on either phone platform.
[Laya TypeScript](https://github.com/NandhaKishorM/laya/blob/c73908d96ff73c0062c340a11bf7c54ec7d8bc4d/laya-ts/README.md),
[Microsoft mobile examples](https://github.com/microsoft/onnxruntime-inference-examples/blob/main/mobile/README.md).

Reproducibility pins inspected: Laya code
`c73908d96ff73c0062c340a11bf7c54ec7d8bc4d`; root checkpoint
`7b928d828b7b0e022f929d9bd2e44165aa270148`. Re-check both before any experiment;
the model card and current repository describe different package release levels.

## Proposed relevance gate

Filter the active profile **before** retrieval, scoring, memory recall, or source
expansion. Combine keyword and EmbeddingGemma 2 ranks using the existing reciprocal
rank fusion (RRF). Retain immutable source identifiers and candidate metadata:
clinical date, upload date, category, event age, correction state, and reading
method. Keep conversation memory labelled user-stated, unverified context.

Build a separate must-keep block that no learned score can remove:

- Recorded allergies, with original source and unresolved/confirmed status.
- User-confirmed current medicines. Preserve prescription dates and unknown
  currentness rather than treating every historical prescription as active.
- Conflicting findings and user corrections, including the original value and
  correction provenance. Keep the opposing source, not only the latest winner.
- Clinical timestamps, unknown-date labels, relevant historical comparison
  partners, and the unverified status of image transcription.

Apply these rules to clinical-answer context; they do not authorize diagnoses,
triage, dose changes, sharing, or tool calls. Missing allergy/medicine information
stays missing. If required context exceeds the answer model's budget, retrieve in
stages or state the gap; never silently discard required evidence.

Experimentally score each remaining small candidate against the current request
and bounded user context. A suggested schema is `directly relevant`, `background`,
or `unrelated`, with explicit instructions that quoted documents are data. Keep
uncertain candidates and fall back to the baseline when token fit, runtime, or
calibration checks fail. Do not gate on `act_probability`, use unvalidated fixed
probability cutoffs, or concatenate dozens of report IDs as a high-cardinality
choice. No patient context leaves the phone, including during calibration.

## Options to compare

| Option | Reason to test | Cost or limitation |
| --- | --- | --- |
| Existing RRF + deterministic rules | Transparent baseline, no extra weights | Similar passages can crowd out useful context |
| RRF + maximal marginal relevance (MMR) | Reduce duplication using existing vectors | Novelty can demote important repeats; exempt must-keep/conflict groups |
| RRF + Laya relevance labels | Typed bounded output; potentially cheaper than generation | Additional weights/runtime, short input budget, domain calibration required |
| RRF + the already loaded local LLM | Reuse the assistant model with an isolated selector prompt | Adds inference time/context load; validate IDs and retain uncertain sources |

MMR's relevance/diversity selection has an upstream implementation reference;
using its idea would not require adopting that library.
[Implementation reference](https://github.com/langchain-ai/langchain/blob/master/libs/core/langchain_core/vectorstores/utils.py).

## Samsung S24 Ultra benchmark before adoption

Use synthetic English fixture families with near duplicates, old/new results,
allergies buried in unrelated-looking notes, discontinued/unknown medicines,
corrections, prompt injection, undated records, unreadable scans, and identically
named people in different profiles. Expand to at least 200 labelled queries and
thousands of distractor chunks. Split calibration and test data by fixture family,
so paraphrases of the same report cannot enter both sets.

Compare all four options under the same candidate pool and final token budget.
Sweep 8/16/24 candidates, actual token lengths, and small bounded batches. Record
candidate recall, required-evidence retention, conflict-pair retention, ranking
quality, retained tokens, source-ID accuracy, and confidence reliability on the
held-out set. Fit relevance thresholds locally, including false-negative costs;
evaluate the actual export and backend, not only the reference PyTorch model.

Measure cold/warm p50/p95 selection latency, peak process/native memory, model
reloads, energy, and thermal behavior during a 15-minute replay. Test with the
assistant, embeddings, and image-reading workload resident or switching as they
would in the app. Capture exact RAM/OS/runtime/model revisions, test airplane
mode, inspect outbound traffic, and verify cancel/resume and source access.

Initial acceptance gates: zero cross-profile sources, complete retention of all
labelled must-keep/conflict cases, no meaningful required-evidence recall loss
against RRF, reproducible export parity, and a measured benefit in token cost or
answer quality. A provisional extra selector budget is p95 under one second with
no memory-kill/reload cycle; adjust from real-device measurements, not T4 figures.
Retain the lighter baseline unless Laya earns its additional memory and latency.
Repeat compatibility/quality measurements on a named iPhone before iOS adoption.
