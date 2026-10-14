import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/frontier_models.dart';

/// Saving a credential only configures explicitly selected cloud chat.
class FrontierSettings extends StatefulWidget {
  const FrontierSettings({super.key, required this.controller});
  final AppController controller;

  @override
  State<FrontierSettings> createState() => _FrontierSettingsState();
}

class _FrontierSettingsState extends State<FrontierSettings> {
  final keyInput = TextEditingController();
  late final TextEditingController modelInput;
  late String provider;
  String? feedback;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    provider = c.frontierProvider;
    modelInput = TextEditingController(text: c.frontierModel);
  }

  @override
  void dispose() {
    keyInput.dispose();
    modelInput.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final c = widget.controller;
    if (keyInput.text.trim().isEmpty || c.busy || c.isPreview || saving) return;
    final chosen = provider;
    final model = modelInput.text.trim();
    if (FrontierModels.validateModel(model) != null) {
      setState(() => feedback = 'Enter a model id before saving.');
      return;
    }
    final credential = keyInput.text;
    // Do not retain a secret in the form after submission, including failures.
    keyInput.clear();
    setState(() {
      saving = true;
      feedback = null;
    });
    try {
      await c.setFrontierKey(chosen, credential);
      if (c.failure == null && c.frontierKeySavedFor(chosen)) {
        await c.setFrontierModel(chosen, model);
      }
      if (!mounted) return;
      setState(
        () => feedback = c.failure == null && c.frontierKeySavedFor(chosen)
            ? 'API key saved on this device. Choose the cloud model in chat to use it.'
            : 'Could not confirm the saved settings. Enter the key again to retry.',
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _saveModel() async {
    final c = widget.controller;
    if (c.busy || c.isPreview || saving) return;
    setState(() {
      saving = true;
      feedback = null;
    });
    try {
      await c.setFrontierModel(provider, modelInput.text);
      if (mounted) {
        setState(
          () =>
              feedback = c.failure == null ? 'Provider and model saved.' : null,
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _clearKey() async {
    final c = widget.controller;
    if (c.busy || c.isPreview || saving) return;
    setState(() {
      saving = true;
      feedback = null;
    });
    try {
      await c.clearFrontierKey(provider);
      if (mounted) {
        setState(
          () => feedback = c.failure == null
              ? 'API key removed from this device.'
              : null,
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final configured = c.frontierKeySavedFor(provider);
      final disabled = c.busy || c.isPreview || saving;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Frontier models (optional)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const Key('frontier-remote-ai'),
            title: const Text('Remote AI'),
            subtitle: const Text(
              'Allow cloud models. Off by default. In Local mode your health '
              'context stays on this device; public web searches still contact the search provider.',
            ),
            value: c.allowRemoteAi,
            onChanged: c.isPreview || (c.busy && !c.allowRemoteAi)
                ? null
                : (next) async {
                    await c.setAllowRemoteAi(next);
                    if (mounted) setState(() {});
                  },
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cloud privacy warning: when you select a cloud model in chat, your messages and selected profile context leave this device. A one-time warning appears before first use. Your selected OpenAI or Anthropic provider receives them directly, including any health details. No separate server setup is needed. Provider retention policies apply. Saving a key does not enable cloud fallback or send anything.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(configured ? Icons.key_outlined : Icons.key_off_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  configured
                      ? 'Key saved on this device for ${FrontierModels.providerLabel(provider)}'
                      : 'No key saved for ${FrontierModels.providerLabel(provider)}',
                ),
              ),
              if (configured)
                TextButton(
                  onPressed: disabled ? null : _clearKey,
                  child: const Text('Remove'),
                ),
            ],
          ),
          DropdownButtonFormField<String>(
            key: const Key('frontier-provider'),
            initialValue: FrontierModels.isValidProvider(provider)
                ? provider
                : FrontierModels.openAiProvider,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: FrontierModels.providers
                .map(
                  (p) => DropdownMenuItem(
                    value: p,
                    child: Text(FrontierModels.providerLabel(p)),
                  ),
                )
                .toList(),
            onChanged: disabled
                ? null
                : (next) {
                    if (next == null) return;
                    setState(() {
                      provider = next;
                      modelInput.text = next == c.frontierProvider
                          ? c.frontierModel
                          : FrontierModels.defaultModelFor(next);
                      keyInput.clear();
                      feedback = null;
                    });
                  },
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('frontier-model'),
            controller: modelInput,
            enabled: !disabled,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Model',
              helperText:
                  'Defaults: ${FrontierModels.defaultOpenAiModel} / ${FrontierModels.defaultClaudeModel}',
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() => feedback = null),
          ),
          TextButton(
            onPressed: disabled ? null : _saveModel,
            child: const Text('Save provider and model'),
          ),
          TextField(
            key: const Key('frontier-api-key'),
            controller: keyInput,
            obscureText: true,
            enabled: !disabled,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: const InputDecoration(
              labelText: 'API key',
              helperText: 'Stored in this device’s secure storage.',
            ),
            onChanged: (_) => setState(() => feedback = null),
          ),
          TextButton(
            onPressed: disabled || keyInput.text.trim().isEmpty
                ? null
                : _saveKey,
            child: const Text('Save API key'),
          ),
          const SizedBox(height: 8),
          if (c.busy && c.activity.isNotEmpty) Text(c.activity),
          if (feedback != null) Text(feedback!),
          if (c.failure != null)
            Text(
              c.failure!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
