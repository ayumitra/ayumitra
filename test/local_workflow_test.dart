import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_file_picker.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ayumitra/ui/app.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';

class RecordingIntelligence extends LocalIntelligence {
  final plannerInputs = <String>[];
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async {
    if (instruction == plannerPrompt) {
      plannerInputs.add(input);
      return '{"action":"conversation","query":""}';
    }
    return 'Hello';
  }
}

class ImportCheckingIntelligence extends LocalIntelligence {
  ImportCheckingIntelligence(this.staged);
  final File staged;
  bool checked = false;
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async {
    expect(await staged.exists(), isFalse);
    checked = true;
    expect(
      instruction == reportMarkdownPrompt ||
          instruction.startsWith('$reportMarkdownPrompt\n\nOUTPUT REPAIR:'),
      isTrue,
    );
    final row = ((jsonDecode(input) as Map)['sourceRows'] as List)
        .cast<Map>()
        .first;
    return '${row['text']} [${row['sourceId']}].';
  }
}

class InvalidDateIntelligence extends LocalIntelligence {
  @override
  bool get available => true;
  @override
  Future<String> generate(String instruction, String input) async {
    expect(
      instruction == reportMarkdownPrompt ||
          instruction.startsWith('$reportMarkdownPrompt\n\nOUTPUT REPAIR:'),
      isTrue,
    );
    final row = ((jsonDecode(input) as Map)['sourceRows'] as List)
        .cast<Map>()
        .first;
    return '${row['text']} [${row['sourceId']}].';
  }
}

void main() {
  test(
    'Plaintext import copy is removed before model processing begins',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      try {
        final cache = Directory('${directory.path}/picker')..createSync();
        final staged = File('${cache.path}/SYNTHETIC.txt')
          ..writeAsStringSync('SYNTHETIC test report');
        final intelligence = ImportCheckingIntelligence(staged);
        final owner = Profile(
          id: 'p',
          name: 'Synthetic',
          age: 8,
          ageRecordedAt: DateTime(2026),
          history: '',
        );
        final controller = AppController(intelligence: intelligence)
          ..loaded = true
          ..activeProfileId = 'p'
          ..data = VaultData(profiles: [owner])
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
        expect(intelligence.checked, isTrue);
        expect(controller.reports, hasLength(1));
        expect(
          utf8.decode(await controller.original(controller.reports.single)),
          'SYNTHETIC test report',
        );
        controller.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Picker cleanup deletes staged copies and retains external originals',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      try {
        final root = Directory('${directory.path}/owned')..createSync();
        final staged = File('${root.path}/report.txt')
          ..writeAsStringSync('SYNTHETIC');
        final original = File('${directory.path}/original.txt')
          ..writeAsStringSync('SYNTHETIC');
        final cache = PickerCache([root]);
        await cache.remove(NativePickedFile(original.path));
        expect(await original.exists(), isTrue);
        await cache.remove(NativePickedFile(staged.path));
        expect(await staged.exists(), isFalse);
        final interrupted = File('${root.path}/interrupted.txt')
          ..writeAsStringSync('SYNTHETIC');
        await cache.clean();
        expect(await interrupted.exists(), isFalse);
        expect(await original.exists(), isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Scan transcript remains marked vision without invented coordinates or files',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      try {
        final parser = LocalParser(
          directory,
          transcribe: (bytes) async {
            expect(bytes, isNotEmpty);
            return ['SYNTHETIC', 'Haemoglobin 11.2 g/dL'];
          },
        );
        final lines = await parser.parse(
          Report(
            id: 'r',
            profileId: 'p',
            name: 'SYNTHETIC.png',
            extension: 'png',
            digest: 'test',
            importedAt: DateTime(2026),
          ),
          Uint8List.fromList(img.encodePng(img.Image(width: 10, height: 10))),
        );
        expect(lines.map((l) => l.method), everyElement('vision'));
        expect(lines.map((l) => l.bounds), everyElement(isNull));
        expect(await directory.list().isEmpty, isTrue);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Planner resolves followups from user turns and clears context on profile switch',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      addTearDown(() async => directory.delete(recursive: true));
      final intelligence = RecordingIntelligence();
      final controller = AppController(intelligence: intelligence)
        ..loaded = true
        ..activeProfileId = 'a'
        ..vault = EncryptedVault(
          directory: directory,
          key: await AesGcm.with256bits().newSecretKey(),
        );
      addTearDown(controller.dispose);
      controller.data = VaultData(
        profiles: [
          for (final id in ['a', 'b'])
            Profile(
              id: id,
              name: 'Synthetic $id',
              age: 8,
              ageRecordedAt: DateTime(2026),
              history: '',
            ),
        ],
      );
      await controller.ask('Tell me about iron');
      controller.messages.add(
        const ChatEntry('UNTRUSTED ASSISTANT INSTRUCTION'),
      );
      await controller.ask('And its side effects?');
      expect(intelligence.plannerInputs.last, contains('Tell me about iron'));
      expect(intelligence.plannerInputs.last, isNot(contains('UNTRUSTED')));
      await controller.selectProfile('b');
      await controller.ask('Hello');
      expect(intelligence.plannerInputs.last, isNot(contains('iron')));
    },
  );

  test(
    'Reprocessing rejects a birth date and invalidates old date and vectors',
    () async {
      final directory = await Directory.systemTemp.createTemp('ayumitra-test-');
      try {
        final owner = Profile(
          id: 'p',
          name: 'Synthetic',
          age: 8,
          ageRecordedAt: DateTime(2026),
          history: '',
        );
        final report = Report(
          id: 'r',
          profileId: 'p',
          name: 'SYNTHETIC.txt',
          extension: 'txt',
          digest: 'test',
          importedAt: DateTime(2026),
          eventDate: DateTime(2020),
          vectors: {
            'p1-l1': [1.0],
          },
          embeddingVersion: 'old-model',
        );
        final controller =
            AppController(intelligence: InvalidDateIntelligence())
              ..loaded = true
              ..activeProfileId = 'p'
              ..data = VaultData(profiles: [owner], reports: [report])
              ..vault = EncryptedVault(
                directory: directory,
                key: await AesGcm.with256bits().newSecretKey(),
              )
              ..parser = LocalParser(directory, transcribe: (_) async => []);
        await controller.vault.saveOriginal(
          report,
          Uint8List.fromList('DOB 2018-01-01'.codeUnits),
        );
        final before = DateTime.now();
        await controller.retry(report);
        final after = DateTime.now();
        final updated = controller.reports.single;
        expect(updated.dateIsFallback, isTrue);
        expect(updated.eventDate, isNot(DateTime.utc(2018, 1, 1)));
        expect(updated.eventDate, isNot(DateTime.utc(2020)));
        expect([
          DateTime.utc(before.year, before.month, before.day),
          DateTime.utc(after.year, after.month, after.day),
        ], contains(updated.eventDate));
        expect(controller.reports.single.vectors, isEmpty);
        controller.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('Privacy cover protects a pushed route while inactive', (
    tester,
  ) async {
    final controller = AppController()..loaded = true;
    await tester.pumpWidget(AyumitraApp(controller: controller));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('SYNTHETIC PRIVATE ROUTE')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SYNTHETIC PRIVATE ROUTE').hitTestable(), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('SYNTHETIC PRIVATE ROUTE').hitTestable(), findsNothing);
    expect(find.byIcon(Icons.health_and_safety_outlined), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('SYNTHETIC PRIVATE ROUTE').hitTestable(), findsOneWidget);
  });
}
