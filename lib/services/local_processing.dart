import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';

/// Keeps only active local work alive. No health text enters the native bridge.
class LocalProcessing {
  LocalProcessing({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('app.ayumitra/processing'),
      supported = supported ?? (!kIsWeb && Platform.isAndroid);
  final MethodChannel _channel;
  final bool supported;
  final _lock = Lock();
  int _owners = 0;
  bool _active = false;

  Future<ProcessingLease> acquire() => _lock.synchronized(() async {
    if (!supported) return ProcessingLease._(() async {}, false);
    if (_owners == 0) {
      try {
        _active = await _channel.invokeMethod<bool>('begin') ?? false;
      } catch (_) {
        _active = false;
      }
    }
    _owners++;
    return ProcessingLease._(
      () => _lock.synchronized(() async {
        if (--_owners > 0) return;
        if (_active) {
          _active = false;
          try {
            // Serialize this with acquire: a late end must never stop a newer
            // task's begin while the previous platform call is still pending.
            await _channel.invokeMethod<void>('end');
          } catch (_) {}
        }
      }),
      _active,
    );
  });
}

class ProcessingLease {
  ProcessingLease._(this._release, this.protected);
  final Future<void> Function() _release;
  final bool protected;
  bool _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _release();
  }
}
