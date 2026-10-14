import 'dart:convert';
import 'dart:async';
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
  Completer<String>? blocked;
  int blockAfter = 0;
  @override
  bool get available => ready;
  @override
  Future<String> generate(String instruction, String input) async {
    inputs.add(input);
    instructions.add(instruction);
    if (blocked != null && inputs.length > blockAfter) return blocked!.future;
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
  Completer<void>? saveGate, saveEntered, originalGate, originalEntered;
  bool failNextSave = false;
  @override
  Future<void> save(VaultData next) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('Synthetic unavailable storage');
    }
    final gate = saveGate;
    if (gate != null) {
      saveGate = null;
      saveEntered!.complete();
      await gate.future;
    }
    await super.save(next);
  }

  @override
  Future<void> saveOriginal(Report report, Uint8List bytes) async {
    await super.saveOriginal(report, bytes);
    if (originalGate != null) {
      originalEntered!.complete();
      await originalGate!.future;
    }
  }

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
    'Stop while acquiring protection releases the eventual lease without running work',
    () async {
      const channel = MethodChannel('synthetic/cancellation-lease');
      final begin = Completer<void>();
      final allow = Completer<bool>();
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'begin') {
              begin.complete();
              return allow.future;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final c = await open(
        fixture(),
        localProcessing: LocalProcessing(channel: channel, supported: true),
      );
      var ran = false;
      final task = c.runCancellableTask('Waiting for protection', () async {
        ran = true;
      }, background: true);
      await begin.future;
      c.cancelCurrentTask();
      expect(c.busy, isTrue);
      allow.complete(true);
      await task;
      expect(ran, isFalse);
      expect(methods, ['begin', 'end']);
      expect(c.busy, isFalse);
      expect(c.failure, isNull);
    },
  );
  test(
    'Stop finishes an in-flight vault write before admitting a fresh task',
    () async {
      final c = await open(fixture());
      final entered = vault.saveEntered = Completer<void>();
      final gate = vault.saveGate = Completer<void>();
      final next = c.data.copy(
        activeSessionByProfile: {'alice': 'committed-before-stop'},
      );
      final task = c.runCancellableTask(
        'Saving',
        () => c.persistCompanionData(next),
      );
      await entered.future;
      c.cancelCurrentTask();
      expect(c.busy, isTrue);
      var startedNew = false;
      await c.runCancellableTask('New', () async {
        startedNew = true;
      });
      expect(startedNew, isFalse);
      gate.complete();
      await task;
      expect(c.data.activeSessionByProfile, next.activeSessionByProfile);
      expect(
        (await vault.read()).activeSessionByProfile,
        next.activeSessionByProfile,
      );
      expect(c.busy, isFalse);
    },
  );
  for (final newSession in [false, true]) {
    test(
      'Stop preserves submitted user turn and memory during save (new conversation: $newSession)',
      () async {
        final c = await open(fixture(jobs: []));
        if (newSession) {
          c.data = c.data.copy(
            sessions: [],
            memories: [],
            clearActiveSession: true,
          );
          c.activeSessionId = null;
          c.restoreConversation();
        }
        final entered = vault.saveEntered = Completer<void>();
        final gate = vault.saveGate = Completer<void>();
        final task = c.ask('My synthetic hemoglobin is 13 g/dL');
        await entered.future;
        c.cancelCurrentTask();
        gate.complete();
        await task;
        expect(c.messages.last.text, 'My synthetic hemoglobin is 13 g/dL');
        expect(c.messages.last.isUser, isTrue);
        expect(c.activeSession!.turns.last.text, c.messages.last.text);
        expect(
          (await vault.read()).memories.last.text,
          contains('hemoglobin is 13'),
        );
        expect(c.failure, isNull);
        expect(intelligence.inputs, isEmpty);
      },
    );
  }
  test(
    'Stop during original save completes its index transaction and pauses processing',
    () async {
      final c = await open(fixture(jobs: []));
      final entered = vault.originalEntered = Completer<void>();
      final gate = vault.originalGate = Completer<void>();
      final bytes = Uint8List.fromList(
        utf8.encode('SYNTHETIC newly imported file'),
      );
      final task = c.importSample(bytes);
      await entered.future;
      c.cancelCurrentTask();
      expect(c.busy, isTrue);
      gate.complete();
      await task;
      vault.originalGate = null;
      final imported = c.data.reports.last;
      expect(imported.name, 'Synthetic blood report.txt');
      expect(await vault.readOriginal(imported, 'alice'), bytes);
      expect((await vault.read()).reports.last.id, imported.id);
      expect(c.data.processingJobs.single.paused, isTrue);
      expect(intelligence.inputs, isEmpty);
      expect(c.failure, isNull);
    },
  );
  test(
    'Stop pauses the entire queued batch durably without starting the next report',
    () async {
      intelligence.blocked = Completer<String>();
      final c = await open(fixture(jobs: [_job('alice'), _job('bob')]));
      final task = c.runPendingProcessingJobs();
      for (var i = 0; i < 100 && intelligence.inputs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(intelligence.inputs.length, 1);
      c.cancelCurrentTask();
      await task;
      expect(c.data.processingJobs.every((job) => job.paused), isTrue);
      expect(c.data.processingJobs.map((job) => job.attempts), [1, 0]);
      expect(
        (await vault.read()).processingJobs.every((job) => job.paused),
        isTrue,
      );
      final reads = vault.reads.length;
      await c.runPendingProcessingJobs();
      expect(vault.reads.length, reads);
      intelligence.blocked!.complete('Uncited late model output');
      await Future<void>.delayed(Duration.zero);
      expect(
        c.data.reports.every((report) => report.summaryMarkdown == null),
        isTrue,
      );
      expect(intelligence.inputs.length, 1);
    },
  );
  test(
    'Stop on a later report does not requeue a completed earlier report',
    () async {
      intelligence.blocked = Completer<String>();
      intelligence.blockAfter = 1;
      final c = await open(fixture(jobs: [_job('alice'), _job('bob')]));
      final task = c.runPendingProcessingJobs();
      for (var i = 0; i < 100 && intelligence.inputs.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(intelligence.inputs.length, 2);
      c.cancelCurrentTask();
      await task;
      expect(c.data.processingJobs.length, 1);
      expect(c.data.processingJobs.single.profileId, 'bob');
      expect(c.data.processingJobs.single.paused, isTrue);
      final completed = c.data.reports.firstWhere(
        (r) => r.profileId == 'alice',
      );
      expect(completed.status, ReportStatus.ready);
      expect(completed.summaryMarkdown, isNotNull);
      intelligence.blocked!.complete('Late notes');
    },
  );
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
  test(
    'failed pause persistence stays stopped in memory and reports the storage problem',
    () async {
      intelligence.blocked = Completer<String>();
      final c = await open(fixture());
      final task = c.runPendingProcessingJobs();
      for (var i = 0; i < 100 && intelligence.inputs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(intelligence.inputs.length, 1);
      vault.failNextSave = true;
      c.cancelCurrentTask();
      await task;
      expect(c.busy, isFalse);
      expect(c.failure, contains('paused status could not be saved'));
      expect(c.data.processingJobs.single.paused, isTrue);
      await c.runPendingProcessingJobs();
      expect(intelligence.inputs.length, 1);
      intelligence.blocked!.complete('Late notes');
    },
  );
  test(
    'old saved notes cannot mark a failed new processing attempt as successful',
    () async {
      intelligence.invalidMarkdown = true;
      final data = fixture();
      final c = await open(
        data.copy(
          reports: data.reports
              .map(
                (r) => r.copy(
                  summaryMarkdown: 'Previous notes [shared-report/p1-l1]',
                ),
              )
              .toList(),
        ),
      );
      await c.runPendingProcessingJobs();
      final report = c.data.reports.firstWhere((r) => r.profileId == 'bob');
      expect(report.summaryMarkdown, 'Previous notes [shared-report/p1-l1]');
      expect(report.status, ReportStatus.needsReview);
      expect(c.data.processingJobs.single.attempts, 1);
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
