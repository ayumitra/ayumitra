import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../domain/records.dart';
import '../domain/second_opinion.dart';

/// An explicitly reviewed local copy followed, optionally, by a homepage open.
/// No prompt is included in the URL and no message is submitted to a provider.
class SecondOpinionScreen extends StatefulWidget {
  const SecondOpinionScreen({
    super.key,
    required this.controller,
    this.copyText,
    this.openProvider,
  });
  final AppController controller;
  final Future<void> Function(String)? copyText;
  final Future<bool> Function(Uri)? openProvider;
  @override
  State<SecondOpinionScreen> createState() => _SecondOpinionScreenState();
}

class _SecondOpinionScreenState extends State<SecondOpinionScreen> {
  AppController get c => widget.controller;
  late final TextEditingController text;
  late final SecondOpinionPack pack;
  late final Profile owner;
  bool reviewed = false;
  String? error, status;
  bool pending = false;

  @override
  void initState() {
    super.initState();
    owner = c.profile!;
    pack = c.secondOpinionPack();
    text = TextEditingController(text: pack.markdown);
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  bool get scopeMatches =>
      c.profile?.id == pack.profileId &&
      c.activeSession?.id == pack.sessionId &&
      c.activeSession?.profileId == pack.profileId &&
      pack.reportIds.every(
        (id) => c.data.reports.any(
          (r) => r.id == id && r.profileId == pack.profileId,
        ),
      );

  Future<void> _record(String target) async {
    await c.recordSecondOpinionExport(
      target: target,
      reportIds: pack.reportIds,
      profileId: pack.profileId,
      sessionId: pack.sessionId,
    );
  }

  Future<void> _act({String? target, Uri? url}) async {
    if (pending) {
      return;
    }
    if (!reviewed || text.text.trim().isEmpty) {
      setState(
        () => error =
            'Review the edited text and confirm your choice before copying or opening a provider.',
      );
      return;
    }
    if (!scopeMatches) {
      setState(
        () => error =
            'The profile, conversation, or source records changed. Return and rebuild this draft.',
      );
      return;
    }
    final draft = text.text;
    setState(() {
      pending = true;
      error = null;
      status = null;
    });
    var copied = false;
    var copyRecorded = false;
    var opened = false;
    try {
      if (widget.copyText != null) {
        await widget.copyText!(draft);
      } else {
        await Clipboard.setData(ClipboardData(text: draft));
      }
      copied = true;
      if (!scopeMatches) {
        if (mounted) {
          setState(
            () => error =
                'The draft was copied, but the active conversation changed. No provider was opened or new export record confirmed. Return and rebuild the draft.',
          );
        }
        return;
      }
      await _record('copy');
      copyRecorded = true;
      if (url == null) {
        if (mounted) {
          setState(
            () => status =
                'Draft copied and the copy recorded locally. No message was sent. Paste only where you choose.',
          );
        }
        return;
      }
      if (!scopeMatches) {
        if (mounted) {
          setState(
            () => error =
                'The draft was copied and recorded, but the active conversation changed. No provider was opened.',
          );
        }
        return;
      }
      opened = widget.openProvider != null
          ? await widget.openProvider!(url)
          : await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened) {
        if (mounted) {
          setState(
            () => error =
                'The draft was copied and recorded, but the browser could not open. Paste it manually if you choose. No message was sent.',
          );
        }
        return;
      }
      await _record(target!);
      if (mounted) {
        setState(
          () => status =
              'Provider homepage opened; the draft is on your clipboard. These actions were recorded locally. Paste and send there only if you choose. No message was sent by Ayumitra.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = !copied
              ? 'Could not copy to the clipboard. No provider was opened or copy recorded.'
              : opened
              ? 'The homepage opened and the draft was copied, but its local action record could not be confirmed. No message was sent by Ayumitra.'
              : !copyRecorded
              ? 'The draft was copied, but its local copy record could not be confirmed. No provider was opened.'
              : 'The draft was copied and recorded, but the browser could not open. No message was sent.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => pending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hints = identifierHints(text.text, owner);
    return PopScope(
      canPop: !pending,
      child: Scaffold(
        appBar: AppBar(title: const Text('Prepare a second opinion')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'This text-only draft is not anonymized and may contain identifying details. No photos or attachments are included. Review and edit it before copying. Clipboard contents may be available to other apps or synced by your device. Opening ChatGPT or Claude opens only its homepage; you decide whether to paste and send there. Ayumitra does not submit the draft.',
            ),
            const SizedBox(height: 8),
            if (hints.isNotEmpty)
              Text(
                'Possible identifiers: ${hints.join(', ')}. These checks are incomplete; review all text.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (pack.truncated)
              const Text(
                'Some content was omitted or shortened. Recent requests and source excerpts were prioritized; check the full conversation and originals.',
              ),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              enabled: !pending,
              minLines: 10,
              maxLines: 18,
              onChanged: (_) => setState(() {
                reviewed = false;
                error = null;
                status = null;
              }),
              decoration: const InputDecoration(
                labelText: 'Draft to copy (editable)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              title: const Text(
                'I reviewed this text and choose to copy/share it',
              ),
              value: reviewed,
              onChanged: pending
                  ? null
                  : (v) => setState(() => reviewed = v ?? false),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (status != null) Text(status!),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: pending ? null : () => _act(),
              icon: const Icon(Icons.copy_outlined),
              label: Text(pending ? 'Working…' : 'Copy draft'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: pending
                        ? null
                        : () => _act(
                            target: 'chatgpt',
                            url: Uri.parse('https://chatgpt.com/'),
                          ),
                    icon: const Icon(Icons.open_in_new_outlined),
                    label: const Text('Open ChatGPT'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: pending
                        ? null
                        : () => _act(
                            target: 'claude',
                            url: Uri.parse('https://claude.ai/'),
                          ),
                    icon: const Icon(Icons.open_in_new_outlined),
                    label: const Text('Open Claude'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
