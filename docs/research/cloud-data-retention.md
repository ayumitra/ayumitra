# Cloud data retention: controls and honest product guarantees

Verified against official documentation on **2026-10-14**. This is a research
note and implementation recommendation, not confirmation of any person's API
account configuration. No keys, account settings, or medical records were read.

## Decision

Keep the lifelong record, profile selection, memory and retrieval on the device,
with no Ayumitra account or central patient database. Optional provider inference
must be described separately: **a provider key alone does not establish Zero Data
Retention (ZDR)**. Honor eligible provider arrangements without claiming the app
can activate or independently guarantee them.

Suggested product wording:

> Your health history lives on this device. Ayumitra does not require an account
> or keep a central copy. If you choose a cloud model, relevant context is sent
> directly to that provider using your key. We request supported non-storage
> controls; the provider's account agreement, model and feature policies determine
> retention. Cloud inference can incur charges.

This is a proposed guarantee to validate against the finished app and deployment.
“Not used for training,” “not saved as a response,” and “no retained customer
content” describe different controls.

## OpenAI: `store: false` is necessary, not a ZDR switch

The default API policy excludes customer data from training unless the customer
opts in. Abuse-monitoring logs can contain prompts/responses and normally persist
up to 30 days, with longer retention exceptions. ZDR or Modified Abuse Monitoring
requires OpenAI approval and organization/project configuration. Responses
(`/v1/responses`) is ZDR-eligible subject to documented limitations; stored
conversations, files and vector stores have different rules. A foreground
Responses call with `store: false` avoids normal response application-state
storage; it does not itself remove abuse logs. ZDR enforces `store: false`.
[OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)

Caching is a separate qualification. Official guidance describes encrypted
key/value tensors in GPU-local storage. For GPT-5.6 and later, including the
selected GPT-6 family, `prompt_cache_options.ttl` specifies a **minimum**, with
`30m` the documented value, rather than a deletion deadline. Earlier models have
different `in_memory`/`24h` controls. Do not invent a cache-disable parameter or
promise that `store: false` means no transient artifacts.
[OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)

OpenAI documents organization and project retention administration. The
organization retrieval example uses an **Admin API key**, not an ordinary model
key. Ayumitra should not request a privileged administrator key merely to label
someone's personal cloud setting as verified. Organization settings alone also
need to be interpreted alongside project overrides and feature/model conditions.
[Organization retention API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/data_retention/methods/retrieve),
[project controls](https://developers.openai.com/api/docs/guides/terraform/project-controls)

## Anthropic: eligible Messages calls plus an organization arrangement

ZDR is enabled separately for each organization through Anthropic's account team.
Under that arrangement, prompts/responses are not stored at rest after returning
the response, subject to exceptions. Standard Messages (`/v1/messages`) and Token
Counting are eligible; eligibility depends on the model and features. Some
stateful features are excluded, and the API does **not** generally block a ZDR
customer from selecting an excluded feature. The provider advises confirming the
arrangement through the contract or account representative. Flagged content and
legal requirements can override retention, including up to two years for flagged
inputs/outputs. A model's display name or successful request is not ZDR evidence.
[Anthropic API retention and feature eligibility](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)

Without a special arrangement, Anthropic's commercial policy generally deletes
API inputs/outputs within 30 days, with feature, policy-enforcement and legal
exceptions. This differs from a ZDR arrangement and from consumer Claude plans.
[Anthropic commercial retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)

The documented Messages request does not offer a universal per-request
`zero_retention: true` control. Normal headers such as `anthropic-version` do not
activate an organization's contractual retention policy.
[Messages API contract](https://platform.claude.com/docs/en/api/messages/create)

## What the mobile client can enforce

Recommended controls, distinct from provider-side retention guarantees:

- Keep local mode available without app sign-in or cloud credentials. Save the
  one-time cloud disclosure and mode choice locally; identify the active provider.
- Restrict keys to the selected provider's exact official HTTPS endpoint; refuse
  redirects. Avoid embedding shared keys, request-body logs, telemetry containing
  health data, and source text in diagnostic errors.
- Use foreground text Responses with `store: false` and stateless Anthropic
  Messages. Do not add provider files, hosted memory, batches, containers or
  server-side conversation resources merely to reproduce features already local.
- Continue running retrieval and tools through the same locally controlled agent.
  Minimize profile context sent for each step. A tool result sent back to a cloud
  model is another disclosure; public search services have their own policies.
- Never retry a retention/model eligibility rejection with a storing feature,
  another account or another provider. Preserve the local record and surface a
  plain error instead. A local “ZDR confirmed by account owner” setting would be
  self-attestation, not technical verification.

These controls can be tested in the client. Physical provider deletion, legal
exceptions and another organization's contractual configuration cannot be proven
by inspecting an ordinary successful generation response. Avoid labels such as
“zero retention guaranteed,” “HIPAA compliant,” or “fully local” for cloud mode.

## Future medical knowledge banks

Prefer public, licensed, versioned knowledge packs downloaded for local indexing,
with provenance and update dates. Keep personal longitudinal memory separate from
shared medical knowledge. An online knowledge service should receive a minimal
public query, not a profile export; treat each service as a separate data recipient.
A knowledge-bank integration or self-hosted proxy does not change the upstream
model provider's retention agreement. This is an architecture recommendation,
not a claim that a knowledge-bank integration already exists.
