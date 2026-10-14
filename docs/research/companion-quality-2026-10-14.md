# Synthetic S24 companion comparison — 2026-10-14

The person authorized a live comparison using their saved OpenAI key. Only a dedicated synthetic profile, fixed synthetic TXT report and fixed fictional history were sent. No personal profile or original attachment was sent. The app called OpenAI directly; no LiteLLM gateway was needed. Saved Brave credentials and local model availability were confirmed separately without exposing keys.

Models: on-device Gemma 4 E2B and EmbeddingGemma 2; optional GPT-6 Luna (`gpt-6-luna`). Both used the production controller, report retrieval and citation handling. These are end-to-end app timings, not token-throughput benchmarks: local questions also use local planning, while this cloud path receives prepared context directly. Two examples cannot establish clinical accuracy or general performance.

| Task | Gemma 4 | GPT-6 Luna |
| --- | --- | --- |
| Find the March 14 hemoglobin result | 7.528 s; exact 11.2 g/dL and correct report source | 4.380 s; exact 11.2 g/dL and correct report source |
| Draft a health report from report + user history | 11.386 s; preserved cited report values but incorrectly described 11.2 as within the supplied 11.5–15.5 interval, and duplicated temperature as a pulse entry | 5.937 s; correctly described that relation and kept user-reported pulse and temperature separate with their dates |

Both answers rendered as ordinary Markdown after the formatting fix. The local draft's citations were valid despite its semantic errors: citation validation alone cannot establish correct interpretation. Local drafting needs further measurement-label/unit and numerical-reasoning evaluation. Do not describe the local model as clinically validated. The original records and user history retained their correct values; generated drafts did not rewrite them.

Follow-up changes require source names, values, units and dates to stay together, omit unavailable fields, and quote reference ranges without adding a normal/high/low classification unless the source explicitly provides that flag. A local-only recheck used no further provider calls. The exact result remained correct (14.352 s); the summary (10.626 s) kept pulse 72 bpm separate from temperature 37.0 °C and quoted the report ranges without the incorrect normal-status interpretation. It still omitted the observations’ individual dates and printed an unavailable age field, so the prompt change improved these examples without establishing reliable temporal reasoning.

The bounded debug harness is `checks/android_quality_compare.dart`. It displays a noninteractive screen during tests to prevent real user statements entering the synthetic context, checks ownership before each request, makes at most four cloud requests, restores prior selection and in-memory public-search configuration, and saves only the fixed synthetic answers in a private diagnostic artifact. Debug artifacts are not committed. The model stays explicitly selectable; cloud consent is remembered once, with no automatic fallback.

These recorded timings predate the shared planner/tool refactor later on October 14. Cloud now runs planning, public-query rewriting and extended research through the selected provider too. The older timing comparison cannot predict the latency or cost of that workflow. Its four-call cap describes the original harness run, not the current production task budget (32 assistant calls). A new device check is required after the refactor.
