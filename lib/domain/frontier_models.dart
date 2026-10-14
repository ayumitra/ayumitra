/// Optional frontier-model access (human request). Local-first stays the
/// default: nothing uses these keys unless the user explicitly submits text
/// to a cloud model. Keys live in platform secure storage only — never in
/// the encrypted vault, logs, or exports.
///
/// Human-specified defaults: GPT-6 Luna and Claude Haiku 5.5, using their
/// official API identifiers. Requests go directly to the selected provider;
/// this file contains configuration and validation only, no network.
class FrontierModels {
  const FrontierModels._();

  static const openAiProvider = 'openai';
  static const anthropicProvider = 'anthropic';
  static const providers = [openAiProvider, anthropicProvider];

  static const defaultOpenAiModel = 'gpt-6-luna';
  static const defaultClaudeModel = 'claude-haiku-5-5';

  static const openAiKeyRef = 'ayumitra-frontier-openai-key';
  static const anthropicKeyRef = 'ayumitra-frontier-anthropic-key';
  static const providerRef = 'ayumitra-frontier-provider';
  static const modelRef = 'ayumitra-frontier-model';
  // Legacy development setting; mobile requests never read or use it.
  static const gatewayRef = 'ayumitra-frontier-gateway';
  static const disclosureRef = 'ayumitra-frontier-disclosure-v1';
  static const chatModeRef = 'ayumitra-frontier-chat-mode';

  /// Master remote-AI switch. Off by default: with local chat selected,
  /// nothing leaves the device even when provider keys are saved. Cloud mode
  /// and cloud dispatch both require this to be enabled first.
  static const remoteAiRef = 'ayumitra-frontier-remote-ai';

  static String defaultModelFor(String provider) => switch (provider) {
    anthropicProvider => defaultClaudeModel,
    _ => defaultOpenAiModel,
  };

  static String providerLabel(String provider) => switch (provider) {
    anthropicProvider => 'Anthropic Claude',
    _ => 'OpenAI',
  };

  static bool isValidProvider(String? provider) =>
      provider == openAiProvider || provider == anthropicProvider;

  /// Model ids are provider-opaque; only blank input is rejected here.
  static String? validateModel(String? model) {
    if (model == null || model.trim().isEmpty) {
      return 'Enter a model id, or keep the default.';
    }
    return null;
  }
}
