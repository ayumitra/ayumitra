import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../app_controller.dart';
import '../domain/records.dart';
import '../domain/retrieval.dart';

/// An in-memory UX rehearsal. It never reads files, loads models, or searches
/// the web. Scripted responses are always identified as preview examples.
class DemoController extends AppController {
  int _nextProfile = 0;
  final Map<String, Uint8List> _originals = {};

  @override
  bool get isPreview => true;

  @override
  Future<void> initialize() async {
    data = const VaultData();
    activeProfileId = null;
    messages.clear();
    _originals.clear();
    failure = null;
    loaded = true;
    notifyListeners();
  }

  @override
  Future<void> createProfile(
    String name,
    int age,
    String history,
    bool isChild,
  ) async {
    if (name.trim().isEmpty || age < 0 || age > 125) return;
    final next = Profile(
      id: 'preview-profile-${++_nextProfile}',
      name: name.trim(),
      age: age,
      ageRecordedAt: DateTime.now(),
      history: history.trim(),
      isChild: isChild,
    );
    data = data.copy(profiles: [...data.profiles, next]);
    activeProfileId = next.id;
    messages.clear();
    notifyListeners();
  }

  @override
  Future<void> attachReport() async {
    final owner = profile;
    if (owner == null || busy) return;
    final fixtures = _fixtures(owner.id);
    final next = fixtures
        .where((r) => !data.reports.any((existing) => existing.id == r.id))
        .firstOrNull;
    if (next == null) {
      messages.add(
        const ChatEntry(
          '**UX preview · scripted response**\n\nAll four synthetic examples '
          'are already in your history. Try asking about hemoglobin, medicines, '
          'or the undated note.',
        ),
      );
    } else {
      _add(next);
      messages.add(
        ChatEntry(
          '**UX preview · scripted response**\n\nAdded **${next.name}** to '
          'your in-memory history. Open History to inspect its summary, '
          'source text, category, and estimated age. No file was uploaded.',
          hits: [EvidenceHit(next, next.lines.first, 1)],
        ),
      );
    }
    notifyListeners();
  }

  void _add(Report report) {
    data = data.copy(reports: [...data.reports, report]);
    _originals[report.id] = Uint8List.fromList(
      utf8.encode(report.lines.map((line) => line.text).join('\n')),
    );
  }

  @override
  Future<void> importSample(Uint8List bytes) async {
    final owner = profile;
    if (owner == null || busy) return;
    var count = 0;
    for (final report in _fixtures(owner.id)) {
      if (!data.reports.any((existing) => existing.id == report.id)) {
        _add(report);
        count++;
      }
    }
    messages.add(
      ChatEntry(
        '**UX preview · scripted response**\n\n'
        '${count == 0 ? 'The examples are already available' : 'Added $count synthetic examples'}'
        '. Try “Compare my hemoglobin results”, “Find my medicines”, or '
        '“Summarize my medical history”. Everything resets when this page reloads.',
      ),
    );
    notifyListeners();
  }

  // Defense in depth: even accidental calls from a native UI path cannot read
  // a personal file or invoke a platform plugin in this preview.
  @override
  Future<void> importFile(PlatformFile file) => attachReport();

  @override
  Future<void> capturePhoto() => attachReport();

  @override
  Future<void> installModel(
    PlatformFile file, {
    required bool embedding,
    String family = 'gemma4',
  }) async => _unavailable('Model setup belongs to the mobile app.');

  @override
  Future<void> setWebKey(String value) async =>
      _unavailable('Web search is disabled in this preview. No key is saved.');

  void _unavailable(String message) {
    failure = message;
    notifyListeners();
  }

  @override
  Future<Uint8List> original(Report report) async {
    if (report.profileId != profile?.id || !_originals.containsKey(report.id)) {
      throw StateError('This synthetic source is not in the active profile.');
    }
    return Uint8List.fromList(_originals[report.id]!);
  }

  @override
  Future<void> retry(Report report) async {
    if (report.profileId != profile?.id) return;
    data = data.copy(
      reports: data.reports.map((current) {
        if (current.id != report.id) return current;
        return current.copy(
          summaryMarkdown: _summary(current),
          notice:
              'Synthetic preview: this summary is scripted, not AI generated.',
        );
      }).toList(),
    );
    notifyListeners();
  }

  @override
  Future<void> correctFact(
    Report report,
    MedicalFact fact,
    String replacement,
  ) async {
    if (report.profileId != profile?.id || replacement.trim().isEmpty) return;
    data = data.copy(
      reports: data.reports.map((current) {
        if (current.id != report.id) return current;
        return current.copy(
          facts: current.facts
              .map(
                (item) => item.id == fact.id
                    ? item.withValue(replacement.trim())
                    : item,
              )
              .toList(),
          clearSummary: true,
          notice:
              'Preview correction recorded in memory. Reprocess to refresh '
              'the scripted summary; the synthetic original stays unchanged.',
        );
      }).toList(),
    );
    notifyListeners();
  }

  @override
  Future<void> ask(String question) async {
    if (question.trim().isEmpty || profile == null || busy) return;
    failure = null;
    messages.add(ChatEntry(question.trim(), isUser: true));
    final text = question.toLowerCase();
    if (_isAttachmentCommand(text)) {
      await attachReport();
      return;
    }
    final followUp = RegExp(
      r'\b(it|them|those|that|again|compare|previous|earlier)\b',
    ).hasMatch(text);
    final previous = messages.where((m) => m.isUser).toList();
    // An explicit topic in the new request wins. Only references without a
    // topic inherit the latest relevant user request; assistant text is never
    // used to decide the scope of a follow-up.
    var scope = _scopeFor(text);
    if (scope == null && followUp) {
      for (final request in previous.reversed.skip(1).take(6)) {
        if (_isAttachmentCommand(request.text.toLowerCase())) continue;
        scope = _scopeFor(request.text.toLowerCase());
        if (scope != null) break;
      }
    }
    final medicine = scope == 'medicine';
    final blood = scope == 'blood';
    final undated = scope == 'undated';
    final selected = reports
        .where(
          (report) => medicine
              ? report.type == 'prescription'
              : blood
              ? report.type == 'lab'
              : undated
              ? report.eventDate == null
              : true,
        )
        .toList();
    final hits = <EvidenceHit>[];
    final content = StringBuffer('**UX preview · scripted response**\n\n');
    if (selected.isEmpty) {
      content.write(
        'There are no matching synthetic reports yet. Use the '
        'attachment button to add an example, or “Try a synthetic example” '
        'to explore the full sample history. This preview does not interpret '
        'your question with an LLM.',
      );
    } else {
      content.writeln(
        '## ${medicine
            ? 'Medicines in the sample history'
            : blood
            ? 'Sample blood results'
            : 'Sample history'}\n',
      );
      content.writeln('| Name | Value | Unit | Printed range | Source |');
      content.writeln('| --- | --- | --- | --- | --- |');
      for (final report in selected) {
        for (final fact in report.facts) {
          final line = report.lines.firstWhere(
            (line) => line.id == fact.sourceLineId,
          );
          hits.add(EvidenceHit(report, line, 1));
          content.writeln(
            '| ${fact.name} | ${fact.value}${fact.corrected ? ' (user corrected)' : ''} | '
            '${fact.unit.isEmpty ? '—' : fact.unit} | '
            '${fact.range.isEmpty ? 'Not printed' : fact.range} | '
            '[${report.id}/${line.id}] |',
          );
        }
      }
      content.writeln('\n## Reports used\n');
      for (final report in selected) {
        final dateLine = report.lines.firstWhere((line) => line.id == 'p1l3');
        hits.add(EvidenceHit(report, dateLine, 1));
        content.writeln(
          '- **${report.name}** · ${_date(report.eventDate)} · '
          '${ageAtEvent(profile!, report.eventDate)} · ${report.type} '
          '[${report.id}/${dateLine.id}]',
        );
      }
      content.writeln('\n## Open questions\n');
      content.write(
        'Check the original source using the links below. '
        'Age labels are estimates from the age recorded at onboarding.',
      );
      if (medicine || RegExp(r'web|search|explain|used for').hasMatch(text)) {
        content.write(
          '\n\nThe mobile assistant can choose public web search '
          'for general medicine information. This UX preview makes no web '
          'search or AI calls and does not offer medical advice.',
        );
      }
    }
    messages.add(ChatEntry(content.toString(), hits: hits));
    notifyListeners();
  }

  bool _isAttachmentCommand(String text) => RegExp(
    r'^\s*(?:please\s+|can you\s+)?(?:add|attach|import|upload|scan)\b.*\breports?\b',
  ).hasMatch(text);

  String? _scopeFor(String text) {
    if (RegExp(r'medicine|prescription|amoxicillin').hasMatch(text)) {
      return 'medicine';
    }
    if (RegExp(r'blood|hemoglobin|haemoglobin|white').hasMatch(text)) {
      return 'blood';
    }
    if (RegExp(r'undated|unknown|allerg').hasMatch(text)) return 'undated';
    return null;
  }

  List<Report> _fixtures(String ownerId) {
    final now = DateTime.now();
    final currentDate = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 11));
    final olderDate = currentDate.subtract(const Duration(days: 740));
    final prescriptionDate = currentDate.subtract(const Duration(days: 23));
    final prefix = '$ownerId-report';
    return [
      _report(
        '$prefix-blood-recent',
        ownerId,
        'Synthetic blood report',
        'lab',
        currentDate,
        [
          ('lab', 'Hemoglobin', '11.2', 'g/dL', '10.0–14.0'),
          ('lab', 'White blood cells', '7.4', '10^9/L', '4.0–12.0'),
        ],
      ),
      _report(
        '$prefix-medicine',
        ownerId,
        'Synthetic prescription',
        'prescription',
        prescriptionDate,
        [('medicine', 'Amoxicillin', '250', 'mg', '')],
      ),
      _report(
        '$prefix-blood-older',
        ownerId,
        'Synthetic earlier blood report',
        'lab',
        olderDate,
        [('lab', 'Hemoglobin', '10.8', 'g/dL', '10.0–14.0')],
      ),
      _report(
        '$prefix-undated',
        ownerId,
        'Synthetic undated note',
        'note',
        null,
        [('allergy', 'Allergy status', 'Not recorded', '', '')],
      ),
    ];
  }

  Report _report(
    String id,
    String ownerId,
    String name,
    String category,
    DateTime? date,
    List<(String, String, String, String, String)> values,
  ) {
    final lines = [
      const SourceLine(
        id: 'p1l1',
        page: 1,
        text: 'SYNTHETIC EXAMPLE — NOT A REAL PATIENT',
      ),
      SourceLine(id: 'p1l2', page: 1, text: 'Category: $category'),
      SourceLine(
        id: 'p1l3',
        page: 1,
        text: 'Clinical report date: ${_date(date)}',
      ),
      for (var i = 0; i < values.length; i++)
        SourceLine(
          id: 'p1l${i + 4}',
          page: 1,
          text:
              '${values[i].$2} | ${values[i].$3} | ${values[i].$4} | ${values[i].$5}',
        ),
    ];
    final report = Report(
      id: id,
      profileId: ownerId,
      name: name,
      extension: 'txt',
      digest: 'synthetic:$id',
      importedAt: DateTime.now(),
      eventDate: date,
      type: category,
      status: ReportStatus.ready,
      notice: 'Synthetic preview: this summary is scripted, not AI generated.',
      lines: lines,
      facts: [
        for (var i = 0; i < values.length; i++)
          MedicalFact(
            id: '$id-f$i',
            kind: values[i].$1,
            name: values[i].$2,
            value: values[i].$3,
            unit: values[i].$4,
            range: values[i].$5,
            sourceLineId: lines[i + 3].id,
            evidence: lines[i + 3].text,
          ),
      ],
    );
    return report.copy(summaryMarkdown: _summary(report));
  }

  String _summary(Report report) {
    final owner = profile!;
    final content = StringBuffer(
      '**Synthetic UX preview · scripted summary**\n\n',
    );
    content.writeln('## Overview\n');
    content.writeln(
      'Category: ${report.type}. Clinical date: ${_date(report.eventDate)}. '
      '${ageAtEvent(owner, report.eventDate)}. [${report.id}/p1l3]\n',
    );
    content.writeln('## Findings\n');
    content.writeln('| Name | Value | Unit | Printed range | Source |');
    content.writeln('| --- | --- | --- | --- | --- |');
    for (final fact in report.facts) {
      content.writeln(
        '| ${fact.name} | ${fact.value}${fact.corrected ? ' (user corrected)' : ''} | '
        '${fact.unit.isEmpty ? '—' : fact.unit} | '
        '${fact.range.isEmpty ? 'Not printed' : fact.range} | '
        '[${report.id}/${fact.sourceLineId}] |',
      );
    }
    content.writeln('\n## Open questions\n');
    content.write(
      'These invented values demonstrate source lookup and correction. '
      'They are not clinical advice.',
    );
    if (report.eventDate == null) {
      content.write(
        ' The source has no usable clinical date; its position '
        'and age remain unknown. [${report.id}/p1l3]',
      );
    }
    return content.toString();
  }

  String _date(DateTime? date) => date == null
      ? 'Unknown'
      : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
