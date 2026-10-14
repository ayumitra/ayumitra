# Frontier transport and optional developer gateway

## Normal Android/iOS setup: provider key only

The app now sends optional cloud chat **directly** to the selected provider.
There is no gateway URL, companion server, LiteLLM installation, or host setup
for a person using the phone app. The legacy Dart class name `FrontierGateway`
remains for compatibility; its mobile implementation is direct-provider HTTP.

- OpenAI: `POST https://api.openai.com/v1/responses`, default `gpt-6-luna`.
- Anthropic: `POST https://api.anthropic.com/v1/messages`, default
  `claude-haiku-5-5` (the API identifier for Claude Haiku 5.5).

The person supplies their own provider key in device secure storage, reads the
one-time cloud disclosure, and selects cloud chat. The disclosure acceptance and
model choice persist on the device. Local chat stays the default; selecting local
chat stops cloud dispatch. Merely saving a key, accepting the disclosure, or
preparing context sends nothing. The composer identifies the selected provider.
Do not bundle a shared developer key in an app or export user keys with records.

Cloud mode sends bounded context from the selected profile to that provider.
This includes relevant medical record text, dates, user-provided health details,
readings, and conversation context selected for the question. It exposes that
context to the provider and may incur charges. This is optional cloud inference;
a local vault does not make the provider request local. OpenAI requests use
`store: false`; provider retention and safety policies still apply.

The transport accepts only the exact official HTTPS endpoint for the selected
provider, refuses redirects, preserves the configured model identifier, and
never sends the key to another host or provider. OpenAI uses `Authorization:
Bearer …`; Anthropic uses `x-api-key` and `anthropic-version: 2023-06-01`.
Neither request enables tools, uploads source files, or changes sampling settings.
The Anthropic mobile request does not use a dangerous-direct-browser-access
header. The browser preview does not enable cloud inference.

Limits: 256 KiB request, 512 KiB response, 120-second deadline, and 4,096 output
tokens. Incomplete, empty, refused, mismatched-model, and tool-only replies are
rejected with generic errors that do not expose provider payloads or keys. A
provider may resolve a model alias to its own dated snapshot; another model or
family is not accepted. Reasoning content is excluded from returned answers and
conversation memory.

The controller runs the same planner, retrieval, privacy-filtered public web
search and bounded research workflow for local and cloud assistants. Cloud
planning, rewriting, research and drafting all use the selected provider, with
at most 32 assistant calls per task. Invalid answer formatting may use up to ten
answer attempts with the same selected provider/model and controlled guidance;
each role receives fresh owned profile metadata. It never echoes rejected output into the next request. The
one-time disclosure includes the possible additional charges. Provider/network
errors stop immediately; cloud failure never silently switches models.

The transport tests in `test/frontier_gateway_test.dart` use mocked HTTP only.
Those transport tests make no provider requests or paid calls. A separate
user-authorized synthetic device comparison is documented in
[the quality note](../docs/research/companion-quality-2026-10-14.md).

References: [OpenAI Responses text generation](https://developers.openai.com/api/docs/guides/text),
[Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create),
[Claude Haiku 5.5 model identifier](https://platform.claude.com/docs/en/models/haiku-5-5/overview).

## Optional developer experiment: LiteLLM

The Python files in this directory retain the earlier **developer-only** LiteLLM
experiment. They are not connected to mobile settings or needed by the app. The
mobile transport deliberately rejects this service's URL. Do not ask phone users
to run or configure it.

For isolated development with Python 3.10–3.14, from this directory:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8088 --no-access-log --log-level critical
```

The experimental `POST /v1/generate` takes a provider key in its Authorization
header and exactly four JSON strings: `provider`, `model`, `instruction`, `input`.
It calls the real LiteLLM SDK provider adapter without arbitrary API-base overrides,
tools, aliases, fallback or automatic retries. Telemetry, callbacks, and dependency
request logging are disabled. There is no application key or health-data storage.
Secrets exist transiently in process memory; no cryptographic erasure is promised.
Use only synthetic data while experimenting, bind loopback, and do not expose the
development server publicly. Deployment security and full transitive dependency
locking would need separate review before anyone relies on this service.

Direct dependencies were pinned against PyPI on 2026-10-14. The experimental tests
replace `litellm.acompletion` with an async mock and do not contact providers:

```sh
.venv/bin/pip install -r requirements-test.txt
.venv/bin/python -m pytest -q tests
```

Developer references: [LiteLLM completion inputs](https://docs.litellm.ai/docs/completion/input),
[LiteLLM retry controls](https://docs.litellm.ai/docs/completion/reliable_completions),
[LiteLLM release metadata](https://pypi.org/project/litellm/1.105.1/).
