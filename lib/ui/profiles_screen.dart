import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../domain/records.dart';

enum _ProfileAction { viewFiles, edit, delete }

/// Separate create/edit/switch manager for profiles.
///
/// Calls the controller contract from board MSG-038:
/// `createProfile(String name, DateTime dob, String history, bool isChild)`,
/// `updateProfile(String id, {required name, dateOfBirth, history, isChild})`,
/// `selectProfile(String id) -> Future<void>`.
/// DOB entry is a picker plus a strict YYYY-MM-DD field; future dates are
/// refused locally before anything reaches the controller.
class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({
    super.key,
    required this.controller,
    this.onViewFiles,
    this.createOnOpen = false,
  });
  final AppController controller;

  /// Opens a blank creation form when entering from the home Add profile button.
  final bool createOnOpen;

  /// Optional file-library entry: when set, each person gets a folder
  /// button that selects them before opening their library. Kept optional
  /// so existing push sites without library wiring are unaffected.
  final void Function(Profile profile)? onViewFiles;
  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  final name = TextEditingController();
  final dobText = TextEditingController();
  final history = TextEditingController();
  bool isChild = true;
  String? editingId;
  String? formError;
  String? _deletingProfileId;
  bool _deleteFailed = false;
  AppController get c => widget.controller;
  bool get _actionsEnabled => !c.busy && _deletingProfileId == null;

  @override
  void initState() {
    super.initState();
    if (widget.createOnOpen) editingId = '';
  }

  @override
  void dispose() {
    name.dispose();
    dobText.dispose();
    history.dispose();
    super.dispose();
  }

  void _newForm() => setState(() {
    editingId = '';
    name.clear();
    dobText.clear();
    history.clear();
    isChild = true;
    formError = null;
  });

  void _editForm(Profile p) => setState(() {
    editingId = p.id;
    name.text = p.name;
    dobText.text = p.dateOfBirth == null
        ? ''
        : DateFormat('yyyy-MM-dd').format(p.dateOfBirth!);
    history.text = p.history;
    isChild = p.isChild;
    formError = null;
  });

  Future<void> _viewFiles(Profile profile) async {
    if (!_actionsEnabled || widget.onViewFiles == null) return;
    await c.selectProfile(profile.id);
    if (!mounted || c.activeProfileId != profile.id) return;
    widget.onViewFiles!.call(profile);
  }

  Future<void> _deleteProfile(Profile profile) async {
    if (!_actionsEnabled) return;
    final fileCount = c.data.reports
        .where((report) => report.profileId == profile.id)
        .length;
    final conversationCount = c.data.sessions
        .where((session) => session.profileId == profile.id)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${profile.name}’s profile?'),
        content: Text(
          'This will permanently delete ${profile.name}’s profile, '
          '$fileCount ${fileCount == 1 ? 'file' : 'files'}, '
          '$conversationCount ${conversationCount == 1 ? 'conversation' : 'conversations'}, '
          'and all remembered context. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep profile'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete profile'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !_actionsEnabled) return;
    if (!c.data.profiles.any((person) => person.id == profile.id)) return;
    setState(() {
      _deletingProfileId = profile.id;
      _deleteFailed = false;
    });
    try {
      await c.deleteProfile(profile.id);
    } catch (_) {
      if (mounted) setState(() => _deleteFailed = true);
    } finally {
      if (mounted) {
        if (editingId == profile.id &&
            !c.data.profiles.any((person) => person.id == profile.id)) {
          name.clear();
          dobText.clear();
          history.clear();
          _cancelForm();
        }
        setState(() => _deletingProfileId = null);
      }
    }
  }

  Widget _profileCard(Profile profile) => LayoutBuilder(
    builder: (context, constraints) {
      final roomy = constraints.maxWidth >= 420;
      return Card(
        key: ValueKey('managed-profile-${profile.id}'),
        child: ListTile(
          leading: roomy
              ? Icon(
                  c.activeProfileId == profile.id
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                )
              : null,
          title: Text(
            profile.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${profile.dateOfBirth == null ? 'Birth date not set' : 'Born ${DateFormat.yMMMd('en_US').format(profile.dateOfBirth!)}'}\n'
            '${profile.isChild ? 'Child' : 'Adult'} profile',
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (roomy && widget.onViewFiles != null)
                IconButton(
                  tooltip: 'View files',
                  onPressed: _actionsEnabled ? () => _viewFiles(profile) : null,
                  icon: const Icon(Icons.folder_outlined),
                ),
              PopupMenuButton<_ProfileAction>(
                key: ValueKey('profile-actions-${profile.id}'),
                tooltip: 'Profile actions for ${profile.name}',
                enabled: _actionsEnabled,
                onSelected: (action) {
                  if (!_actionsEnabled) return;
                  switch (action) {
                    case _ProfileAction.viewFiles:
                      _viewFiles(profile);
                      return;
                    case _ProfileAction.edit:
                      _editForm(profile);
                      return;
                    case _ProfileAction.delete:
                      _deleteProfile(profile);
                      return;
                  }
                },
                itemBuilder: (context) => [
                  if (!roomy && widget.onViewFiles != null)
                    const PopupMenuItem(
                      value: _ProfileAction.viewFiles,
                      child: Text('View files'),
                    ),
                  const PopupMenuItem(
                    value: _ProfileAction.edit,
                    child: Text('Edit profile'),
                  ),
                  PopupMenuItem(
                    value: _ProfileAction.delete,
                    child: Text(
                      'Delete profile',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
          onTap: _actionsEnabled ? () => c.selectProfile(profile.id) : null,
        ),
      );
    },
  );

  void _cancelForm() => setState(() {
    editingId = null;
    formError = null;
  });

  /// Strict calendar date: exact YYYY-MM-DD shape and a real calendar day
  /// (rejects overflow like 2026-02-30 that lenient parsers roll over).
  DateTime? _parseStrictDob(String text) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text.trim());
    if (m == null) return null;
    final parsed = DateTime.tryParse('${m[1]}-${m[2]}-${m[3]}');
    if (parsed == null) return null;
    if (parsed.year != int.parse(m[1]!) ||
        parsed.month != int.parse(m[2]!) ||
        parsed.day != int.parse(m[3]!)) {
      return null;
    }
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  Future<void> _pickDob() async {
    final initial = _parseStrictDob(dobText.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(DateTime.now()) ? DateTime.now() : initial,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        dobText.text = DateFormat('yyyy-MM-dd').format(picked);
        formError = null;
      });
    }
  }

  Future<void> _save() async {
    if (!_actionsEnabled) return;
    final dob = _parseStrictDob(dobText.text);
    if (dob == null) {
      setState(() => formError = 'Enter the birth date as YYYY-MM-DD.');
      return;
    }
    final futureError = validateDateOfBirth(dob);
    if (futureError != null) {
      setState(() => formError = futureError);
      return;
    }
    if (name.text.trim().isEmpty) {
      setState(() => formError = 'Enter a name.');
      return;
    }
    setState(() => formError = null);
    if (editingId == null || editingId!.isEmpty) {
      await c.createProfile(
        name.text.trim(),
        dob,
        history.text.trim(),
        isChild,
      );
    } else {
      await c.updateProfile(
        editingId!,
        name: name.text.trim(),
        dateOfBirth: dob,
        history: history.text.trim(),
        isChild: isChild,
      );
    }
    if (mounted && c.failure == null) _cancelForm();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Profiles')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Each person keeps a separate private history.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 12),
          for (final profile in c.data.profiles) _profileCard(profile),
          if (c.failure != null || _deleteFailed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                c.failure ?? 'Couldn’t delete this profile. Please try again.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _actionsEnabled ? _newForm : null,
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('New profile'),
          ),
          if (editingId != null) ...[
            const SizedBox(height: 24),
            Text(
              editingId!.isEmpty ? 'New profile' : 'Edit profile',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              enabled: _actionsEnabled,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: dobText,
              enabled: _actionsEnabled,
              keyboardType: TextInputType.datetime,
              decoration: InputDecoration(
                labelText: 'Date of birth (YYYY-MM-DD)',
                suffixIcon: IconButton(
                  tooltip: 'Pick a date',
                  onPressed: _actionsEnabled ? _pickDob : null,
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: history,
              enabled: _actionsEnabled,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Previous history (optional)',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Child profile'),
              subtitle: const Text('A caregiver manages this history.'),
              value: isChild,
              onChanged: _actionsEnabled
                  ? (v) => setState(() => isChild = v)
                  : null,
            ),
            if (formError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  formError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _actionsEnabled ? _save : null,
                    child: const Text('Save profile'),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _actionsEnabled ? _cancelForm : null,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}
