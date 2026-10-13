/// Transcribes readable Markdown rows without imposing a clinical fact schema.
/// Tables, headings, indentation and literal JSON-looking source text remain
/// text. Repairs only enforce local row/length bounds; they never reinterpret
/// evidence or echo a rejected response back to the model.
Future<List<String>> generateValidatedTranscript(
  Future<String> Function(String repairHint) generate,
) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    final raw = await generate(
      attempt == 0
          ? ''
          : 'The previous transcription exceeded local size limits and was discarded. '
                'Return only readable Markdown transcription with at most 300 nonblank '
                'rows and 2000 characters per row. Preserve exact visible text, tables '
                'and headings. No commentary, diagnoses or invented text; mark unreadable '
                'parts [unreadable].',
    );
    try {
      var rows = raw
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');
      final first = rows.indexWhere((row) => row.trim().isNotEmpty);
      final last = rows.lastIndexWhere((row) => row.trim().isNotEmpty);
      if (first >= 0 &&
          last > first &&
          RegExp(
            r'^```(?:markdown|md)?[ \t]*$',
            caseSensitive: false,
          ).hasMatch(rows[first].trim()) &&
          rows[last].trim() == '```') {
        // Remove only one complete wrapping Markdown fence. Nested fences and
        // literal JSON code blocks are retained as visible source text.
        rows = rows.sublist(first + 1, last);
      }
      final lines = rows.where((row) => row.trim().isNotEmpty).toList();
      if (lines.length > 300 || lines.any((line) => line.length > 2000)) {
        throw const FormatException('Invalid transcript.');
      }
      return lines;
    } on FormatException {
      /* Never echo rejected text or relax source quality. */
    }
  }
  throw const FormatException('Invalid local transcript after three attempts.');
}
