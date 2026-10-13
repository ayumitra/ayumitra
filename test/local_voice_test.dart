import 'dart:async';

import 'package:ayumitra/services/local_voice.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeVoice {
  _NativeVoice({
    this.available = true,
    this.onDevice = true,
    this.permission = true,
  }) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('app.ayumitra/voice'),
      (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'capabilities':
            return {
              'available': available,
              'onDevice': onDevice,
              'platform': 'test',
            };
          case 'requestPermission':
            return permissionGate?.future ?? permission;
          case 'start':
            startIds.add((call.arguments as Map)['sessionId'] as int);
            return null;
          case 'stop':
            return null;
          default:
            throw MissingPluginException();
        }
      },
    );
    messenger.setMockStreamHandler(
      const EventChannel('app.ayumitra/voice_events'),
      MockStreamHandler.inline(onListen: (_, events) => sink = events),
    );
  }
  bool available, onDevice, permission;
  Completer<bool>? permissionGate;
  final calls = <String>[];
  final startIds = <int>[];
  MockStreamHandlerEventSink? sink;
  int get starts => calls.where((call) => call == 'start').length;
  void emit(
    String type, {
    String? text,
    String? code,
    String? reason,
    int? sessionId,
  }) => sink!.success({
    'type': type,
    'sessionId': sessionId ?? startIds.last,
    'text': ?text,
    'code': ?code,
    'reason': ?reason,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void scenario(
    void Function(FakeAsync, _NativeVoice, LocalVoice, List<String>) run, {
    bool available = true,
    bool onDevice = true,
    bool permission = true,
  }) {
    fakeAsync((time) {
      final native = _NativeVoice(
        available: available,
        onDevice: onDevice,
        permission: permission,
      );
      final commands = <String>[];
      final voice = LocalVoice(onCommand: commands.add);
      try {
        run(time, native, voice, commands);
      } finally {
        voice.dispose();
        time.flushMicrotasks();
      }
    });
  }

  void startWake(FakeAsync time, LocalVoice voice) {
    unawaited(voice.setWakeEnabled(true));
    time.flushMicrotasks();
  }

  void nextRun(FakeAsync time) {
    time.flushMicrotasks();
    time.elapse(const Duration(milliseconds: 150));
    time.flushMicrotasks();
  }

  test('unavailable recognition refuses permission and start', () {
    scenario((time, native, voice, commands) {
      startWake(time, voice);
      expect(native.calls, contains('capabilities'));
      expect(native.calls, isNot(contains('requestPermission')));
      expect(native.starts, 0);
      expect(voice.available, isFalse);
      expect(voice.onDeviceChecked, isTrue);
      expect(voice.wakeEnabled, isFalse);
    }, available: false);
  });
  test(
    'a cloud-capable recognizer is refused without a device-only guarantee',
    () {
      scenario((time, native, voice, commands) {
        startWake(time, voice);
        expect(native.calls, isNot(contains('requestPermission')));
        expect(native.starts, 0);
        expect(voice.available, isFalse);
        expect(commands, isEmpty);
      }, onDevice: false);
    },
  );
  test('permission denial does not start the microphone', () {
    scenario((time, native, voice, commands) {
      unawaited(voice.startPushToTalk());
      time.flushMicrotasks();
      expect(native.calls, contains('requestPermission'));
      expect(native.starts, 0);
      expect(voice.permissionDenied, isTrue);
    }, permission: false);
  });
  test('push-to-talk echoes partial text and dispatches one final', () {
    scenario((time, native, voice, commands) {
      unawaited(voice.startPushToTalk());
      time.flushMicrotasks();
      native.emit('partial', text: 'Find my blood');
      time.flushMicrotasks();
      expect(voice.partialText, 'Find my blood');
      expect(commands, isEmpty);
      native.emit('final', text: 'Find my blood reports');
      native.emit('final', text: 'Find my blood reports');
      native.emit('stopped');
      time.flushMicrotasks();
      expect(commands, ['Find my blood reports']);
      expect(voice.partialText, isEmpty);
      expect(voice.listening, isFalse);
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();
      expect(native.starts, 1);
    });
  });
  test(
    'wake mode ignores non-wake speech and strips only a leading exact phrase',
    () {
      scenario((time, native, voice, commands) {
        startWake(time, voice);
        for (final ignored in [
          'Find my reports',
          'Please hey Ayumitra find reports',
          'Hey Ayumitraville find reports',
        ]) {
          native.emit('final', text: ignored);
          nextRun(time);
        }
        expect(commands, isEmpty);
        native.emit('final', text: 'Hey, Ayumitra: Find my reports');
        nextRun(time);
        native.emit('final', text: 'hey ayu mitra show my medicines');
        time.flushMicrotasks();
        expect(commands, ['Find my reports', 'show my medicines']);
      });
    },
  );
  test('wake-only phrase arms one command and expires after 30 seconds', () {
    scenario((time, native, voice, commands) {
      startWake(time, voice);
      native.emit('final', text: 'Hey Ayumitra');
      nextRun(time);
      expect(voice.wakeArmed, isTrue);
      native.emit('final', text: 'Find my report');
      nextRun(time);
      expect(commands, ['Find my report']);
      expect(voice.wakeArmed, isFalse);
      native.emit('final', text: 'Hey Ayu Mitra');
      nextRun(time);
      expect(voice.wakeArmed, isTrue);
      time.elapse(const Duration(seconds: 30));
      time.flushMicrotasks();
      expect(voice.wakeArmed, isFalse);
      native.emit('final', text: 'This must not be a command');
      time.flushMicrotasks();
      expect(commands, ['Find my report']);
    });
  });
  test(
    'busy suspension and app inactivity cancel commands and pending restart',
    () {
      scenario((time, native, voice, commands) {
        startWake(time, voice);
        native.emit('stopped');
        time.flushMicrotasks();
        unawaited(voice.suspend(true));
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 5));
        time.flushMicrotasks();
        native.emit('final', text: 'Hey Ayumitra send this');
        time.flushMicrotasks();
        expect(native.starts, 1);
        expect(commands, isEmpty);
        unawaited(voice.suspend(false));
        time.flushMicrotasks();
        expect(native.starts, 2);
        voice.didChangeAppLifecycleState(AppLifecycleState.inactive);
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 5));
        time.flushMicrotasks();
        expect(native.starts, 2);
        unawaited(voice.stop());
        time.flushMicrotasks();
        voice.didChangeAppLifecycleState(AppLifecycleState.resumed);
        time.flushMicrotasks();
        expect(native.starts, 2);
      });
    },
  );
  test(
    'permission grant while suspended does not start, dialog resume can start push-to-talk',
    () {
      scenario((time, native, voice, commands) {
        native.permissionGate = Completer<bool>();
        unawaited(voice.startPushToTalk());
        time.flushMicrotasks();
        voice.didChangeAppLifecycleState(AppLifecycleState.inactive);
        native.permissionGate!.complete(true);
        time.flushMicrotasks();
        expect(native.starts, 0);
        voice.didChangeAppLifecycleState(AppLifecycleState.resumed);
        time.flushMicrotasks();
        expect(native.starts, 1);
        expect(voice.listening, isTrue);
      });
    },
  );
  test('busy suspension invalidates a pending permission grant', () {
    scenario((time, native, voice, commands) {
      native.permissionGate = Completer<bool>();
      startWake(time, voice);
      unawaited(voice.suspend(true));
      time.flushMicrotasks();
      native.permissionGate!.complete(true);
      time.flushMicrotasks();
      expect(native.starts, 0);
    });
  });
  test(
    'no-speech uses bounded backoff while other errors stop without fallback',
    () {
      scenario((time, native, voice, commands) {
        startWake(time, voice);
        native.emit('error', code: 'no_speech');
        time.flushMicrotasks();
        time.elapse(const Duration(milliseconds: 499));
        time.flushMicrotasks();
        expect(native.starts, 1);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(native.starts, 2);
        native.emit('error', code: 'noSpeech');
        time.flushMicrotasks();
        time.elapse(const Duration(milliseconds: 999));
        time.flushMicrotasks();
        expect(native.starts, 2);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(native.starts, 3);
        native.emit('error', code: 'network');
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 30));
        time.flushMicrotasks();
        expect(native.starts, 3);
        expect(voice.wakeEnabled, isFalse);
      });
    },
  );

  test(
    'final events from a cancelled native session cannot reach a new session',
    () {
      scenario((time, native, voice, commands) {
        startWake(time, voice);
        final oldId = native.startIds.last;
        unawaited(voice.stop());
        time.flushMicrotasks();
        startWake(time, voice);
        expect(native.startIds.last, isNot(oldId));
        native.emit(
          'final',
          text: 'Hey Ayumitra old profile command',
          sessionId: oldId,
        );
        time.flushMicrotasks();
        expect(commands, isEmpty);
        expect(voice.listening, isTrue);
        native.emit('final', text: 'Hey Ayumitra current command');
        time.flushMicrotasks();
        expect(commands, ['current command']);
      });
    },
  );

  test(
    'NO_MATCH restarts wake while an English model error is shown without fallback',
    () {
      scenario((time, native, voice, commands) {
        startWake(time, voice);
        native.emit('error', code: 'NO_MATCH');
        time.flushMicrotasks();
        time.elapse(const Duration(milliseconds: 500));
        time.flushMicrotasks();
        expect(native.starts, 2);
        native.emit(
          'error',
          code: 'LANGUAGE_UNAVAILABLE',
          reason: 'Download the English on-device speech model.',
        );
        time.flushMicrotasks();
        expect(voice.failure, 'Download the English on-device speech model.');
        expect(voice.wakeEnabled, isFalse);
        time.elapse(const Duration(seconds: 10));
        time.flushMicrotasks();
        expect(native.starts, 2);
      });
    },
  );
}
