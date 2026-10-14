import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/domain/processing_jobs.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/report_markdown.dart';
import 'package:ayumitra/services/second_opinion_draft.dart';
import 'package:ayumitra/services/task_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model extends LocalIntelligence {
  final calls = <String>[];
  String? blockedRole;
  Completer<String>? blocked;
  int stops = 0;
  String planner = '{"actions":[{"action":"conversation","query":""}]}';
  @override
  bool get available => true;
  @override
  Future<void> cancelGeneration() async {
    stops++;
  }

  @override
  Future<String> generate(String instruction, String input) async {
    calls.add(instruction);
    if (instruction == blockedRole) return blocked!.future;
    if (instruction == plannerPrompt) {
      return planner;
    }
    if (instruction == reportMarkdownPrompt) {
      return '# Notes\nSynthetic hemoglobin 13 g/dL [S1].';
    }
    return 'Hello. How can I help?';
  }
}

class _Embeddings extends LocalEmbeddings {
  @override
  bool get available => true;
  @override
  Future<List<double>> embed(String text, {bool document = false}) async => [
    1,
    0,
  ];
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'Task reached its blocked boundary');
}

Future<DemoController> _open(_Model model, {String history = ''}) async {
  final c = DemoController(intelligence: model, embeddings: _Embeddings());
  await c.initialize();
  await c.createProfile('Synthetic', DateTime(2000), history, false);
  return c;
}

void main() {
  test('token cancellation consumes late results and failures', () async {
    final token = CancellationToken();
    final late = Completer<String>();
    final pending = token.race(late.future);
    final checked = expectLater(pending, throwsA(isA<TaskCancelled>()));
    token.cancel();
    token.cancel();
    await checked;
    late.completeError(StateError('Synthetic late failure'));
    await Future<void>.delayed(Duration.zero);
    final alreadyStopped = token.race(Future.value('late answer'));
    await expectLater(alreadyStopped, throwsA(isA<TaskCancelled>()));
  });
  test(
    'stopped planner preserves the user turn and prevents repairs and late answers',
    () async {
      final model = _Model()
        ..blockedRole = plannerPrompt
        ..blocked = Completer<String>();
      final c = await _open(model);
      addTearDown(c.dispose);
      final task = c.ask('Hello');
      await _until(() => model.calls.isNotEmpty);
      expect(c.canCancelTask, isTrue);
      c.cancelCurrentTask();
      c.cancelCurrentTask();
      await task;
      expect(c.busy, isFalse);
      expect(c.failure, isNull);
      expect(c.cancellationRevision, 1);
      expect(model.stops, 1);
      expect(c.messages.single.text, 'Hello');
      expect(c.messages.single.isUser, isTrue);
      model.blocked!.complete('malformed output after Stop');
      await Future<void>.delayed(Duration.zero);
      expect(model.calls, [plannerPrompt]);
      expect(c.messages.length, 1);
      model.blockedRole = null;
      await c.ask('Hello again');
      expect(c.messages.last.isUser, isFalse);
      expect(c.busy, isFalse);
    },
  );
  test(
    'Stop during final answer prevents assistant publication and repair attempts',
    () async {
      final model = _Model()
        ..planner =
            '{"actions":[{"action":"search_records","query":"hemoglobin"}]}'
        ..blockedRole = summaryPrompt
        ..blocked = Completer<String>();
      final c = await _open(model);
      addTearDown(c.dispose);
      c.data = c.data.copy(
        reports: [
          Report(
            id: 'synthetic-report',
            profileId: c.activeProfileId!,
            name: 'synthetic.txt',
            extension: 'txt',
            digest: 'synthetic',
            importedAt: DateTime(2026),
            lines: const [
              SourceLine(id: 'row', page: 1, text: 'Hemoglobin 13 g/dL'),
            ],
          ),
        ],
      );
      final task = c.ask('What is my hemoglobin?');
      await _until(() => model.calls.contains(summaryPrompt));
      c.cancelCurrentTask();
      await task;
      model.blocked!.complete('Wrong unreferenced late answer');
      await Future<void>.delayed(Duration.zero);
      expect(c.messages.where((m) => !m.isUser), isEmpty);
      expect(model.calls.length, 2);
      expect(c.failure, isNull);
    },
  );
  test(
    'Stop during draft synthesis returns no generated or fallback success',
    () async {
      final model = _Model()
        ..blockedRole = secondOpinionDraftPrompt
        ..blocked = Completer<String>();
      final c = await _open(
        model,
        history: 'Synthetic user reports a history of seasonal allergies',
      );
      addTearDown(c.dispose);
      final task = c.generateSecondOpinionDraft();
      await _until(() => model.calls.contains(secondOpinionDraftPrompt));
      c.cancelCurrentTask();
      expect(await task, isNull);
      model.blocked!.complete('Late unreferenced draft');
      await Future<void>.delayed(Duration.zero);
      expect(model.calls.length, 1);
      expect(c.data.exports, isEmpty);
      expect(c.failure, isNull);
    },
  );
  test('late task cannot write after a fresh task has started', () async {
    final c = await _open(_Model());
    addTearDown(c.dispose);
    final started = Completer<void>();
    final late = Completer<void>();
    final old = c.runCancellableTask('Old task', () async {
      started.complete();
      await c.taskCall(
        () => late.future.then((_) async {
          // This continuation retains the old task zone after Stop.
          await c.persistCompanionData(c.data.copy(profiles: []));
        }),
      );
    });
    await started.future;
    c.cancelCurrentTask();
    await old;
    final next = Completer<void>();
    final current = c.runCancellableTask(
      'Fresh task',
      () => c.taskCall(() => next.future),
    );
    expect(c.busy, isTrue);
    late.complete();
    await Future<void>.delayed(Duration.zero);
    expect(c.data.profiles.length, 1);
    expect(c.activity, 'Fresh task');
    expect(c.canCancelTask, isTrue);
    next.complete();
    await current;
    expect(c.busy, isFalse);
  });
  test(
    'stopped import keeps original and searchable text; only explicit retry resumes notes',
    () async {
      final model = _Model()
        ..blockedRole = reportMarkdownPrompt
        ..blocked = Completer<String>();
      final c = await _open(model);
      addTearDown(c.dispose);
      final bytes = Uint8List.fromList(
        utf8.encode('Synthetic hemoglobin 13 g/dL'),
      );
      final importing = c.importBytes('synthetic.txt', 'txt', bytes);
      await _until(() => model.calls.contains(reportMarkdownPrompt));
      c.cancelCurrentTask();
      await importing;
      final report = c.data.reports.single;
      expect(report.lines.single.text, contains('hemoglobin 13'));
      expect(report.summaryMarkdown, isNull);
      expect(report.status, ReportStatus.needsReview);
      expect(report.notice, contains('paused'));
      expect(await c.original(report), bytes);
      expect(c.data.processingJobs.single.paused, isTrue);
      expect(
        pendingReportJobs(c.data, DateTime.now().add(const Duration(days: 30))),
        isEmpty,
      );
      model.blocked!.complete('# Late notes [S1]');
      await Future<void>.delayed(Duration.zero);
      expect(c.data.reports.single.summaryMarkdown, isNull);
      expect(model.calls.length, 1);
      model.blockedRole = null;
      await c.retry(report);
      expect(c.data.processingJobs, isEmpty);
      expect(c.data.reports.single.summaryMarkdown, contains('hemoglobin 13'));
      expect(await c.original(report), bytes);
    },
  );
  test(
    'manual retry retains a job when fresh notes fail validation despite old notes',
    () async {
      final model = _Model();
      final c = await _open(model);
      addTearDown(c.dispose);
      final bytes = Uint8List.fromList(
        utf8.encode('Synthetic hemoglobin 13 g/dL'),
      );
      await c.importBytes('synthetic.txt', 'txt', bytes);
      final report = c.data.reports.single;
      expect(report.summaryMarkdown, isNotNull);
      model.blockedRole = reportMarkdownPrompt;
      model.blocked = Completer<String>()..complete('Invalid uncited draft');
      await c.retry(report);
      expect(c.data.reports.single.status, ReportStatus.needsReview);
      expect(c.data.processingJobs.length, 1);
      expect(c.data.processingJobs.single.paused, isFalse);
    },
  );
  test(
    'draft owns its cancellable task before the first asynchronous boundary',
    () async {
      final c = await _open(_Model());
      addTearDown(c.dispose);
      await c.newConversation();
      final pending = c.generateSecondOpinionDraft();
      expect(c.canCancelTask, isTrue);
      c.cancelCurrentTask();
      expect(await pending, isNull);
      expect(c.busy, isFalse);
      expect(c.failure, isNull);
    },
  );
}
