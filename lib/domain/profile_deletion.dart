import 'records.dart';

/// Remove all context owned by a profile. Identity collisions with other
/// profiles are harmless: ownership, never a report/session ID, is the filter.
/// Native callers must persist this result before erasing queued originals.
VaultData withoutProfile(
  VaultData data,
  String id, {
  bool queueFileDeletion = true,
}) {
  if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
    throw StateError('Invalid profile identity.');
  }
  if (!data.profiles.any((profile) => profile.id == id)) {
    throw StateError('Unknown profile.');
  }
  final profiles = data.profiles.where((profile) => profile.id != id).toList();
  final sessions = data.sessions
      .where((session) => session.profileId != id)
      .toList();
  final selections = {...data.activeSessionByProfile}..remove(id);
  final next = data.copy(
    profiles: profiles,
    reports: data.reports.where((report) => report.profileId != id).toList(),
    sessions: sessions,
    memories: data.memories.where((memory) => memory.profileId != id).toList(),
    exports: data.exports.where((entry) => entry.profileId != id).toList(),
    processingJobs: data.processingJobs
        .where((job) => job.profileId != id)
        .toList(),
    vitals: data.vitals.where((vital) => vital.profileId != id).toList(),
    activeSessionByProfile: selections,
    deletedProfileIds: queueFileDeletion
        ? {...data.deletedProfileIds, id}.toList()
        : data.deletedProfileIds,
  );
  if (data.activeProfileId != id) {
    // A corrupt vault can pair another profile with a removed session;
    // never leave a dangling active session behind.
    if (!sessions.any((s) => s.id == next.activeSessionId)) {
      return next.copy(clearActiveSession: true);
    }
    return next;
  }
  if (profiles.isEmpty) {
    return next.copy(clearActiveProfile: true);
  }
  final replacement = profiles.first.id;
  final ownedSessions =
      sessions.where((session) => session.profileId == replacement).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final remembered = selections[replacement];
  final selected = ownedSessions.any((session) => session.id == remembered)
      ? remembered
      : ownedSessions.firstOrNull?.id;
  return next.copy(
    activeProfileId: replacement,
    activeSessionId: selected,
    clearActiveSession: selected == null,
  );
}
