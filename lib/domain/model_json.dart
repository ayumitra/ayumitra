/// Shared model-output JSON hygiene for strict local validators.
///
/// Removes one wrapping Markdown code fence and surrounding whitespace only:
/// a single leading ```json/```JSON/``` fence and a single trailing ```
/// fence. Anything else passes through byte-identical, so strict downstream
/// validators still reject malformed content. No content is inferred,
/// repaired, or interpreted here.
String unfenceJson(String text) => text
    .trim()
    .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
    .replaceFirst(RegExp(r'\s*```$'), '');
