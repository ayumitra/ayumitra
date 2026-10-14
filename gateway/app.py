"""Opt-in text-only LiteLLM gateway. No storage, tools, uploads, or fallback."""

import asyncio
import json
import logging
import os
import re

# Configure before importing LiteLLM. Do not register external callbacks.
os.environ['LITELLM_TELEMETRY'] = 'False'
os.environ['LITELLM_LOG'] = 'ERROR'
os.environ['LITELLM_LOCAL_MODEL_COST_MAP'] = 'True'
import litellm  # noqa: E402
from fastapi import FastAPI, Request  # noqa: E402
from fastapi.responses import JSONResponse  # noqa: E402

litellm.telemetry = False
litellm.set_verbose = False
litellm.turn_off_message_logging = True
litellm.suppress_debug_info = True
litellm.callbacks = []
litellm.success_callback = []
litellm.failure_callback = []
litellm.input_callback = []
# Dependency exception/debug logs may include request bodies or credentials.
for _logger in ('LiteLLM', 'LiteLLM Router', 'LiteLLM Proxy', 'httpx', 'httpcore',
                'openai', 'anthropic'):
    logging.getLogger(_logger).disabled = True

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
MAX_REQUEST_BYTES = 256 * 1024
MAX_RESPONSE_BYTES = 512 * 1024
TIMEOUT_SECONDS = 110
MODEL_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$')


def failure(status: int, message: str) -> JSONResponse:
    return JSONResponse({'error': message}, status_code=status,
                        headers={'Cache-Control': 'no-store'})


@app.get('/health')
async def health():
    return JSONResponse({'status': 'ok'}, headers={'Cache-Control': 'no-store'})


@app.post('/v1/generate')
async def generate(request: Request):
    authorization = request.headers.get('authorization', '')
    if not authorization.startswith('Bearer '):
        return failure(401, 'A provider key is required.')
    api_key = authorization[7:]
    if not api_key or len(api_key) > 4096 or any(c.isspace() for c in api_key):
        return failure(401, 'A provider key is required.')
    if request.headers.get('content-type', '').split(';')[0].lower() != 'application/json':
        return failure(415, 'JSON is required.')
    # Stream before JSON decoding so even chunked requests have a firm bound.
    body = bytearray()
    try:
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > MAX_REQUEST_BYTES:
                return failure(413, 'Approved context is too large.')
        data = json.loads(body)
    except Exception:
        return failure(400, 'Invalid request.')
    if not isinstance(data, dict) or set(data) != {'provider', 'model', 'instruction', 'input'}:
        return failure(400, 'Invalid request.')
    provider, model = data['provider'], data['model']
    if provider not in ('openai', 'anthropic') or not isinstance(model, str) or not MODEL_ID.fullmatch(model):
        return failure(400, 'Invalid provider or model.')
    if any(not isinstance(data[field], str) or not data[field].strip()
           for field in ('instruction', 'input')):
        return failure(400, 'Approved text is required.')
    try:
        # Prefix chooses the real LiteLLM provider adapter; model is preserved
        # exactly. No API-base override, automatic retries, fallback, or tools.
        response = await asyncio.wait_for(litellm.acompletion(
            model=f'{provider}/{model}',
            api_key=api_key,
            messages=[{'role': 'system', 'content': data['instruction']},
                      {'role': 'user', 'content': data['input']}],
            stream=False,
            max_completion_tokens=4096,
            timeout=TIMEOUT_SECONDS - 5,
            num_retries=0,
        ), timeout=TIMEOUT_SECONDS)
        choices = response.choices
        if len(choices) != 1 or choices[0].finish_reason != 'stop':
            return failure(502, 'The provider returned an incomplete answer.')
        message = choices[0].message
        content = message.content
        if getattr(message, 'tool_calls', None) or not isinstance(content, str) or not content.strip():
            return failure(502, 'The provider returned an invalid answer.')
        payload = {'provider': provider, 'model': model, 'content': content.strip()}
        if len(json.dumps(payload, ensure_ascii=False).encode('utf-8')) > MAX_RESPONSE_BYTES:
            return failure(502, 'The provider answer exceeded the response limit.')
        return JSONResponse(payload, headers={'Cache-Control': 'no-store'})
    except Exception:
        # Never return repr(exception): SDK exceptions can embed key or records.
        return failure(502, 'The provider request failed. Check the key and exact model id.')
