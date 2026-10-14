import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../domain/records.dart';

/// The household entry point. Opening and creating profiles remain owned by
/// the app so navigation and profile selection happen in one place.
class ProfileHomeScreen extends StatefulWidget {
  const ProfileHomeScreen({
    super.key,
    required this.controller,
    required this.onOpenProfile,
    required this.onAddProfile,
    this.onViewFiles,
  });

  final AppController controller;
  final Future<void> Function(String) onOpenProfile;
  final VoidCallback onAddProfile;

  /// Optional dedicated files entry: opens [profile]'s file library without
  /// going through a conversation. When null, no files button is shown.
  final Future<void> Function(Profile profile)? onViewFiles;

  @override
  State<ProfileHomeScreen> createState() => _ProfileHomeScreenState();
}

class _ProfileHomeScreenState extends State<ProfileHomeScreen> {
  String? _openingProfileId;
  bool _openFailed = false;

  bool get _enabled =>
      widget.controller.loaded &&
      !widget.controller.busy &&
      _openingProfileId == null;

  Future<void> _openProfile(String id) async {
    if (!_enabled) return;
    setState(() {
      _openingProfileId = id;
      _openFailed = false;
    });
    try {
      await widget.onOpenProfile(id);
    } catch (_) {
      if (mounted) setState(() => _openFailed = true);
    } finally {
      if (mounted) setState(() => _openingProfileId = null);
    }
  }

  Widget _profileCard(Profile profile) {
    final colors = Theme.of(context).colorScheme;
    final opening = _openingProfileId == profile.id;
    return Card(
      key: ValueKey('home-profile-${profile.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: Icon(
            profile.isChild ? Icons.child_care_outlined : Icons.person_outline,
          ),
        ),
        title: Text(
          profile.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            [
              profile.isChild ? 'Child profile' : 'Adult profile',
              if (profile.dateOfBirth != null)
                'Born ${DateFormat.yMMMd('en_US').format(profile.dateOfBirth!)}',
            ].join(' · '),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onViewFiles != null)
              IconButton(
                key: ValueKey('home-files-${profile.id}'),
                tooltip: 'Files',
                onPressed: !_enabled
                    ? null
                    : () => widget.onViewFiles!(profile),
                icon: const Icon(Icons.folder_open_outlined),
              ),
            if (opening)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.arrow_forward_rounded),
          ],
        ),
        enabled: _enabled,
        onTap: _enabled ? () => _openProfile(profile.id) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.spa_outlined),
              SizedBox(width: 10),
              Text('Ayumitra'),
            ],
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                key: const Key('profile-home-list'),
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
                children: [
                  Text(
                    'Your health companion',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Choose a profile to open their conversations and health history.',
                    style: TextStyle(fontSize: 16, height: 1.5),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Each person has their own private space.',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (!controller.loaded)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Loading your profiles…'),
                        ],
                      ),
                    )
                  else if (controller.data.profiles.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 40,
                              color: colors.primary,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Welcome to Ayumitra',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Add your first profile to begin.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  else ...[
                    Text(
                      'Profiles',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    for (final profile in controller.data.profiles)
                      _profileCard(profile),
                  ],
                  if (_openFailed) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Couldn’t open this profile. Please try again.',
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('home-add-profile'),
                    onPressed: _enabled ? widget.onAddProfile : null,
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('Add profile'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
