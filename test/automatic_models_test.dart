import 'dart:async';

import 'package:ayumitra/services/automatic_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<Object?, Object?> _state(DefaultModel m, String state, {int? bytes}) => {
  'role': m.role.name,
  'state': state,
  'downloadedBytes': bytes ?? (state == 'ready' ? m.bytes : 0),
  'totalBytes': m.bytes,
  if (state == 'ready') ...{
    'path': '/private/files/ayumitra-models/${m.filename}',
    'sha256': m.sha256,
  },
};

void main() {
  test(
    'OS download is ensured once, then polled until verified private file',
    () async {
      final calls = <String>[];
      final progress = <String>[];
      final m = DefaultModel.assistant;
      final states = [
        _state(m, 'queued'),
        _state(m, 'downloading', bytes: 1400000000),
        _state(m, 'verifying', bytes: m.bytes),
        _state(m, 'ready'),
      ];
      final setup = AutomaticModels(
        pollInterval: Duration.zero,
        call: (method, args) async {
          calls.add(method);
          expect(args, {'role': 'assistant'});
          return states.removeAt(0);
        },
      );
      final file = await setup.prepare(
        m,
        supportPath: '/private/files',
        cancelled: () => false,
        onProgress: (p) => progress.add(p.state),
      );
      expect(calls, ['ensure', 'status', 'status', 'status']);
      expect(progress, ['queued', 'downloading', 'verifying', 'ready']);
      expect(file.path, '/private/files/ayumitra-models/${m.filename}');
    },
  );

  test(
    'restart resumes through ensure without a Dart download or arbitrary URL',
    () async {
      final m = DefaultModel.embedding;
      var ready = false;
      final methods = <String>[];
      final setup = AutomaticModels(
        pollInterval: Duration.zero,
        call: (method, args) async {
          methods.add(method);
          expect(args.keys, ['role']);
          return _state(m, ready ? 'ready' : 'failed');
        },
      );
      Future<VerifiedModel> run() => setup.prepare(
        m,
        supportPath: '/private/files',
        cancelled: () => false,
        onProgress: (_) {},
      );
      await expectLater(run(), throwsStateError);
      ready = true;
      expect((await run()).model, m);
      expect(methods, ['ensure', 'ensure']);
    },
  );

  test(
    'wrong fingerprint, external path, role, bytes and unknown state are refused',
    () async {
      final m = DefaultModel.embedding;
      for (final change in [
        {'sha256': 'bad'},
        {'path': '/sdcard/${m.filename}'},
        {'role': 'assistant'},
        {'totalBytes': 12},
        {'downloadedBytes': -1},
        {'state': 'cloud'},
      ]) {
        final setup = AutomaticModels(
          call: (_, _) async => {..._state(m, 'ready'), ...change},
        );
        await expectLater(
          setup.prepare(
            m,
            supportPath: '/private/files',
            cancelled: () => false,
            onProgress: (_) {},
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'closing polling does not cancel the OS download or activate a late response',
    () async {
      final m = DefaultModel.embedding;
      final reply = Completer<Map<Object?, Object?>>();
      final calls = <String>[];
      var closed = false;
      final setup = AutomaticModels(
        call: (method, _) {
          calls.add(method);
          return reply.future;
        },
      );
      final job = setup.prepare(
        m,
        supportPath: '/private/files',
        cancelled: () => closed,
        onProgress: (_) => fail('Late reply must not update closed UI'),
      );
      closed = true;
      reply.complete(_state(m, 'ready'));
      await expectLater(job, throwsStateError);
      expect(calls, ['ensure']);
    },
  );
}
