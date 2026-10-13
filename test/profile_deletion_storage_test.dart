import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/profile_deletion.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';

final _date = DateTime(2026, 10, 13);
Profile _profile(String id) => Profile(
  id: id,
  name: 'Synthetic $id',
  history: '',
  dateOfBirth: DateTime(2000),
);
Report _report(String owner) => Report(
  id: 'shared-report',
  profileId: owner,
  name: 'synthetic.txt',
  extension: 'txt',
  digest: 'synthetic-digest',
  importedAt: _date,
  lines: const [SourceLine(id: 'line', page: 1, text: 'Synthetic source')],
  facts: const [
    MedicalFact(
      id: 'fact',
      kind: 'test',
      name: 'Synthetic',
      value: '13',
      unit: 'g/dL',
      range: '',
      sourceLineId: 'line',
      evidence: 'Synthetic source',
    ),
  ],
  vectors: const {
    'line': [1, 0],
  },
  summaryMarkdown: 'Synthetic summary',
);
ConversationSession _session(
  String owner, {
  String id = 'shared-session',
  int day = 13,
}) => ConversationSession(
  id: id,
  profileId: owner,
  title: 'Synthetic chat',
  createdAt: _date,
  updatedAt: DateTime(2026, 10, day),
  turns: [
    ConversationTurn(
      id: 'shared-turn',
      role: 'user',
      text: 'Synthetic context',
      createdAt: _date,
    ),
  ],
);
ConversationMemory _memory(String owner) => ConversationMemory(
  id: 'shared-memory',
  profileId: owner,
  sessionId: 'shared-session',
  text: 'Synthetic memory',
  updatedAt: _date,
  vector: [1, 0],
  embeddingVersion: 'test',
);
SecondOpinionAudit _export(String owner) => SecondOpinionAudit(
  id: 'shared-export',
  profileId: owner,
  sessionId: 'shared-session',
  target: 'test',
  reportIds: ['shared-report'],
  reviewed: true,
  createdAt: _date,
);
VaultData _fixture() => VaultData(
  profiles: [_profile('alice'), _profile('bob')],
  reports: [_report('alice'), _report('bob')],
  sessions: [_session('alice'), _session('bob')],
  memories: [_memory('alice'), _memory('bob')],
  exports: [_export('alice'), _export('bob')],
  activeProfileId: 'alice',
  activeSessionId: 'shared-session',
  activeSessionByProfile: const {
    'alice': 'shared-session',
    'bob': 'shared-session',
  },
  modelPath: '/synthetic/model',
  embeddingPath: '/synthetic/embedding',
);

void main() {
  group('profile context cascade', () {
    test('profile deletion also removes durable processing jobs by owner', () {
      final aliceJob = ReportProcessingJob(
        reportId: 'shared-report',
        profileId: 'alice',
        nextAttemptAt: _date,
      );
      final bobJob = ReportProcessingJob(
        reportId: 'shared-report',
        profileId: 'bob',
        nextAttemptAt: _date,
      );
      final erased = withoutProfile(
        _fixture().copy(processingJobs: [aliceJob, bobJob]),
        'alice',
      );
      expect(erased.processingJobs, [bobJob]);
      expect(
        VaultData.decode(
          jsonEncode(erased.toJson()),
        ).processingJobs.single.profileId,
        'bob',
      );
    });
    test(
      'ownership removes facts, vectors, turns, memories and exports without ID collision damage',
      () {
        final source = _fixture();
        final erased = withoutProfile(source, 'bob');
        expect(erased.profiles.map((p) => p.id), ['alice']);
        expect(erased.reports, [source.reports.first]);
        expect(erased.sessions, [source.sessions.first]);
        expect(erased.memories, [source.memories.first]);
        expect(erased.exports, [source.exports.first]);
        expect(erased.activeProfileId, source.activeProfileId);
        expect(erased.activeSessionId, source.activeSessionId);
        expect(erased.activeSessionByProfile, {'alice': 'shared-session'});
        expect(erased.modelPath, source.modelPath);
        expect(erased.embeddingPath, source.embeddingPath);
        expect(erased.deletedProfileIds, ['bob']);
        expect(source.profiles.length, 2);
      },
    );
    test(
      'active deletion restores an owned remembered session before a newer one',
      () {
        final source = _fixture().copy(
          sessions: [
            _session('alice'),
            _session('bob'),
            _session('bob', id: 'newer', day: 14),
          ],
        );
        final erased = withoutProfile(source, 'alice');
        expect(erased.activeProfileId, 'bob');
        expect(erased.activeSessionId, 'shared-session');
        expect(erased.activeSessionByProfile, {'bob': 'shared-session'});
      },
    );
    test(
      'invalid remembered selection falls back to most recently updated owned session',
      () {
        final source = _fixture().copy(
          sessions: [
            _session('alice'),
            _session('bob'),
            _session('bob', id: 'newer', day: 14),
          ],
          activeSessionByProfile: {'alice': 'shared-session', 'bob': 'missing'},
        );
        expect(withoutProfile(source, 'alice').activeSessionId, 'newer');
      },
    );
    test(
      'last profile clears active context and browser deletion queues no file job',
      () {
        final source = withoutProfile(
          _fixture(),
          'bob',
          queueFileDeletion: false,
        );
        final erased = withoutProfile(
          source,
          'alice',
          queueFileDeletion: false,
        );
        expect(erased.activeProfileId, isNull);
        expect(erased.activeSessionId, isNull);
        expect(erased.activeSessionByProfile, isEmpty);
        expect(erased.reports, isEmpty);
        expect(erased.sessions, isEmpty);
        expect(erased.memories, isEmpty);
        expect(erased.exports, isEmpty);
        expect(erased.deletedProfileIds, isEmpty);
      },
    );
    test('unknown and path traversal identities are rejected', () {
      expect(() => withoutProfile(_fixture(), 'missing'), throwsStateError);
      expect(() => withoutProfile(_fixture(), '../alice'), throwsStateError);
      expect(() => withoutProfile(_fixture(), ''), throwsStateError);
    });
    test(
      'schema 2 without tombstones remains compatible and pending jobs round trip',
      () {
        final json = _fixture().toJson()..remove('deletedProfileIds');
        expect(VaultData.decode(jsonEncode(json)).deletedProfileIds, isEmpty);
        final erased = withoutProfile(_fixture(), 'alice');
        expect(
          VaultData.decode(jsonEncode(erased.toJson())).deletedProfileIds,
          ['alice'],
        );
      },
    );
  });

  group('durable original erasure', () {
    late Directory root;
    late EncryptedVault vault;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('ayumitra-profile-erasure-');
      vault = EncryptedVault(
        directory: root,
        key: await AesGcm.with256bits().newSecretKey(),
      );
      await vault.saveOriginal(
        _report('alice'),
        Uint8List.fromList(utf8.encode('synthetic alice')),
      );
      await vault.saveOriginal(
        _report('bob'),
        Uint8List.fromList(utf8.encode('synthetic bob')),
      );
      await vault.save(_fixture());
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    test(
      'persisted logical deletion precedes originals cleanup and survives fresh read',
      () async {
        final erased = withoutProfile(await vault.read(), 'alice');
        await vault.save(erased);
        final bobFile = File('${root.path}/originals/bob/shared-report.enc');
        final ciphertext = await bobFile.readAsBytes();
        final model = File('${root.path}/models/keep-model')
          ..parent.createSync();
        await model.writeAsString('synthetic public model');
        final completed = await vault.completeProfileDeletions(
          await vault.read(),
        );
        expect(completed.deletedProfileIds, isEmpty);
        expect(
          await Directory('${root.path}/originals/alice').exists(),
          isFalse,
        );
        expect(await bobFile.readAsBytes(), ciphertext);
        expect(await model.readAsString(), 'synthetic public model');
        // Cleanup intentionally cannot silently rewrite the encrypted index.
        expect((await vault.read()).deletedProfileIds, ['alice']);
        await vault.save(completed);
        final restored = await EncryptedVault(
          directory: root,
          key: vault.key,
        ).read();
        expect(restored.profiles.map((p) => p.id), ['bob']);
        expect(restored.reports.map((p) => p.profileId), ['bob']);
        expect(restored.sessions.map((p) => p.profileId), ['bob']);
        expect(restored.memories.map((p) => p.profileId), ['bob']);
        expect(restored.exports.map((p) => p.profileId), ['bob']);
        expect(restored.deletedProfileIds, isEmpty);
        expect(
          utf8.decode(await vault.readOriginal(_report('bob'), 'bob')),
          'synthetic bob',
        );
      },
    );
    test(
      'crash after file erasure before index completion retries an absent folder',
      () async {
        await vault.save(withoutProfile(_fixture(), 'alice'));
        await vault.completeProfileDeletions(await vault.read());
        final reopened = EncryptedVault(directory: root, key: vault.key);
        final retried = await reopened.completeProfileDeletions(
          await reopened.read(),
        );
        expect(retried.deletedProfileIds, isEmpty);
        expect(retried.profiles.map((p) => p.id), ['bob']);
      },
    );
    test(
      'live owner in each collection blocks a forged deletion job',
      () async {
        final owned = _fixture();
        final noProfiles = owned.copy(
          profiles: [],
          deletedProfileIds: ['alice'],
        );
        final variants = [
          owned.copy(deletedProfileIds: ['alice']),
          noProfiles.copy(sessions: [], memories: [], exports: []),
          noProfiles.copy(reports: [], memories: [], exports: []),
          noProfiles.copy(reports: [], sessions: [], exports: []),
          noProfiles.copy(reports: [], sessions: [], memories: []),
        ];
        for (final data in variants) {
          expect(
            (await vault.completeProfileDeletions(data)).deletedProfileIds,
            ['alice'],
          );
          expect(
            await File(
              '${root.path}/originals/alice/shared-report.enc',
            ).exists(),
            isTrue,
          );
        }
      },
    );
    test(
      'path traversal and symbolic profile directory retain pending jobs',
      () async {
        final erased = withoutProfile(_fixture(), 'alice');
        await Directory('${root.path}/originals/alice').delete(recursive: true);
        await Link(
          '${root.path}/originals/alice',
        ).create('${root.path}/originals/bob');
        final result = await vault.completeProfileDeletions(
          erased.copy(deletedProfileIds: ['alice', '../bob']),
        );
        expect(result.deletedProfileIds, ['alice', '../bob']);
        expect(await vault.readOriginal(_report('bob'), 'bob'), isNotEmpty);
      },
    );
    test(
      'a symlink descendant causes no partial erasure and retry succeeds once repaired',
      () async {
        final erased = withoutProfile(_fixture(), 'alice');
        final link = Link('${root.path}/originals/alice/unsafe');
        await link.create('${root.path}/originals/bob');
        final failed = await vault.completeProfileDeletions(erased);
        expect(failed.deletedProfileIds, ['alice']);
        expect(
          await File('${root.path}/originals/alice/shared-report.enc').exists(),
          isTrue,
        );
        await vault.save(failed);
        await link.delete();
        final completed = await vault.completeProfileDeletions(
          await vault.read(),
        );
        expect(completed.deletedProfileIds, isEmpty);
        expect(
          await Directory('${root.path}/originals/alice').exists(),
          isFalse,
        );
        expect(await vault.readOriginal(_report('bob'), 'bob'), isNotEmpty);
      },
    );
    test(
      'a symbolic originals ancestor is refused without touching its destination',
      () async {
        final realOriginals = Directory('${root.path}/saved-originals');
        await Directory('${root.path}/originals').rename(realOriginals.path);
        await Link('${root.path}/originals').create(realOriginals.path);
        final result = await vault.completeProfileDeletions(
          withoutProfile(_fixture(), 'alice'),
        );
        expect(result.deletedProfileIds, ['alice']);
        expect(
          await File('${realOriginals.path}/alice/shared-report.enc').exists(),
          isTrue,
        );
      },
    );
    test('a symbolic vault root is refused', () async {
      final link = Link('${root.path}/linked-vault');
      await link.create(root.path);
      final linked = EncryptedVault(
        directory: Directory(link.path),
        key: vault.key,
      );
      final result = await linked.completeProfileDeletions(
        withoutProfile(_fixture(), 'alice'),
      );
      expect(result.deletedProfileIds, ['alice']);
      expect(
        await File('${root.path}/originals/alice/shared-report.enc').exists(),
        isTrue,
      );
    });
  });
}
