import 'dart:async';

import 'package:flutter/services.dart';

enum ModelRole { assistant, embedding }

class DefaultModel {
  const DefaultModel(
    this.role,
    this.name,
    this.filename,
    this.bytes,
    this.sha256,
  );
  final ModelRole role;
  final String name, filename, sha256;
  final int bytes;

  static const assistant = DefaultModel(
    ModelRole.assistant,
    'Gemma 4',
    'gemma-4-E2B-it.litertlm',
    2588147712,
    '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
  );
  static const embedding = DefaultModel(
    ModelRole.embedding,
    'EmbeddingGemma 2',
    'embeddinggemma-2-text-270m.litertlm',
    164626432,
    '2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb',
  );
}

/// Metadata only. No report, conversation, URL or prompt crosses this channel.
class ModelSetupProgress {
  const ModelSetupProgress(this.model, this.state, this.downloadedBytes);
  final DefaultModel model;
  final String state;
  final int downloadedBytes;
  double? get fraction => state == 'downloading' || state == 'queued'
      ? downloadedBytes / model.bytes
      : null;
  String get label => switch (state) {
    'ready' => '${model.name} ready on this device',
    'activating' => 'Loading ${model.name} on this device…',
    'verifying' => 'Checking ${model.name}…',
    'queued' => 'Waiting to download ${model.name}…',
    'failed' => '${model.name} setup could not finish. Please retry.',
    _ => 'Downloading ${model.name}…',
  };
}

class VerifiedModel {
  const VerifiedModel(this.model, this.path);
  final DefaultModel model;
  final String path;
}

typedef ModelSetupCall =
    Future<Map<Object?, Object?>> Function(
      String method,
      Map<String, Object> arguments,
    );

/// Android owns resumable downloads and verifies immutable public weights.
/// Dart polls while alive; cancelling polling never cancels the OS download.
class AutomaticModels {
  AutomaticModels({
    ModelSetupCall? call,
    this.pollInterval = const Duration(seconds: 1),
  }) : _call = call ?? _nativeCall;
  static const _channel = MethodChannel('app.ayumitra/model_setup');
  final ModelSetupCall _call;
  final Duration pollInterval;
  static Future<Map<Object?, Object?>> _nativeCall(
    String method,
    Map<String, Object> arguments,
  ) async =>
      await _channel.invokeMapMethod<Object?, Object?>(method, arguments) ??
      (throw const FormatException('Missing model setup state.'));

  Future<VerifiedModel> prepare(
    DefaultModel model, {
    required String supportPath,
    required void Function(ModelSetupProgress) onProgress,
    required bool Function() cancelled,
  }) async {
    var method = 'ensure';
    while (!cancelled()) {
      final raw = await _call(method, {'role': model.role.name});
      if (cancelled()) throw StateError('Model setup closed.');
      final state = raw['state'];
      final downloaded = raw['downloadedBytes'];
      if (raw['role'] != model.role.name ||
          raw['totalBytes'] != model.bytes ||
          state is! String ||
          !{
            'ready',
            'downloading',
            'queued',
            'verifying',
            'failed',
          }.contains(state) ||
          downloaded is! int ||
          downloaded < 0 ||
          downloaded > model.bytes) {
        throw const FormatException('Invalid model setup state.');
      }
      onProgress(ModelSetupProgress(model, state, downloaded));
      if (state == 'ready') {
        final expectedPath = '$supportPath/ayumitra-models/${model.filename}';
        if (raw['path'] != expectedPath || raw['sha256'] != model.sha256) {
          throw const FormatException('Unverified local model path.');
        }
        return VerifiedModel(model, expectedPath);
      }
      if (state == 'failed') throw StateError('Model download unavailable.');
      method = 'status';
      await Future<void>.delayed(pollInterval);
    }
    throw StateError('Model setup closed.');
  }
}
