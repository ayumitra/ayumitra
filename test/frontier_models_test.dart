// Frontier-model configuration checks. No keys, no network.
import 'package:ayumitra/domain/frontier_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('human-specified provider defaults', () {
    expect(FrontierModels.defaultOpenAiModel, 'gpt-6-luna');
    expect(FrontierModels.defaultClaudeModel, 'claude-haiku-5-5');
    expect(
      FrontierModels.defaultModelFor(FrontierModels.openAiProvider),
      'gpt-6-luna',
    );
    expect(
      FrontierModels.defaultModelFor(FrontierModels.anthropicProvider),
      'claude-haiku-5-5',
    );
  });

  test('provider validation accepts only the two supported providers', () {
    expect(FrontierModels.isValidProvider('openai'), isTrue);
    expect(FrontierModels.isValidProvider('anthropic'), isTrue);
    expect(FrontierModels.isValidProvider('litellm'), isFalse);
    expect(FrontierModels.isValidProvider(null), isFalse);
    expect(FrontierModels.isValidProvider(''), isFalse);
  });

  test('model validation rejects blank input only', () {
    expect(FrontierModels.validateModel('gpt-6-luna'), isNull);
    expect(FrontierModels.validateModel('  '), isNotNull);
    expect(FrontierModels.validateModel(null), isNotNull);
  });
}
