import 'dart:convert';

import 'package:ayumitra/domain/processing_jobs.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 13, 12);
Profile _profile(String id) => Profile(
  id: id,
  name: 'Synthetic $id',
  history: '',
  dateOfBirth: DateTime(2000),
);
Report _report(String profileId, {String id = 'shared-report'}) => Report(
  id: id,
  profileId: profileId,
  name: 'synthetic.txt',
  extension: 'txt',
  digest: 'synthetic',
  importedAt: _now,
);
VaultData _fixture() => VaultData(
  profiles: [_profile('alice'), _profile('bob')],
  reports: [_report('alice'), _report('bob')],
  activeProfileId: 'alice',
);
ReportProcessingJob _job(
  String profileId, {
  String reportId = 'shared-report',
  int attempts = 0,
  DateTime? date,
}) => ReportProcessingJob(
  profileId: profileId,
  reportId: reportId,
  attempts: attempts,
  nextAttemptAt: date ?? _now,
);

void main() {
  test(
    'paused jobs survive reload and startup enqueue until an explicit retry',
    () {
      final queued = enqueueReportJob(
        _fixture(),
        'shared-report',
        'alice',
        _now,
      );
      final attempted = failReportJob(queued, 'shared-report', 'alice', _now);
      final paused = pauseReportJob(attempted, 'shared-report', 'alice');
      final restored = VaultData.decode(jsonEncode(paused.toJson()));
      final startup = enqueueReportJob(
        restored,
        'shared-report',
        'alice',
        _now,
      );
      expect(startup.processingJobs.single.paused, isTrue);
      expect(startup.processingJobs.single.attempts, 1);
      expect(
        pendingReportJobs(startup, _now.add(const Duration(days: 30))),
        isEmpty,
      );
      final retry = enqueueReportJob(
        startup,
        'shared-report',
        'alice',
        _now,
        resetAttempts: true,
      );
      expect(retry.processingJobs.single.paused, isFalse);
      expect(retry.processingJobs.single.attempts, 0);
      expect(pendingReportJobs(retry, _now).length, 1);
      final legacy = queued.processingJobs.single.toJson()..remove('paused');
      expect(ReportProcessingJob.fromJson(legacy).paused, isFalse);
    },
  );
  test(
    'new queue is due and idempotent enqueue cannot reset persisted backoff',
    () {
      final queued = enqueueReportJob(
        _fixture(),
        'shared-report',
        'alice',
        _now,
      );
      expect(pendingReportJobs(queued, _now).length, 1);
      final failed = failReportJob(queued, 'shared-report', 'alice', _now);
      final later = enqueueReportJob(
        failed,
        'shared-report',
        'alice',
        _now.add(const Duration(minutes: 2)),
      );
      expect(later.processingJobs.length, 1);
      expect(later.processingJobs.single.attempts, 1);
      expect(
        later.processingJobs.single.nextAttemptAt,
        _now.add(const Duration(seconds: 10)),
      );
    },
  );
  test(
    'retry is due at exact deadline with 10 second, 1 minute and 5 minute delays',
    () {
      var data = enqueueReportJob(_fixture(), 'shared-report', 'alice', _now);
      var clock = _now;
      final delays = [
        const Duration(seconds: 10),
        const Duration(minutes: 1),
        const Duration(minutes: 5),
      ];
      for (var attempt = 1; attempt <= 3; attempt++) {
        data = failReportJob(data, 'shared-report', 'alice', clock);
        final deadline = clock.add(delays[attempt - 1]);
        expect(data.processingJobs.single.attempts, attempt);
        expect(data.processingJobs.single.nextAttemptAt, deadline);
        expect(
          pendingReportJobs(
            data,
            deadline.subtract(const Duration(microseconds: 1)),
          ),
          isEmpty,
        );
        expect(pendingReportJobs(data, deadline).length, attempt < 3 ? 1 : 0);
        clock = deadline;
      }
      expect(
        pendingReportJobs(data, clock.add(const Duration(days: 365))),
        isEmpty,
      );
      expect(
        pendingReportJobs(
          data,
          clock.add(const Duration(days: 365)),
          maxAttempts: 5,
        ),
        isEmpty,
      );
    },
  );
  test(
    'explicit manual reset makes exhausted owned job due without affecting another owner',
    () {
      final other = _job('bob', attempts: 2);
      final data = _fixture().copy(
        processingJobs: [_job('alice', attempts: 3), other],
      );
      final reset = enqueueReportJob(
        data,
        'shared-report',
        'alice',
        _now,
        resetAttempts: true,
      );
      expect(
        reset.processingJobs.where((job) => job.profileId == 'bob').single,
        same(other),
      );
      final own = reset.processingJobs
          .where((job) => job.profileId == 'alice')
          .single;
      expect(own.attempts, 0);
      expect(own.nextAttemptAt, _now);
      expect(pendingReportJobs(reset, _now).map((job) => job.profileId), [
        'alice',
        'bob',
      ]);
    },
  );
  test(
    'success removes only exact owner/report pair even when report IDs collide',
    () {
      var data = enqueueReportJob(_fixture(), 'shared-report', 'alice', _now);
      data = enqueueReportJob(data, 'shared-report', 'bob', _now);
      final result = finishReportJob(data, 'shared-report', 'alice');
      expect(result.processingJobs.map((job) => job.profileId), ['bob']);
      expect(data.processingJobs.length, 2);
      expect(result.reports.length, 2);
    },
  );
  test(
    'unknown, wrong owner, removed report and pending erasure never become executable jobs',
    () {
      final data = _fixture().copy(
        processingJobs: [
          _job('alice'),
          _job('missing'),
          _job('bob', reportId: 'absent'),
        ],
        deletedProfileIds: ['alice'],
      );
      expect(pendingReportJobs(data, _now), isEmpty);
      for (final owner in ['alice', 'missing']) {
        expect(
          () => enqueueReportJob(data, 'shared-report', owner, _now),
          throwsStateError,
        );
        expect(
          () => failReportJob(data, 'shared-report', owner, _now),
          throwsStateError,
        );
      }
      // Finishing is an unconditional purge: orphan entries for removed
      // reports must be deletable, never stuck.
      expect(
        finishReportJob(
          data,
          'shared-report',
          'missing',
        ).processingJobs.where((job) => job.profileId == 'missing'),
        isEmpty,
      );
      final removed = data.copy(reports: [], deletedProfileIds: []);
      expect(pendingReportJobs(removed, _now), isEmpty);
      expect(
        () => enqueueReportJob(removed, 'shared-report', 'bob', _now),
        throwsStateError,
      );
      final absentOwner = data.copy(profiles: [], deletedProfileIds: []);
      expect(pendingReportJobs(absentOwner, _now), isEmpty);
      expect(
        () => enqueueReportJob(absentOwner, 'shared-report', 'bob', _now),
        throwsStateError,
      );
    },
  );
  test('failure cannot manufacture a job for an unqueued report', () {
    expect(
      () => failReportJob(_fixture(), 'shared-report', 'alice', _now),
      throwsStateError,
    );
  });
  test(
    'duplicate stored jobs execute each ownership pair once and due jobs sort deterministically',
    () {
      final data = _fixture().copy(
        processingJobs: [_job('bob'), _job('alice'), _job('alice')],
      );
      expect(pendingReportJobs(data, _now).map((job) => job.profileId), [
        'alice',
        'bob',
      ]);
      expect(pendingReportJobs(data, _now, maxAttempts: 0), isEmpty);
      final bounded = data.copy(
        processingJobs: [_job('alice', attempts: 1), _job('bob')],
      );
      expect(
        pendingReportJobs(
          bounded,
          _now,
          maxAttempts: 1,
        ).map((job) => job.profileId),
        ['bob'],
      );
    },
  );
  test(
    'interrupted processing is recovered from index without depending on active profile',
    () {
      final data = enqueueReportJob(_fixture(), 'shared-report', 'bob', _now);
      final restored = VaultData.decode(jsonEncode(data.toJson()));
      expect(restored.activeProfileId, 'alice');
      expect(pendingReportJobs(restored, _now).single.profileId, 'bob');
      expect(
        restored.processingJobs.single.toJson(),
        data.processingJobs.single.toJson(),
      );
      expect(
        restored.copy(activeProfileId: 'bob').processingJobs.single.attempts,
        0,
      );
    },
  );
  test('schema1 and schema2 pre-job vaults remain readable', () {
    for (final schema in [1, 2]) {
      final json = _fixture().toJson()..remove('processingJobs');
      json['schema'] = schema;
      expect(VaultData.decode(jsonEncode(json)).processingJobs, isEmpty);
    }
  });
  test(
    'negative attempt metadata is rejected on creation, copy and index decode',
    () {
      expect(() => _job('alice', attempts: -1), throwsFormatException);
      expect(() => _job('alice').copy(attempts: -1), throwsFormatException);
      final json = _fixture().toJson();
      json['processingJobs'] = [_job('alice').toJson()..['attempts'] = -1];
      expect(() => VaultData.decode(jsonEncode(json)), throwsFormatException);
    },
  );
}
