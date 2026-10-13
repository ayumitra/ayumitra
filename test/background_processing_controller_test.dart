import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:ayumitra/services/local_processing.dart';
import 'package:flutter/services.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _JobIntelligence extends LocalIntelligence {
  bool ready = true;
  bool fail = false;
  final inputs = <String>[];
  final instructions = <String>[];
  bool invalidMarkdown = false;
  @override
  bool get available => ready;
  @override
  Future<String> generate(String instruction, String input) async {
    inputs.add(input);
    instructions.add(instruction);
    if (fail) throw StateError('Synthetic interrupted model');
    if (instruction == organizerPrompt || instruction == extractorPrompt) {
      throw StateError('Reports must use Markdown rather than forced JSON.');
    }
    if (instruction != reportMarkdownPrompt &&
        !instruction.startsWith('$reportMarkdownPrompt\n\nOUTPUT REPAIR:')) {
      throw StateError('Unexpected model role in report processing.');
    }
    return invalidMarkdown
        ? 'Synthetic notes without a source.'
        : '## Notes\nSYNTHETIC bob fixture [S1].';
  }
}

class _JobEmbeddings extends LocalEmbeddings {
  bool ready = true;
  final inputs = <String>[];
  @override
  bool get available => ready;
  @override
  String? get version => 'synthetic-embedding';
  @override
  Future<List<double>> embed(String text, {bool document = false}) async {
    inputs.add(text);
    return [1, 0];
  }
}

class _ReadSpyVault extends EncryptedVault {
  _ReadSpyVault({required super.directory, required super.key});
  final reads = <String>[];
  @override
  Future<Uint8List> readOriginal(Report report, String activeProfileId) {
    reads.add('${report.profileId}/${report.id}');
    return super.readOriginal(report, activeProfileId);
  }
}

Profile _owner(String id) => Profile(
  id: id,
  name: 'Synthetic $id',
  history: '',
  dateOfBirth: DateTime(2000),
);
Report _report(String owner) => Report(
  id: 'shared-report',
  profileId: owner,
  name: 'synthetic.txt',
  extension: 'txt',
  digest: 'synthetic-$owner',
  importedAt: DateTime(2026, 10, 13),
);
ReportProcessingJob _job(String owner, {int attempts = 0}) =>
    ReportProcessingJob(
      reportId: 'shared-report',
      profileId: owner,
      attempts: attempts,
      nextAttemptAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _ReadSpyVault vault;
  late _JobIntelligence intelligence;
  late _JobEmbeddings embeddings;
  final controllers = <AppController>[];
  Future<AppController> open(
    VaultData data, {
    LocalProcessing? localProcessing,
  }) async {
    final c =
        AppController(
            intelligence: intelligence,
            embeddings: embeddings,
            localProcessing: localProcessing,
          )
          ..loaded = true
          ..vault = vault
          ..parser = LocalParser(
            Directory('${root.path}/scratch'),
            transcribe: (_) async => [],
          )
          ..data = data
          ..activeProfileId = data.activeProfileId
          ..activeSessionId = data.activeSessionId;
    controllers.add(c);
    c.restoreConversation();
    return c;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('ayumitra-background-test-');
    vault = _ReadSpyVault(
      directory: Directory('${root.path}/vault'),
      key: await AesGcm.with256bits().newSecretKey(),
    );
    intelligence = _JobIntelligence();
    embeddings = _JobEmbeddings();
    for (final owner in ['alice', 'bob']) {
      await vault.saveOriginal(
        _report(owner),
        Uint8List.fromList(utf8.encode('SYNTHETIC $owner fixture')),
      );
    }
  });
  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    await root.delete(recursive: true);
  });
  VaultData fixture({List<ReportProcessingJob>? jobs}) {
    final date = DateTime(2026, 10, 13);
    final session = ConversationSession(
      id: 'alice-chat',
      profileId: 'alice',
      title: 'Synthetic chat',
      createdAt: date,
      updatedAt: date,
      turns: [
        ConversationTurn(
          id: 'alice-turn',
          role: 'user',
          text: 'Synthetic active conversation',
          createdAt: date,
        ),
      ],
    );
    return VaultData(
      profiles: [_owner('alice'), _owner('bob')],
      reports: [_report('alice'), _report('bob')],
      sessions: [session],
      memories: [buildConversationMemory(session)],
      processingJobs: jobs ?? [_job('bob')],
      activeProfileId: 'alice',
      activeSessionId: session.id,
      activeSessionByProfile: {'alice': session.id},
    );
  }

  test(
    'background completion processes inactive owned report without changing current conversation',
    () async {
      final original = fixture();
      await vault.save(original);
      final c = await open(original);
      final messagesBefore = c.messages.map((m) => m.text).toList();
      await c.runPendingProcessingJobs();
      expect(vault.reads, ['bob/shared-report']);
      expect(
        intelligence.inputs,
        everyElement(contains('SYNTHETIC bob fixture')),
      );
      expect(embeddings.inputs, ['SYNTHETIC bob fixture']);
      expect(c.data.processingJobs, isEmpty);
      expect(c.activeProfileId, 'alice');
      expect(c.activeSessionId, 'alice-chat');
      expect(c.data.activeSessionByProfile, original.activeSessionByProfile);
      expect(c.messages.map((m) => m.text), messagesBefore);
      expect(
        c.data.sessions.single.toJson(),
        original.sessions.single.toJson(),
      );
      expect(
        c.data.memories.single.toJson(),
        original.memories.single.toJson(),
      );
      final alice = c.data.reports.firstWhere((r) => r.profileId == 'alice');
      expect(alice.toJson(), original.reports.first.toJson());
      final bob = c.data.reports.firstWhere((r) => r.profileId == 'bob');
      expect(bob.status, ReportStatus.ready);
      expect(bob.summaryMarkdown, contains('## Notes'));
      expect(bob.summaryMarkdown, contains('[shared-report/p1-l1]'));
      expect(intelligence.instructions, isNot(contains(organizerPrompt)));
      expect(intelligence.instructions, isNot(contains(extractorPrompt)));
      expect(bob.vectors, isNotEmpty);
      expect((await vault.read()).processingJobs, isEmpty);
    },
  );
  test('uncited report notes cannot complete an unfinished job', () async {
    intelligence.invalidMarkdown = true;
    final c = await open(fixture());
    await vault.save(c.data);
    await c.runPendingProcessingJobs();
    final bob = c.data.reports.firstWhere(
      (report) => report.profileId == 'bob',
    );
    expect(bob.summaryMarkdown, isNull);
    expect(c.data.processingJobs.single.profileId, 'bob');
    expect(c.data.processingJobs.single.attempts, greaterThan(0));
    expect((await vault.read()).processingJobs, isNotEmpty);
    expect(c.activeProfileId, 'alice');
    expect(c.data.sessions.single.turns.length, 1);
  });

  test(
    'denied native background protection preserves the queued attempt budget',
    () async {
      const channel = MethodChannel('test.ayumitra/background-job');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'begin');
            expect(call.arguments, isNull);
            return false;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final original = fixture();
      final c = await open(
        original,
        localProcessing: LocalProcessing(channel: channel, supported: true),
      );
      await c.runPendingProcessingJobs();
      expect(vault.reads, isEmpty);
      expect(intelligence.inputs, isEmpty);
      expect(c.data.processingJobs.single.attempts, 0);
      expect(
        c.data.reports.map((r) => r.toJson()),
        original.reports.map((r) => r.toJson()),
      );
      expect(c.processingNotice, contains('when Ayumitra is open'));
      expect(c.busy, isFalse);
    },
  );

  test('busy or either missing model leaves queued report untouched', () async {
    final c = await open(fixture());
    c.busy = true;
    await c.runPendingProcessingJobs();
    c.busy = false;
    intelligence.ready = false;
    await c.runPendingProcessingJobs();
    intelligence.ready = true;
    embeddings.ready = false;
    await c.runPendingProcessingJobs();
    expect(vault.reads, isEmpty);
    expect(intelligence.inputs, isEmpty);
    expect(c.data.processingJobs.length, 1);
    expect(c.data.reports.every((r) => r.status == ReportStatus.saved), isTrue);
  });
  test(
    'orphan or erased-owner jobs cannot read files or invoke local models',
    () async {
      final data = fixture(
        jobs: [_job('bob'), _job('missing')],
      ).copy(reports: [_report('alice')], deletedProfileIds: ['bob']);
      final c = await open(data);
      await c.runPendingProcessingJobs();
      expect(vault.reads, isEmpty);
      expect(intelligence.inputs, isEmpty);
      expect(embeddings.inputs, isEmpty);
    },
  );
  test(
    'failures persist backoff across reload, stop at cap and preserve original',
    () async {
      intelligence.fail = true;
      var data = fixture();
      await vault.save(data);
      var previousAttempts = 0;
      for (var round = 0; round < 3; round++) {
        final c = await open(await vault.read());
        final before = DateTime.now();
        await c.runPendingProcessingJobs();
        data = await vault.read();
        final job = data.processingJobs.single;
        expect(job.attempts, greaterThan(previousAttempts));
        expect(job.attempts, lessThanOrEqualTo(3));
        expect(job.nextAttemptAt.isAfter(before), isTrue);
        final reads = vault.reads.length;
        await c.runPendingProcessingJobs();
        expect(vault.reads.length, reads);
        expect(
          data.reports.firstWhere((r) => r.profileId == 'bob').status,
          ReportStatus.needsReview,
        );
        previousAttempts = job.attempts;
        if (job.attempts >= 3) break;
        await vault.save(
          data.copy(
            processingJobs: [
              job.copy(
                nextAttemptAt: DateTime.now().subtract(
                  const Duration(seconds: 1),
                ),
              ),
            ],
          ),
        );
      }
      expect(data.processingJobs.single.attempts, 3);
      final capped = await open(data);
      final calls = intelligence.inputs.length;
      await capped.runPendingProcessingJobs();
      expect(intelligence.inputs.length, calls);
      expect(
        utf8.decode(await vault.readOriginal(_report('bob'), 'bob')),
        'SYNTHETIC bob fixture',
      );
    },
  );
  test(
    'profile deletion removes its queued job and originals without disturbing active owner',
    () async {
      final c = await open(fixture());
      await vault.save(c.data);
      await c.deleteProfile('bob');
      expect(c.data.processingJobs, isEmpty);
      expect((await vault.read()).processingJobs, isEmpty);
      expect(c.activeProfileId, 'alice');
      expect(c.activeSessionId, 'alice-chat');
      expect(
        await Directory('${vault.directory.path}/originals/bob').exists(),
        isFalse,
      );
      await c.runPendingProcessingJobs();
      expect(intelligence.inputs, isEmpty);
      expect(
        utf8.decode(await vault.readOriginal(_report('alice'), 'alice')),
        'SYNTHETIC alice fixture',
      );
    },
  );
}
