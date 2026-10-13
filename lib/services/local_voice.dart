import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum VoiceMode { idle, pushToTalk, foregroundWake }

/// Foreground-only English speech control. Recognition is permitted only when
/// the native bridge confirms that it runs on this device. No remote fallback,
/// audio files, transcript persistence, or transcript logging exists here.
class LocalVoice extends ChangeNotifier with WidgetsBindingObserver {
  LocalVoice({
    required this.onCommand,
    this.channel = const MethodChannel('app.ayumitra/voice'),
    this.events = const EventChannel('app.ayumitra/voice_events'),
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final void Function(String command) onCommand;
  final MethodChannel channel;
  final EventChannel events;
  StreamSubscription<dynamic>? _subscription;
  Timer? _restartTimer, _armTimer, _duplicateTimer;
  bool _disposed = false, _foreground = true, _suspended = false;
  bool _starting = false, _accepting = false, _permissionGranted = false;
  bool _permissionPending = false, _pendingPushAfterPermission = false;
  int _generation = 0, _silentRestarts = 0;
  static int _nextStartId = DateTime.now().microsecondsSinceEpoch;
  int? _activeStartId;
  int? _lastFinalHash;
  VoiceMode mode = VoiceMode.idle;
  bool available = false, onDevice = false, listening = false;
  bool readyForSpeech = false;
  bool onDeviceChecked = false;
  bool wakeEnabled = false, wakeArmed = false, permissionDenied = false;
  String platform = '', partialText = '', status = '', failure = '';

  bool get suspended => _suspended || !_foreground;
  bool get _canWake => !_disposed && wakeEnabled && !suspended;

  Future<void> startPushToTalk() async {
    if (_disposed || suspended || _starting) return;
    await _cancelRecognition(clearArm: true);
    _lastFinalHash = null;
    _duplicateTimer?.cancel();
    mode = VoiceMode.pushToTalk;
    await _start();
  }

  Future<void> setWakeEnabled(bool enabled) async {
    if (_disposed) return;
    wakeEnabled = enabled;
    if (!enabled) {
      await stop();
      return;
    }
    mode = VoiceMode.foregroundWake;
    failure = '';
    if (!suspended && !listening) await _start();
    _changed();
  }

  /// Main combines its busy/profile/route conditions into this suspension flag.
  /// Push-to-talk does not resume automatically; explicitly enabled wake does.
  Future<void> suspend(bool value) async {
    if (_disposed || _suspended == value) return;
    _suspended = value;
    if (value) {
      await _cancelRecognition(clearArm: true);
      status = 'Voice paused';
    } else if (_canWake) {
      mode = VoiceMode.foregroundWake;
      await _start();
    }
    _changed();
  }

  Future<void> stop() async {
    if (_disposed) return;
    wakeEnabled = false;
    mode = VoiceMode.idle;
    await _cancelRecognition(clearArm: true);
    status = '';
    _changed();
  }

  Future<void> _start() async {
    if (_disposed ||
        suspended ||
        _starting ||
        listening ||
        mode == VoiceMode.idle) {
      return;
    }
    _starting = true;
    final generation = _generation;
    try {
      final capabilities = await channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      if (!_current(generation)) return;
      onDeviceChecked = true;
      onDevice = capabilities?['onDevice'] == true;
      available = capabilities?['available'] == true && onDevice;
      platform = capabilities?['platform'] is String
          ? capabilities!['platform'] as String
          : '';
      if (!available || !onDevice) {
        wakeEnabled = false;
        mode = VoiceMode.idle;
        failure = capabilities?['reason'] is String
            ? capabilities!['reason'] as String
            : 'English on-device speech recognition is unavailable.';
        return;
      }
      if (!_permissionGranted) {
        _permissionPending = true;
        final granted =
            await channel.invokeMethod<bool>('requestPermission') == true;
        _permissionPending = false;
        if (_disposed || _suspended || generation != _generation) return;
        _permissionGranted = granted;
        permissionDenied = !granted;
        if (!granted) {
          wakeEnabled = false;
          mode = VoiceMode.idle;
          failure =
              'Microphone and local speech permission are needed for voice.';
          return;
        }
        if (!_foreground) {
          _pendingPushAfterPermission = mode == VoiceMode.pushToTalk;
          return;
        }
      }
      _subscription ??= events.receiveBroadcastStream().listen(
        _event,
        onError: (Object _) =>
            _fatal('Local voice recognition stopped. Try again.'),
        onDone: () => _fatal('Local voice recognition stopped. Try again.'),
      );
      if (!_current(generation)) return;
      partialText = '';
      failure = '';
      readyForSpeech = false;
      listening = true;
      _accepting = true;
      _activeStartId = ++_nextStartId;
      status = 'Starting on-device speech…';
      _changed();
      await channel.invokeMethod<void>('start', {'sessionId': _activeStartId});
    } on MissingPluginException {
      onDeviceChecked = true;
      available = false;
      onDevice = false;
      _fatal('On-device voice is not available on this platform.');
    } catch (_) {
      _fatal('On-device voice could not start. Try again.');
    } finally {
      _permissionPending = false;
      _starting = false;
      if (_pendingPushAfterPermission &&
          _foreground &&
          !_suspended &&
          !_disposed) {
        _pendingPushAfterPermission = false;
        unawaited(_start());
      } else if (generation != _generation &&
          _canWake &&
          !listening &&
          _restartTimer == null) {
        _scheduleRestart();
      }
      _changed();
    }
  }

  bool _current(int generation) =>
      !_disposed && !suspended && generation == _generation;

  void _event(dynamic value) {
    if (_disposed ||
        !_accepting ||
        suspended ||
        value is! Map ||
        value['sessionId'] is! int ||
        value['sessionId'] != _activeStartId) {
      return;
    }
    final type = value['type'];
    if (type == 'ready') {
      readyForSpeech = true;
      status = mode == VoiceMode.foregroundWake
          ? (wakeArmed ? 'Listening for your command…' : 'Listening for “Ayu”…')
          : 'Listening on this device…';
      _changed();
      return;
    }
    if (type == 'partial') {
      partialText = value['text'] is String ? value['text'] as String : '';
      _changed();
      return;
    }
    if (type == 'error') {
      final code = (value['code'] is String ? value['code'] as String : '')
          .toLowerCase()
          .replaceAll(RegExp(r'[_\-\s]'), '');
      if (code == 'nospeech' || code == 'speechtimeout' || code == 'nomatch') {
        _silentRestarts = (_silentRestarts + 1).clamp(1, 4);
        unawaited(
          _finish(delay: Duration(milliseconds: 250 * (1 << _silentRestarts))),
        );
      } else if (code == 'languageunavailable' ||
          code == 'languagenotsupported') {
        final reason = value['reason'] is String
            ? (value['reason'] as String).trim()
            : '';
        _fatal(
          reason.isNotEmpty && reason.length <= 240
              ? reason
              : 'English on-device speech recognition is unavailable.',
        );
      } else {
        _fatal(
          'Local voice recognition stopped. Check on-device speech setup and try again.',
        );
      }
      return;
    }
    if (type == 'stopped') {
      unawaited(_finish());
      return;
    }
    if (type != 'final') return;
    _accepting = false; // Reject duplicate final/stopped events from this run.
    final text = value['text'] is String
        ? (value['text'] as String).trim()
        : '';
    final hash = text.toLowerCase().hashCode;
    if (text.isNotEmpty && hash != _lastFinalHash) {
      _lastFinalHash = hash;
      _duplicateTimer?.cancel();
      _duplicateTimer = Timer(
        const Duration(seconds: 2),
        () => _lastFinalHash = null,
      );
      _silentRestarts = 0;
      if (mode == VoiceMode.pushToTalk) {
        _dispatch(text);
      } else if (mode == VoiceMode.foregroundWake) {
        final wake = RegExp(
          // Ayu (aa-yuh) must lead the utterance as a whole name. An
          // optional Hey is accepted; generic "are you" is not a wake name.
          r'^(?:hey\s+)?(?:a{1,2}yuh?|(?:aa|ah)[\s–—-]+yuh?)\b',
          caseSensitive: false,
        ).firstMatch(text.replaceAll(RegExp(r'[,.:;!?]'), ' '));
        if (wake != null) {
          // Punctuation replacement preserves offsets for stripping the prefix.
          final command = text
              .substring(wake.end)
              .replaceFirst(RegExp(r'^[\s,.:;!?]+'), '')
              .trim();
          if (command.isEmpty) {
            wakeArmed = true;
            _armTimer?.cancel();
            _armTimer = Timer(const Duration(seconds: 30), () {
              wakeArmed = false;
              if (_canWake) status = 'Listening for “Ayu”…';
              _changed();
            });
          } else {
            _clearArm();
            _dispatch(command);
          }
        } else if (wakeArmed) {
          _clearArm();
          _dispatch(text);
        }
      }
    }
    unawaited(_finish());
  }

  void _dispatch(String command) {
    try {
      onCommand(command);
    } catch (_) {
      failure = 'The voice command could not be handled. Please try typing it.';
    }
  }

  Future<void> _finish({
    Duration delay = const Duration(milliseconds: 150),
  }) async {
    _accepting = false;
    _activeStartId = null;
    listening = false;
    readyForSpeech = false;
    partialText = '';
    final generation = _generation;
    await _nativeStop();
    if (!_current(generation)) return;
    if (_canWake) {
      mode = VoiceMode.foregroundWake;
      status = 'Foreground voice will resume shortly…';
      _scheduleRestart(delay);
    } else {
      mode = VoiceMode.idle;
      status = '';
    }
    _changed();
  }

  void _scheduleRestart([Duration delay = const Duration(milliseconds: 150)]) {
    if (!_canWake || _restartTimer != null) return;
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      if (_canWake) unawaited(_start());
    });
  }

  Future<void> _cancelRecognition({required bool clearArm}) async {
    _generation++;
    _activeStartId = null;
    _permissionPending = false;
    _pendingPushAfterPermission = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _accepting = false;
    listening = false;
    readyForSpeech = false;
    partialText = '';
    if (clearArm) _clearArm();
    await _nativeStop();
    _changed();
  }

  Future<void> _nativeStop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } catch (_) {
      /* An unavailable bridge cannot start a remote fallback. */
    }
  }

  void _clearArm() {
    wakeArmed = false;
    _armTimer?.cancel();
    _armTimer = null;
  }

  void _fatal(String message) {
    if (_disposed) return;
    _permissionGranted = false;
    wakeEnabled = false;
    mode = VoiceMode.idle;
    failure = message;
    unawaited(_cancelRecognition(clearArm: true));
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      // The permission sheet temporarily makes the app inactive before any
      // microphone starts. Keep that pending request, but never start offscreen.
      if (!_permissionPending) unawaited(_cancelRecognition(clearArm: true));
      status = 'Voice paused';
    } else if (_pendingPushAfterPermission && !_suspended) {
      _pendingPushAfterPermission = false;
      unawaited(_start());
    } else if (_canWake) {
      mode = VoiceMode.foregroundWake;
      unawaited(_start());
    }
    _changed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _accepting = false;
    _activeStartId = null;
    _permissionPending = false;
    listening = false;
    readyForSpeech = false;
    partialText = '';
    _restartTimer?.cancel();
    _armTimer?.cancel();
    _duplicateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    unawaited(_nativeStop());
    super.dispose();
  }
}
