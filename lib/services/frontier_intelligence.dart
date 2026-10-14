import '../domain/frontier_models.dart';
import 'frontier_gateway.dart';
import 'local_intelligence.dart';

typedef IntelligenceGenerate =
    Future<String> Function(String instruction, String input);

/// Adapts a controller-owned generation closure to the shared intelligence
/// interface. A closure can check the current profile, selected model and saved
/// disclosure before each call without exposing its provider key here.
///
/// Planning, retrieval, web tools, validation and retries remain with the shared
/// agent controller. This adapter forwards text unchanged and executes no tools.
class DelegatingIntelligence implements Intelligence {
  DelegatingIntelligence({
    required IntelligenceGenerate generate,
    bool Function()? isAvailable,
    // Public argument names keep private credentials/callback fields private.
    // ignore: prefer_initializing_formals
  }) : _generate = generate,
       _isAvailable = isAvailable ?? _alwaysAvailable;

  final IntelligenceGenerate _generate;
  final bool Function() _isAvailable;
  static bool _alwaysAvailable() => true;

  @override
  bool get available => _isAvailable();

  @override
  Future<String> generate(String instruction, String input) async {
    if (!available) {
      throw const FrontierGatewayException(
        'The selected intelligence is unavailable.',
      );
    }
    return await _generate(instruction, input);
  }
}

/// Direct-provider implementation of the same interface used by local inference.
/// The caller must enforce saved disclosure, selected mode and profile ownership.
/// It may prefer [DelegatingIntelligence] when those checks must be re-evaluated
/// during each step of an agent run. There is no automatic provider fallback,
/// retry, JSON transformation, file access or separate cloud tool execution path.
class FrontierIntelligence implements Intelligence {
  FrontierIntelligence({
    required this.provider,
    required this.model,
    required String apiKey,
    FrontierGateway? gateway,
    // ignore: prefer_initializing_formals
  }) : _apiKey = apiKey,
       _gateway = gateway ?? FrontierGateway();

  final String provider, model;
  final String _apiKey;
  final FrontierGateway _gateway;

  @override
  bool get available =>
      FrontierModels.isValidProvider(provider) &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$').hasMatch(model) &&
      _apiKey.isNotEmpty &&
      _apiKey.length <= 4096 &&
      !RegExp(r'\s').hasMatch(_apiKey);

  @override
  Future<String> generate(String instruction, String input) async {
    if (!available) {
      throw const FrontierGatewayException(
        'Check the selected provider and model key.',
      );
    }
    return await _gateway.generate(
      endpoint: FrontierGateway.providerEndpoint(provider),
      provider: provider,
      model: model,
      apiKey: _apiKey,
      instruction: instruction,
      input: input,
    );
  }
}
