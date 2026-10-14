from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

import app as gateway

SECRET = 'synthetic-provider-key'
BODY = {'provider': 'openai', 'model': 'gpt-6-luna',
        'instruction': 'Approved instruction', 'input': 'Synthetic approved context'}
HEADERS = {'Authorization': f'Bearer {SECRET}'}


def result(content='Synthetic answer', reason='stop', tool_calls=None):
    return SimpleNamespace(choices=[SimpleNamespace(finish_reason=reason,
        message=SimpleNamespace(content=content, tool_calls=tool_calls))])


@pytest.fixture
def client(monkeypatch):
    completion = AsyncMock(return_value=result())
    monkeypatch.setattr(gateway.litellm, 'acompletion', completion)
    with TestClient(gateway.app) as client:
        yield client, completion


def test_real_adapter_contract_no_storage_tools_aliases_or_retries(client):
    client, completion = client
    response = client.post('/v1/generate', json=BODY, headers=HEADERS)
    assert response.status_code == 200
    assert response.json() == {'provider': 'openai', 'model': 'gpt-6-luna', 'content': 'Synthetic answer'}
    assert response.headers['cache-control'] == 'no-store'
    completion.assert_awaited_once_with(model='openai/gpt-6-luna', api_key=SECRET,
        messages=[{'role': 'system', 'content': BODY['instruction']},
                  {'role': 'user', 'content': BODY['input']}],
        stream=False, max_completion_tokens=4096, timeout=105, num_retries=0)


def test_anthropic_preserves_user_model_exactly(client):
    client, completion = client
    response = client.post('/v1/generate', json={**BODY, 'provider': 'anthropic', 'model': 'claude-haiku-5-5'}, headers=HEADERS)
    assert response.status_code == 200
    assert completion.await_args.kwargs['model'] == 'anthropic/claude-haiku-5-5'


@pytest.mark.parametrize('change', [
    {'provider': 'azure'}, {'provider': ['openai']}, {'model': 'openai/model'},
    {'model': ''}, {'model': 'https://evil.example'}, {'model': None},
    {'input': []}, {'instruction': ''}, {'api_base': 'https://evil.example'},
    {'tools': [{'type': 'function'}]},
])
def test_untrusted_overrides_or_bad_payload_never_call_provider(client, change):
    client, completion = client
    response = client.post('/v1/generate', json={**BODY, **change}, headers=HEADERS)
    assert response.status_code == 400
    completion.assert_not_called()


def test_key_required_each_time_not_retained(client):
    client, completion = client
    assert client.post('/v1/generate', json=BODY, headers=HEADERS).status_code == 200
    assert client.post('/v1/generate', json=BODY).status_code == 401
    completion.assert_awaited_once()


def test_body_limit_and_invalid_json(client):
    client, completion = client
    assert client.post('/v1/generate', content='x' * (gateway.MAX_REQUEST_BYTES + 1), headers={**HEADERS, 'content-type': 'application/json'}).status_code == 413
    assert client.post('/v1/generate', content='not json', headers={**HEADERS, 'content-type': 'application/json'}).status_code == 400
    completion.assert_not_called()


@pytest.mark.parametrize('answer', [result(reason='length'), result(content=''),
    result(content=None), result(tool_calls=[{'function': 'x'}]),
    result(content='x' * (gateway.MAX_RESPONSE_BYTES + 1))])
def test_invalid_incomplete_or_tool_output_is_rejected(client, answer):
    client, completion = client
    completion.return_value = answer
    response = client.post('/v1/generate', json=BODY, headers=HEADERS)
    assert response.status_code == 502
    assert 'content' not in response.json()


def test_errors_never_expose_keys_or_medical_payload(client, caplog):
    client, completion = client
    completion.side_effect = RuntimeError(f'{SECRET} {BODY["input"]}')
    response = client.post('/v1/generate', json=BODY, headers=HEADERS)
    assert response.status_code == 502
    assert SECRET not in response.text + caplog.text
    assert BODY['input'] not in response.text + caplog.text
    assert completion.await_count == 1


def test_telemetry_and_callbacks_disabled():
    assert gateway.litellm.telemetry is False
    assert gateway.litellm.set_verbose is False
    assert gateway.litellm.callbacks == []
    assert gateway.litellm.success_callback == []
    assert gateway.litellm.failure_callback == []
