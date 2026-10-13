import 'dart:async';

import 'package:ayumitra/services/local_processing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('test.ayumitra/local-processing');

class _NativeProcessing {
  _NativeProcessing({this.beginResult = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          // The native gate accepts no health text, prompt, transcript or
          // patient metadata. Its complete protocol is begin/end alone.
          expect(call.arguments, isNull);
          if (call.method == 'begin') {
            beginEntered?.complete();
            if (beginError != null) throw beginError!;
            return beginGate == null ? beginResult : await beginGate!.future;
          }
          if (call.method == 'end') {
            endEntered?.complete();
            if (endGate != null) await endGate!.future;
            if (endError != null) throw endError!;
            return null;
          }
          throw MissingPluginException();
        });
  }

  final calls = <MethodCall>[];
  Object? beginResult;
  Exception? beginError, endError;
  Completer<bool>? beginGate;
  Completer<void>? beginEntered, endEntered, endGate;
  List<String> get methods => calls.map((call) => call.method).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test(
    'overlapping work shares one begin and ends only after the final owner',
    () async {
      final native = _NativeProcessing();
      final processing = LocalProcessing(channel: _channel, supported: true);
      final first = await processing.acquire();
      final second = await processing.acquire();
      expect(first.protected, isTrue);
      expect(second.protected, isTrue);
      expect(native.methods, ['begin']);
      await first.close();
      expect(native.methods, ['begin']);
      await second.close();
      expect(native.methods, ['begin', 'end']);
    },
  );

  test('concurrent acquisition waits for one pending native begin', () async {
    final native = _NativeProcessing()
      ..beginGate = Completer<bool>()
      ..beginEntered = Completer<void>();
    final processing = LocalProcessing(channel: _channel, supported: true);
    var completed = 0;
    Future<ProcessingLease> acquire() async {
      final lease = await processing.acquire();
      completed++;
      return lease;
    }

    final first = acquire();
    final second = acquire();
    final third = acquire();
    await native.beginEntered!.future;
    expect(native.methods, ['begin']);
    expect(completed, 0);
    native.beginGate!.complete(true);
    final leases = await Future.wait([first, second, third]);
    expect(completed, 3);
    expect(leases.every((lease) => lease.protected), isTrue);
    await leases.first.close();
    expect(native.methods, ['begin']);
    await Future.wait(leases.skip(1).map((lease) => lease.close()));
    expect(native.methods, ['begin', 'end']);
  });

  test(
    'closing a lease repeatedly or concurrently cannot release another owner',
    () async {
      final native = _NativeProcessing();
      final processing = LocalProcessing(channel: _channel, supported: true);
      final first = await processing.acquire();
      final second = await processing.acquire();
      await Future.wait([first.close(), first.close(), first.close()]);
      expect(native.methods, ['begin']);
      await second.close();
      await second.close();
      expect(native.methods, ['begin', 'end']);
      final next = await processing.acquire();
      expect(next.protected, isTrue);
      await first.close();
      expect(native.methods, ['begin', 'end', 'begin']);
      await next.close();
      expect(native.methods, ['begin', 'end', 'begin', 'end']);
    },
  );

  test('new work waits for the previous native end to finish', () async {
    final native = _NativeProcessing()
      ..endEntered = Completer<void>()
      ..endGate = Completer<void>();
    final processing = LocalProcessing(channel: _channel, supported: true);
    final first = await processing.acquire();
    final ending = first.close();
    await native.endEntered!.future;
    final next = processing.acquire();
    await Future<void>.delayed(Duration.zero);
    expect(native.methods, ['begin', 'end']);
    native.endGate!.complete();
    await ending;
    final second = await next;
    expect(native.methods, ['begin', 'end', 'begin']);
    native.endEntered = null;
    native.endGate = null;
    await second.close();
    expect(native.methods, ['begin', 'end', 'begin', 'end']);
  });

  test(
    'unsupported platforms acquire unprotected leases without native calls',
    () async {
      final native = _NativeProcessing();
      final processing = LocalProcessing(channel: _channel, supported: false);
      final leases = await Future.wait([
        processing.acquire(),
        processing.acquire(),
      ]);
      expect(leases.every((lease) => !lease.protected), isTrue);
      await Future.wait(leases.map((lease) => lease.close()));
      await leases.first.close();
      expect(native.calls, isEmpty);
    },
  );

  for (final result in <Object?>[false, null]) {
    test(
      'native begin $result cannot claim protection and is retryable later',
      () async {
        final native = _NativeProcessing(beginResult: result);
        final processing = LocalProcessing(channel: _channel, supported: true);
        final leases = await Future.wait([
          processing.acquire(),
          processing.acquire(),
        ]);
        expect(leases.every((lease) => !lease.protected), isTrue);
        await Future.wait(leases.map((lease) => lease.close()));
        expect(native.methods, ['begin']);
        native.beginResult = true;
        final retry = await processing.acquire();
        expect(retry.protected, isTrue);
        await retry.close();
        expect(native.methods, ['begin', 'begin', 'end']);
      },
    );
  }

  test(
    'native begin exception is contained and does not poison reacquisition',
    () async {
      final native = _NativeProcessing()
        ..beginError = PlatformException(code: 'synthetic-start-denied');
      final processing = LocalProcessing(channel: _channel, supported: true);
      final first = await processing.acquire();
      expect(first.protected, isFalse);
      await first.close();
      expect(native.methods, ['begin']);
      native.beginError = null;
      final second = await processing.acquire();
      expect(second.protected, isTrue);
      await second.close();
      expect(native.methods, ['begin', 'begin', 'end']);
    },
  );

  test(
    'native end exception is contained and the next work gets a fresh begin',
    () async {
      final native = _NativeProcessing()
        ..endError = PlatformException(code: 'synthetic-end-denied');
      final processing = LocalProcessing(channel: _channel, supported: true);
      final first = await processing.acquire();
      await first.close();
      await first.close();
      expect(native.methods, ['begin', 'end']);
      native.endError = null;
      final second = await processing.acquire();
      expect(second.protected, isTrue);
      await second.close();
      expect(native.methods, ['begin', 'end', 'begin', 'end']);
    },
  );
}
