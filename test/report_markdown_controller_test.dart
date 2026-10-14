import 'dart:io';
import 'dart:typed_data';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_file_picker.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _MarkdownIntelligence extends LocalIntelligence {
  bool ready = true;
  String output =
      '## Key information\nSynthetic observation recorded in this report [S1].';
  final instructions = <String>[];
  final inputs = <String>[];
  @override
  bool get available => ready;
  @override
  Future<String> generate(String instruction, String input) async {
    instructions.add(instruction);
    inputs.add(input);
    if (instruction == organizerPrompt || instruction == extractorPrompt) {
      throw StateError(
        'Report extraction must not require a JSON fact schema.',
      );
    }
    if (instruction != reportMarkdownPrompt &&
        !instruction.startsWith('$reportMarkdownPrompt\n\nOUTPUT REPAIR:')) {
      throw StateError('Unexpected model role in report processing.');
    }
    return output;
  }
}

class _MarkdownEmbeddings extends LocalEmbeddings {
  @override
  bool get available => true;
  @override
  String? get version => 'synthetic-markdown-embedding';
  @override
  Future<List<double>> embed(String text, {bool document = false}) async => [
    1,
    0,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, pickerRoot;
  late AppController c;
  late _MarkdownIntelligence model;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp(
      'ayumitra-markdown-controller-',
    );
    pickerRoot = Directory('${root.path}/picker')..createSync();
    model = _MarkdownIntelligence();
    c = AppController(intelligence: model, embeddings: _MarkdownEmbeddings())
      ..loaded = true
      ..activeProfileId = 'alice'
      ..data = VaultData(
        profiles: [
          Profile(
            id: 'alice',
            name: 'Synthetic Alice',
            history: '',
            dateOfBirth: DateTime(2000),
          ),
          Profile(
            id: 'bob',
            name: 'Synthetic Bob',
            history: '',
            dateOfBirth: DateTime(2001),
          ),
        ],
        activeProfileId: 'alice',
      )
      ..vault = EncryptedVault(
        directory: Directory('${root.path}/vault'),
        key: await AesGcm.with256bits().newSecretKey(),
      )
      ..pickerCache = PickerCache([pickerRoot])
      ..parser = LocalParser(
        Directory('${root.path}/scratch'),
        transcribe: (_) async => ['SYNTHETIC image observation'],
      );
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> importText(String text) async {
    final staged = File('${pickerRoot.path}/synthetic.txt')
      ..writeAsStringSync(text);
    await c.importFile(NativePickedFile(staged.path));
  }

  test(
    'native report stores readable owned Markdown and original-source vectors without fact JSON',
    () async {
      await importText(
        'SYNTHETIC observation recorded in this report\nReport date: 2026-03-14',
      );
      final report = c.data.reports.single;
      expect(report.profileId, 'alice');
      expect(report.summaryMarkdown, contains('## Key information'));
      expect(report.summaryMarkdown, contains('[${report.id}/p1-l1]'));
      expect(report.summaryMarkdown, isNot(contains('[S1]')));
      expect(report.eventDate, DateTime.utc(2026, 3, 14));
      expect(report.dateIsFallback, isFalse);
      expect(report.facts, isEmpty);
      expect(report.vectors.keys, containsAll(['p1-l1', 'p1-l2']));
      expect(report.embeddingVersion, 'synthetic-markdown-embedding');
      expect(c.data.processingJobs, isEmpty);
      expect(model.instructions, isNot(contains(organizerPrompt)));
      expect(model.instructions, isNot(contains(extractorPrompt)));
      final restored = await c.vault.read();
      expect(restored.reports.single.summaryMarkdown, report.summaryMarkdown);
      expect(restored.reports.single.dateIsFallback, isFalse);
      expect(restored.profiles.map((profile) => profile.id), ['alice', 'bob']);
    },
  );
  test(
    'unseen report date uses current filing date marked as fallback',
    () async {
      final before = DateTime.now();
      await importText('SYNTHETIC observation without a printed report date');
      final after = DateTime.now();
      final report = c.data.reports.single;
      expect(report.dateIsFallback, isTrue);
      expect(report.eventDate, isNotNull);
      final date = report.eventDate!;
      final candidates = [
        DateTime.utc(before.year, before.month, before.day),
        DateTime.utc(after.year, after.month, after.day),
      ];
      expect(candidates, contains(date));
      expect((await c.vault.read()).reports.single.dateIsFallback, isTrue);
      expect(c.data.processingJobs, isEmpty);
      expect(report.summaryMarkdown, isNotEmpty);
    },
  );
  test(
    'owned-image source transcription produces cited Markdown while preserving review provenance',
    () async {
      final bytes = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 8, height: 8)),
      );
      final staged = File('${pickerRoot.path}/synthetic.jpg')
        ..writeAsBytesSync(bytes);
      await c.importFile(NativePickedFile(staged.path));
      final report = c.data.reports.single;
      expect(report.profileId, 'alice');
      expect(report.lines.single.method, contains('vision'));
      expect(report.summaryMarkdown, contains('[${report.id}/p1-l1]'));
      expect(report.status, ReportStatus.needsReview);
      expect(report.facts, isEmpty);
      expect(c.data.processingJobs, isEmpty);
      expect(await c.vault.readOriginal(report, 'alice'), bytes);
      expect(await staged.exists(), isFalse);
    },
  );
  test(
    'a foreign Markdown citation is rejected after bounded repair and leaves original retryable',
    () async {
      model.output = 'Synthetic result [other-report/p1-l1].';
      await importText('SYNTHETIC observation recorded in this report');
      final report = c.data.reports.single;
      expect(report.summaryMarkdown, isNull);
      expect(c.data.processingJobs.single.profileId, 'alice');
      expect(c.data.processingJobs.single.attempts, greaterThan(0));
      expect(model.inputs.length, lessThanOrEqualTo(10));
      expect(await c.vault.readOriginal(report, 'alice'), isNotEmpty);
      expect((await c.vault.read()).processingJobs, isNotEmpty);
    },
  );
}
