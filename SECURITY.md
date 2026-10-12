# Security reporting

Ayumitra is in early development. There are no stable releases with a promised
security support period yet. Report problems against the latest source and
include the revision you tested when available.

For a vulnerability, use GitHub's **Security → Report a vulnerability** on this
repository when private vulnerability reporting is enabled. Do not put exploit
details or private health data in a public issue. If the private reporting button
is unavailable, open a minimal public issue asking maintainers to enable private
reporting, without disclosing the vulnerability. No private reporting channel or
response deadline is promised until the repository configures one.

Useful reports include affected platforms and versions, reproducible steps with
synthetic records, expected and actual behavior, and the privacy or security
impact. Never send actual medical reports, account credentials, or model access
tokens. A fully synthetic demonstration is enough.

Relevant problems include unintended uploads, report or key exposure, unsafe
file handling, prompt injection that crosses tool permissions, incomplete export
redaction, and a dependency contacting a service unexpectedly. Ordinary bugs
and feature requests belong in the issue tracker, using synthetic data only.
