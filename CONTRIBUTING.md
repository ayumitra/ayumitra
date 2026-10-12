# Contributing to Ayumitra

Ayumitra is a community project to make a private medical companion available
to everyone. Contributions to code, documentation, accessibility, report
processing, and testing are welcome. The first version supports English input
and output on Android and iOS, with Samsung S24 Ultra as the first Android target.

## Project principles

- Reports, embeddings, extraction, summaries, and conversation inference stay
  on the device. There is no cloud inference fallback.
- The assistant may use internet search for general information. Queries must
  exclude personal identifiers and private report content; web search is not
  a way to process medical records remotely.
- Preserve original evidence and distinguish recorded facts, uncertain
  extraction, and model interpretation. Medical claims should link to their
  source, and conflicting readings should be visible.
- Use open-source code dependencies where possible and disclose native SDK
  and model licenses separately. See [the dependency review](docs/dependencies.md).

## Ways to help

Start with a small issue or pull request: improve wording, add an accessibility
fix, reproduce a device bug, or contribute a synthetic report that exercises an
extraction failure. Larger architecture changes benefit from an issue describing
the problem and proposed behavior first. Please keep discussion kind and specific.

Use **invented, synthetic data only** in issues, screenshots, fixtures, and pull
requests. Do not upload real medical records, including records with names merely
covered visually: underlying text and metadata can still reveal identities.
Use [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Development

Install Flutter **3.44.1** and the tools required for your Android or iOS target.
Clone the repository, then run:

```sh
flutter pub get --enforce-lockfile
dart format lib test
flutter analyze
flutter test
```

Use the checked-in lockfile. Include deliberate dependency changes and explain
their license, network behavior, and mobile support. The CI workflow checks
formatting, analysis, and tests; these checks do not establish clinical accuracy
or prove that a native dependency makes no network requests.

For on-device changes, describe the phone, OS, model artifact and version, and
whether testing succeeded with airplane mode enabled after setup. Add meaningful
regression coverage for behavior changes, especially privacy boundaries,
extraction provenance, medication timing, and retrieval. Documentation-only
changes do not need new tests.

## Pull requests

Explain the problem, the resulting user experience, and how you checked it. Keep
changes focused and flag unfinished work. Do not include credentials, downloaded
model weights, or generated private data. Reuse the pull request template.

Unless explicitly stated otherwise, intentional contributions to this project
are submitted under its [Apache-2.0 license](LICENSE). Third-party material must
keep its own license and attribution; only contribute material you may share.
