import 'package:flutter/material.dart';

import '../app_controller.dart';

/// Reusable native public-search settings section for an [AppController].
///
/// The stored key itself is never read here: only
/// `controller.webSearch.available` (configured, not verified) drives the
/// status, and the input field always starts blank so a saved key is never
/// populated into it. Save stays disabled for empty/whitespace input and
/// while the controller is busy, so a blank save can never erase an
/// existing key. Success feedback appears only when the write finished with
/// `controller.failure == null` and the key reports available; otherwise the
/// typed input is kept and no success is shown.
class WebSearchSettings extends StatefulWidget {
  const WebSearchSettings({super.key, required this.controller});

  final AppController controller;

  @override
  State<WebSearchSettings> createState() => _WebSearchSettingsState();
}

class _WebSearchSettingsState extends State<WebSearchSettings> {
  final input = TextEditingController();
  bool savedFeedback = false;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.controller;
    final text = input.text;
    if (text.trim().isEmpty || c.busy || c.isPreview) return;
    savedFeedback = false;
    await c.setWebKey(text);
    if (!mounted) return;
    if (c.failure == null && c.webSearch.available) {
      input.clear();
      setState(() => savedFeedback = true);
    } else {
      // Write failed: keep the typed input, show no success.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final configured = c.webSearch.available;
      final canSave = input.text.trim().isNotEmpty && !c.busy && !c.isPreview;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Public web search',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'The assistant can look up general information. '
            'Only public queries are sent; reports and conversations stay here.',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(configured ? Icons.key_outlined : Icons.key_off_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  configured
                      ? 'Search key saved on this device'
                      : 'No search key saved yet',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Used to authenticate your public searches with Brave.'),
          const SizedBox(height: 8),
          TextField(
            controller: input,
            obscureText: true,
            enabled: !c.busy && !c.isPreview,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              labelText: 'Brave Search API key',
              helperText: configured
                  ? 'Saved. Type a replacement to change it.'
                  : 'Stored in this device’s secure storage.',
            ),
            onChanged: (_) => setState(() => savedFeedback = false),
          ),
          const SizedBox(height: 8),
          if (c.busy && c.activity.isNotEmpty) Text(c.activity),
          TextButton(
            onPressed: canSave ? _save : null,
            child: const Text('Save search key'),
          ),
          if (savedFeedback && configured)
            const Text('Search key saved on this device.'),
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
