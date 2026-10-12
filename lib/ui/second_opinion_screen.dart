import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../domain/second_opinion.dart';

/// Explicit-tap export of the active conversation to an external AI.
///
/// Local-only build + user-reviewed preview. This screen never sends anything
/// itself: Copy puts the edited pack on the clipboard, and the ChatGPT/Claude
/// buttons open the provider site in an external browser where the user pastes
/// it themselves. The audit log stores target/date/report ids, never content.
class SecondOpinionScreen extends StatefulWidget {
  const SecondOpinionScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<SecondOpinionScreen> createState() => _SecondOpinionScreenState();
}

class _SecondOpinionScreenState extends State<SecondOpinionScreen> {
  AppController get c => widget.controller;
  late final TextEditingController text;
  late final SecondOpinionPack pack;
  final checks = <String, bool>{
    'Names removed or OK to share': false,
    'Birth dates removed or OK to share': false,
    'Addresses, phone numbers, IDs removed': false,
    'Photos / attachments reviewed': false,
    'I read the full text above': false,
  };
  String? error;
  bool sent = false;

  @override
  void initState() {
    super.initState();
    pack = c.secondOpinionPack();
    text = TextEditingController(text: pack.markdown);
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  bool get reviewed => checks.values.every((v) => v);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: text.text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Pack copied. Paste it wherever you choose.')));
    }
  }

  Future<void> _open(String target, Uri url) async {
    if (!reviewed) {
      setState(
        () => error = 'Check every review item first — nothing is sent until you confirm.',
      );
      return;
    }
    setState(() => error = null);
    await Clipboard.setData(ClipboardData(text: text.text));
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok) {
      if (mounted) {
        setState(
          () => error =
              'Could not open the browser. The pack is on your clipboard — paste it manually.',
        );
      }
      return;
    }
    await c.recordSecondOpinionExport(
      target: target,
      reportIds: pack.reportIds,
    );
    if (mounted) setState(() => sent = true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ask ChatGPT or Claude')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'This stays on your phone until you act. Review the text, then copy it or open ChatGPT/Claude and paste it there yourself. AyuMitra never contacts them.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 8),
        if (pack.identifierHints.isNotEmpty)
          Text(
            'Spotted (labels only): ${pack.identifierHints.join(', ')}. Remove anything you do not want to share.',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (pack.truncated)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Long conversation: oldest content was omitted (noted in the pack).',
              style: TextStyle(fontSize: 13),
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: text,
          minLines: 10,
          maxLines: 18,
          decoration: const InputDecoration(
            labelText: 'Pack to send (editable)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Review checklist',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        for (final entry in checks.entries)
          CheckboxListTile(
            title: Text(entry.key, style: const TextStyle(fontSize: 13)),
            value: entry.value,
            dense: true,
            onChanged: (v) =>
                setState(() => checks[entry.key] = v ?? false),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ),
        if (sent)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Recorded in your local export log (target + date only).',
              style: TextStyle(fontSize: 13),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('Copy pack'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _open(
                  'chatgpt',
                  Uri.parse('https://chatgpt.com/'),
                ),
                icon: const Icon(Icons.open_in_new_outlined),
                label: const Text('Open ChatGPT'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () =>
                    _open('claude', Uri.parse('https://claude.ai/')),
                icon: const Icon(Icons.open_in_new_outlined),
                label: const Text('Open Claude'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
