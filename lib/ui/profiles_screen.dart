import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../domain/records.dart';

/// Separate create/edit/switch manager for profiles.
///
/// Calls the controller contract from board MSG-038:
/// `createProfile(String name, DateTime dob, String history, bool isChild)`,
/// `updateProfile(String id, {required name, dateOfBirth, history, isChild})`,
/// `selectProfile(String id) -> Future<void>`.
/// DOB entry is a picker plus a strict YYYY-MM-DD field; future dates are
/// refused locally before anything reaches the controller.
class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key, required this.controller, this.onViewFiles});
  final AppController controller;

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
  AppController get c => widget.controller;

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
    if (c.busy) return;
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
          for (final profile in c.data.profiles)
            Card(
              child: ListTile(
                leading: Icon(
                  c.activeProfileId == profile.id
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                ),
                title: Text(profile.name),
                subtitle: Text(
                  '${profile.dateOfBirth == null ? 'Birth date not set' : 'Born ${DateFormat.yMMMd().format(profile.dateOfBirth!)}'}\n'
                  '${profile.isChild ? 'Child' : 'Adult'} profile',
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onViewFiles != null)
                      IconButton(
                        tooltip: 'View files',
                        onPressed: c.busy
                            ? null
                            : () async {
                                await c.selectProfile(profile.id);
                                widget.onViewFiles!.call(profile);
                              },
                        icon: const Icon(Icons.folder_outlined),
                      ),
                    IconButton(
                      tooltip: 'Edit profile',
                      onPressed: c.busy ? null : () => _editForm(profile),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
                onTap: c.busy ? null : () => c.selectProfile(profile.id),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: c.busy ? null : _newForm,
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
              enabled: !c.busy,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: dobText,
              enabled: !c.busy,
              keyboardType: TextInputType.datetime,
              decoration: InputDecoration(
                labelText: 'Date of birth (YYYY-MM-DD)',
                suffixIcon: IconButton(
                  tooltip: 'Pick a date',
                  onPressed: c.busy ? null : _pickDob,
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: history,
              enabled: !c.busy,
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
              onChanged: c.busy ? null : (v) => setState(() => isChild = v),
            ),
            if (formError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  formError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (c.failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(c.failure!),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: c.busy ? null : _save,
                    child: const Text('Save profile'),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: c.busy ? null : _cancelForm,
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
