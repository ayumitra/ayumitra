import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_file_picker.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic fixture only. Never a real patient.
const _text =
    'SYNTHETIC REPORT - NOT A REAL PATIENT\n'
    'Hemoglobin 11.2 g/dL\n';
const _noSummaryNotice =
    'Report notes could not be linked to their sources. The original is saved and processing will retry.';

/// Scripted local model: direct Markdown report notes come from the script queue.
class SummaryScriptIntelligence extends LocalIntelligence {
  SummaryScriptIntelligence(this.summaryOutputs);
  final List<String> summaryOutputs;
  final summaryInputs = <String>[];
  int summaryCalls = 0;

  @override
  bool get available => true;

  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == reportMarkdownPrompt ||
        instruction.startsWith('$reportMarkdownPrompt\n\nOUTPUT REPAIR:')) {
      summaryInputs.add(input);
      final index = summaryCalls++;
      return index < summaryOutputs.length
          ? summaryOutputs[index]
          : summaryOutputs.last;
    }
    return '{}';
  }
}

Profile _owner() => Profile(
  id: 'p',
  name: 'Synthetic',
  age: 8,
  ageRecordedAt: DateTime(2026),
  history: '',
);

Future<AppController> _nativeController(
  Directory directory,
  SummaryScriptIntelligence intelligence,
) async {
  final cache = Directory('${directory.path}/picker')..createSync();
  final staged = File('${cache.path}/SYNTHETIC.txt')..writeAsStringSync(_text);
  final controller = AppController(intelligence: intelligence)
    ..loaded = true
    ..activeProfileId = 'p'
    ..data = VaultData(profiles: [_owner()])
    ..vault = EncryptedVault(
      directory: Directory('${directory.path}/vault'),
      key: await AesGcm.with256bits().newSecretKey(),
    )
    ..pickerCache = PickerCache([cache])
    ..parser = LocalParser(
      Directory('${directory.path}/scratch'),
      transcribe: (_) async => [],
    );
  await controller.importFile(NativePickedFile(staged.path));
  return controller;
}

void _expectResolvedSummary(String? summary) {
  expect(summary, isNotNull);
  expect(summary, contains('11.2'));
  // Canonical ownership survives; short per-call alias tokens must not leak.
  expect(summary, contains('/p1-l2'));
  expect(summary!.contains(RegExp(r'\[S\d+\]')), isFalse);
}

void main() {
  test(
    'Native import repairs a malformed summary and resolves citations',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      try {
        final intelligence = SummaryScriptIntelligence([
          'All good, no citations here.',
          'Hemoglobin 11.2 g/dL [S2].',
        ]);
        final controller = await _nativeController(directory, intelligence);
        expect(intelligence.summaryCalls, 2);
        // The repair attempt carries guidance, never the rejected draft.
        expect(intelligence.summaryInputs[1], contains('outputRepair'));
        expect(
          intelligence.summaryInputs[1].contains('All good, no citations here'),
          isFalse,
        );
        final report = controller.reports.single;
        expect(report.facts, isEmpty);
        expect(
          report.lines.any((l) => l.text == 'Hemoglobin 11.2 g/dL'),
          isTrue,
        );
        _expectResolvedSummary(report.summaryMarkdown);
        expect(report.notice, isNull);
        controller.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Native import keeps the no-summary notice when repairs are capped',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      try {
        final intelligence = SummaryScriptIntelligence([
          'Bad one.',
          'Bad two.',
          'Bad three.',
        ]);
        final controller = await _nativeController(directory, intelligence);
        // First attempt plus nine controlled repairs, then the cap fallback.
        expect(intelligence.summaryCalls, 10);
        for (final input in intelligence.summaryInputs) {
          expect(
            input,
            contains(
              '"task":"Extract key report information and dates as Markdown"',
            ),
          );
          expect(jsonDecode(input)['sourceRows'], hasLength(2));
        }
        final report = controller.reports.single;
        expect(report.summaryMarkdown, isNull);
        expect(report.notice, _noSummaryNotice);
        expect(report.facts, isEmpty);
        expect(
          report.lines.any((l) => l.text == 'Hemoglobin 11.2 g/dL'),
          isTrue,
        );
        controller.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Demo import repairs a malformed summary and resolves citations',
    () async {
      final intelligence = SummaryScriptIntelligence([
        'All good, no citations here.',
        'Hemoglobin 11.2 g/dL [S2].',
      ]);
      final controller = DemoController(intelligence: intelligence)
        ..loaded = true
        ..activeProfileId = 'p'
        ..data = VaultData(profiles: [_owner()]);
      await controller.importBytes(
        'synthetic.txt',
        'txt',
        Uint8List.fromList(utf8.encode(_text)),
      );
      expect(intelligence.summaryCalls, 2);
      expect(intelligence.summaryInputs[1], contains('outputRepair'));
      expect(
        intelligence.summaryInputs[1].contains('All good, no citations here'),
        isFalse,
      );
      final report = controller.reports.single;
      _expectResolvedSummary(report.summaryMarkdown);
      expect(report.notice, isNull);
      controller.dispose();
    },
  );
}
