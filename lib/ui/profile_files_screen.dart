import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../domain/records.dart';
import '../services/web_llm.dart';

/// Per-profile uploaded-file library.
///
/// Lists every stored original for one immutable [profileId] — including
/// files that are still unprocessed or failed parsing, which are retained
/// with their import status instead of hidden. Entries are filtered by that
/// id AND the controller's active profile: if the active profile changes
/// while this route is open, a guard replaces the list so a stale route can
/// never expose another person's filenames.
///
/// Navigation stays with the caller: [onOpenReport] and [onOpenOriginal]
/// push the existing ReportScreen/SourceScreen, so this file never imports
/// app.dart and no import cycle is possible.
class ProfileFilesScreen extends StatefulWidget {
  const ProfileFilesScreen({
    super.key,
    required this.controller,
    required this.profileId,
    required this.onOpenReport,
    required this.onOpenOriginal,
  });

  final AppController controller;
  final String profileId;
  final void Function(Report report) onOpenReport;
  final void Function(Report report) onOpenOriginal;

  @override
  State<ProfileFilesScreen> createState() => _ProfileFilesScreenState();
}

/// Import/read status in plain words. Kept local (not imported from
/// app.dart) to avoid an import cycle with the companion screen.
String profileFileStatus(ReportStatus status) => switch (status) {
  ReportStatus.saved => 'Saved · not read yet',
  ReportStatus.processing => 'Reading locally',
  ReportStatus.needsReview => 'Needs review',
  ReportStatus.ready => 'Ready to review',
  ReportStatus.failed => 'Could not be read · original kept',
};

class _ProfileFilesScreenState extends State<ProfileFilesScreen> {
  final find = TextEditingController();
  String query = '';

  @override
  void dispose() {
    find.dispose();
    super.dispose();
  }

  String _dateLine(Report report) => report.eventDate == null
      ? 'Added ${DateFormat.yMMMd().format(report.importedAt)}'
      : DateFormat.yMMMd().format(report.eventDate!);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final owner = c.data.profiles
          .where((p) => p.id == widget.profileId)
          .firstOrNull;
      if (owner == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Files')),
          body: const Center(
            child: Text('This profile is no longer available.'),
          ),
        );
      }
      if (c.activeProfileId != widget.profileId) {
        // Stale route after a profile switch: names, types and dates stay
        // hidden; only the guard is shown.
        return Scaffold(
          appBar: AppBar(title: Text('${owner.name}’s files')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'You switched profiles. Go back and open this library again '
                'to see the current profile’s files.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }
      final all = timelineFor(widget.profileId, c.data.reports);
      final q = query.trim().toLowerCase();
      final files = q.isEmpty
          ? all
          : all.where((r) => r.name.toLowerCase().contains(q)).toList();
      return Scaffold(
        appBar: AppBar(title: Text('${owner.name}’s files')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              // The bridge sends report content to the dev Mac for inference,
              // so it must not reuse the production "nowhere else" promise.
              c.isPreview
                  ? 'Originals stay in this tab’s memory and clear on reload. Nothing is uploaded.'
                  : c.intelligence is WebIntelligence &&
                        c.embeddings is WebEmbeddings
                  ? 'Originals stay encrypted on this Android device. Report content goes only to your Mac’s localhost models for development testing — never to the cloud.'
                  : 'Originals stay encrypted on this device. Nothing is uploaded or copied elsewhere.',
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: find,
              decoration: const InputDecoration(
                labelText: 'Find by filename',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 12),
            if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  q.isEmpty
                      ? 'No files yet for ${owner.name}. Add a report to get started.'
                      : 'No files match “${query.trim()}”.',
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            for (final report in files)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(report.name),
                  subtitle: Text(
                    '${report.extension.toUpperCase()} · ${report.type} · ${_dateLine(report)}\n'
                    '${profileFileStatus(report.status)}',
                  ),
                  isThreeLine: true,
                  onTap: () => widget.onOpenReport(report),
                  trailing: IconButton(
                    tooltip: 'Open original',
                    onPressed: () => widget.onOpenOriginal(report),
                    icon: const Icon(Icons.open_in_new_outlined),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
