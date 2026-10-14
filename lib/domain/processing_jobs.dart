import 'records.dart';

const _retryDelays = [
  Duration(seconds: 10),
  Duration(minutes: 1),
  Duration(minutes: 5),
];

bool _ownedReportExists(VaultData data, String reportId, String profileId) =>
    !data.deletedProfileIds.contains(profileId) &&
    data.profiles.any((profile) => profile.id == profileId) &&
    data.reports.any(
      (report) => report.id == reportId && report.profileId == profileId,
    );

bool _matches(ReportProcessingJob job, String reportId, String profileId) =>
    job.reportId == reportId && job.profileId == profileId;

void _requireOwnedReport(VaultData data, String reportId, String profileId) {
  if (!_ownedReportExists(data, reportId, profileId)) {
    throw StateError('Stored report ownership is required for processing.');
  }
}

/// Return only due jobs backed by a live stored profile and its own report.
/// Callers must recheck ownership before file access after any asynchronous gap.
List<ReportProcessingJob> pendingReportJobs(
  VaultData data,
  DateTime now, {
  int maxAttempts = 3,
}) {
  if (maxAttempts <= 0) return [];
  final seen = <(String, String)>{};
  final result = <ReportProcessingJob>[];
  for (final job in data.processingJobs) {
    if (!_ownedReportExists(data, job.reportId, job.profileId) ||
        job.paused ||
        job.attempts >= maxAttempts ||
        job.attempts >= _retryDelays.length ||
        job.nextAttemptAt.isAfter(now) ||
        !seen.add((job.profileId, job.reportId))) {
      continue;
    }
    result.add(job);
  }
  result.sort((a, b) {
    final date = a.nextAttemptAt.compareTo(b.nextAttemptAt);
    if (date != 0) return date;
    final owner = a.profileId.compareTo(b.profileId);
    return owner != 0 ? owner : a.reportId.compareTo(b.reportId);
  });
  return result;
}

/// Idempotent enqueue preserves backoff. Only an explicit/manual reset restarts
/// exhausted attempts, so restarting the app cannot create an endless retry.
VaultData enqueueReportJob(
  VaultData data,
  String reportId,
  String profileId,
  DateTime now, {
  bool resetAttempts = false,
}) {
  _requireOwnedReport(data, reportId, profileId);
  final existing = data.processingJobs
      .where((job) => _matches(job, reportId, profileId))
      .firstOrNull;
  final queued = existing != null && !resetAttempts
      ? existing
      : ReportProcessingJob(
          reportId: reportId,
          profileId: profileId,
          nextAttemptAt: now,
        );
  return data.copy(
    processingJobs: [
      ...data.processingJobs.where(
        (job) => !_matches(job, reportId, profileId),
      ),
      queued,
    ],
  );
}

/// Completion is idempotent and purges unconditionally: entries whose
/// report row is gone (single-report removal, interrupted work) would
/// otherwise persist forever — hidden from [pendingReportJobs] yet never
/// executable nor deletable. Ownership is still required to create or fail
/// a job below.
VaultData finishReportJob(VaultData data, String reportId, String profileId) {
  return data.copy(
    processingJobs: data.processingJobs
        .where((job) => !_matches(job, reportId, profileId))
        .toList(),
  );
}

VaultData failReportJob(
  VaultData data,
  String reportId,
  String profileId,
  DateTime now,
) {
  _requireOwnedReport(data, reportId, profileId);
  final job = data.processingJobs
      .where((job) => _matches(job, reportId, profileId))
      .firstOrNull;
  if (job == null) throw StateError('The report has no queued processing job.');
  final attempts = job.attempts < _retryDelays.length
      ? job.attempts + 1
      : _retryDelays.length;
  return data.copy(
    processingJobs: [
      ...data.processingJobs.where(
        (entry) => !_matches(entry, reportId, profileId),
      ),
      job.copy(
        attempts: attempts,
        nextAttemptAt: now.add(_retryDelays[attempts - 1]),
      ),
    ],
  );
}

/// A user's Stop survives automatic startup enqueue; only explicit Retry
/// (resetAttempts) resumes it. Existing progress and attempt history are kept.
VaultData pauseReportJob(VaultData data, String reportId, String profileId) {
  _requireOwnedReport(data, reportId, profileId);
  final queued = enqueueReportJob(data, reportId, profileId, DateTime.now());
  return queued.copy(
    processingJobs: queued.processingJobs
        .map(
          (job) =>
              _matches(job, reportId, profileId) ? job.copy(paused: true) : job,
        )
        .toList(),
  );
}
