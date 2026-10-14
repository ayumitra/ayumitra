import 'dart:async';
import 'dart:typed_data';

import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/task_cancellation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends Fake implements InferenceModelSession {
  final response = Completer<String>();
  final decoding = Completer<void>();
  Completer<void>? stopGate;
  int stops = 0, closes = 0;
  @override
  Future<int> sizeInTokens(String text) async => 10;
  @override
  Future<void> addQueryChunk(Message message) async {}
  @override
  Future<String> getResponse() {
    decoding.complete();
    return response.future;
  }

  @override
  Future<void> stopGeneration() {
    stops++;
    if (!response.isCompleted) response.complete('Partial unvalidated output');
    return stopGate?.future ?? Future<void>.value();
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

class _Model extends Fake implements InferenceModel {
  _Model(this.preparedSessions);
  final List<_Session> preparedSessions;
  int created = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #createSession) {
      return Future<InferenceModelSession>.value(preparedSessions[created++]);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'native Stop reaches decoding outside lock, rejects queued work, then admits a fresh session',
    () async {
      final first = _Session();
      final fresh = _Session()..response.complete('Fresh response');
      final model = _Model([first, fresh]);
      final intelligence = LocalIntelligence.withModelForTesting(model);
      final running = intelligence.generate(
        'Synthetic instruction',
        'Synthetic request',
      );
      await first.decoding.future;
      final queued = intelligence.generate('Synthetic queued', 'Request');
      final runningCheck = expectLater(running, throwsA(isA<TaskCancelled>()));
      final queuedCheck = expectLater(queued, throwsA(isA<TaskCancelled>()));
      await intelligence.cancelGeneration().timeout(const Duration(seconds: 1));
      await runningCheck;
      await queuedCheck;
      expect(first.stops, 1);
      expect(first.closes, 1);
      expect(model.created, 1);
      expect(
        await intelligence.generate('New instruction', 'New request'),
        'Fresh response',
      );
      expect(fresh.closes, 1);
      expect(model.created, 2);
    },
  );
  test(
    'native session closes only after concurrent stop has settled',
    () async {
      final session = _Session()..stopGate = Completer<void>();
      final intelligence = LocalIntelligence.withModelForTesting(
        _Model([session]),
      );
      final pending = intelligence.generate('Synthetic', 'Synthetic');
      await session.decoding.future;
      final check = expectLater(pending, throwsA(isA<TaskCancelled>()));
      final stop = intelligence.cancelGeneration();
      await Future<void>.delayed(Duration.zero);
      expect(session.closes, 0);
      session.stopGate!.complete();
      await stop;
      await check;
      expect(session.closes, 1);
    },
  );
  test(
    'vision Stop discards partial transcription without starting a repair session',
    () async {
      final session = _Session();
      final model = _Model([session]);
      final intelligence = LocalIntelligence.withModelForTesting(model);
      final pending = intelligence.transcribeImage(
        Uint8List.fromList([1, 2, 3]),
      );
      await session.decoding.future;
      final check = expectLater(pending, throwsA(isA<TaskCancelled>()));
      await intelligence.cancelGeneration();
      await check;
      expect(session.stops, 1);
      expect(session.closes, 1);
      expect(model.created, 1);
    },
  );
}
