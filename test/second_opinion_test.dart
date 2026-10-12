// Sub-owned tests: explicit-tap second-opinion export (user request).
// Synthetic data only. No network, no real patient data.

import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/second_opinion.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

final _dob = DateTime(2021, 4, 18);
Profile _profile() => Profile(
  id: 'p1',
  name: 'Synthetic Child',
  history: 'Synthetic history.',
  isChild: true,
  dateOfBirth: _dob,
);

ConversationSession _session() => ConversationSession(
  id: 's1',
  profileId: 'p1',
  title: 'Fever questions',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  turns: [
    ConversationTurn(
      id: 't1',
      role: 'user',
      text: 'My child has fever, what should I ask the doctor?',
      createdAt: DateTime.utc(2026, 10, 1),
      reportCitations: const ['r1/p1-l1'],
    ),
    ConversationTurn(
      id: 't2',
      role: 'assistant',
      text: 'Local draft citing Hb 11.2 g/dL [r1/p1-l1].',
      createdAt: DateTime.utc(2026, 10, 2),
      webSources: [
        ConversationWebSource(
          id: 'web-1',
          title: 'Synthetic label',
          url: 'https://example.org/label',
          excerpt: 'Synthetic excerpt.',
          retrievedAt: DateTime.utc(2026, 10, 12),
        ),
      ],
    ),
  ],
);

Report _report() => Report(
  id: 'r1',
  profileId: 'p1',
  name: 'r1.pdf',
  extension: 'pdf',
  digest: 'digest-r1',
  importedAt: DateTime.utc(2026, 10, 12),
  lines: const [
    SourceLine(id: 'p1-l1', page: 1, text: 'Hb 11.2 g/dL [12.0-16.0]'),
  ],
);

void main() {
  Future<AppController> auditController() async {
    final directory = await Directory.systemTemp.createTemp(
      'ayumitra-exports-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final controller = AppController()
      ..loaded = true
      ..activeProfileId = 'p1'
      ..activeSessionId = 's1'
      ..data = VaultData(
        profiles: [_profile()],
        sessions: [_session()],
        reports: [_report()],
      )
      ..vault = EncryptedVault(
        directory: directory,
        key: await AesGcm.with256bits().newSecretKey(),
      );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'controller audit verifies original session and owned report snapshot',
    () async {
      final controller = await auditController();
      await expectLater(
        controller.recordSecondOpinionExport(
          target: 'copy',
          reportIds: const ['foreign'],
          profileId: 'p1',
          sessionId: 's1',
        ),
        throwsStateError,
      );
      await expectLater(
        controller.recordSecondOpinionExport(
          target: 'copy',
          reportIds: const ['r1'],
          profileId: 'p1',
          sessionId: 'changed',
        ),
        throwsStateError,
      );
      final entry = await controller.recordSecondOpinionExport(
        target: 'copy',
        reportIds: const ['r1'],
        profileId: 'p1',
        sessionId: 's1',
      );
      expect(entry.profileId, 'p1');
      expect(entry.sessionId, 's1');
      expect(entry.target, 'copy');
      expect(entry.reportIds, ['r1']);
      expect((await controller.vault.read()).exports, hasLength(1));
      expect(entry.toJson().keys, isNot(contains('markdown')));
      controller.activeProfileId = 'changed';
      await expectLater(
        controller.recordSecondOpinionExport(
          target: 'claude',
          reportIds: const ['r1'],
          profileId: 'p1',
          sessionId: 's1',
        ),
        throwsStateError,
      );
      expect((await controller.vault.read()).exports, hasLength(1));
    },
  );

  test(
    'overlapping audit writes cannot overwrite a completed export record',
    () async {
      final controller = await auditController();
      final first = controller.recordSecondOpinionExport(
        target: 'copy',
        reportIds: const ['r1'],
        profileId: 'p1',
        sessionId: 's1',
      );
      await expectLater(
        controller.recordSecondOpinionExport(
          target: 'claude',
          reportIds: const ['r1'],
          profileId: 'p1',
          sessionId: 's1',
        ),
        throwsStateError,
      );
      await first;
      await controller.recordSecondOpinionExport(
        target: 'claude',
        reportIds: const ['r1'],
        profileId: 'p1',
        sessionId: 's1',
      );
      expect((await controller.vault.read()).exports.map((e) => e.target), [
        'copy',
        'claude',
      ]);
    },
  );

  test('pack carries transcript, citations, web sources, and warnings', () {
    final pack = buildSecondOpinionPack(
      profile: _profile(),
      session: _session(),
      reports: [_report()],
    );
    expect(pack.markdown, contains('review before sharing'));
    expect(pack.markdown, contains('My child has fever'));
    expect(pack.markdown, contains('[r1/p1-l1]'));
    expect(pack.markdown, contains('Hb 11.2 g/dL'));
    expect(pack.markdown, contains('https://example.org/label'));
    expect(pack.markdown, contains('2026-10-12'));
    expect(pack.reportIds, ['r1']);
    expect(pack.truncated, isFalse);
  });

  test(
    'long packs preserve the latest question and source within the whole budget',
    () {
      final latest = ConversationTurn(
        id: 'latest',
        role: 'user',
        text: 'LATEST_QUESTION about this haemoglobin result',
        createdAt: DateTime.utc(2026, 10, 3),
        reportCitations: const ['r1/p1-l1'],
      );
      final pack = buildSecondOpinionPack(
        profile: _profile(),
        session: _session().copy(
          turns: [
            ConversationTurn(
              id: 'old',
              role: 'user',
              text: 'OLD_QUESTION ${List.filled(900, 'old text ').join()}',
              createdAt: DateTime.utc(2026, 9, 1),
            ),
            ..._session().turns,
            latest,
          ],
        ),
        reports: [_report()],
        maxChars: 1024,
      );
      expect(pack.truncated, isTrue);
      expect(pack.markdown, contains(latest.text));
      expect(pack.markdown, contains('Hb 11.2 g/dL [12.0-16.0]'));
      expect(pack.markdown, contains('Content omitted or shortened'));
      expect(pack.markdown, isNot(contains('oldest content beyond')));
      expect(pack.markdown.length, lessThanOrEqualTo(1024));
      expect(pack.reportIds, ['r1']);
    },
  );

  test(
    'vision excerpts retain provenance and foreign reports are never included',
    () {
      final pack = buildSecondOpinionPack(
        profile: _profile(),
        session: _session().copy(
          turns: [
            ..._session().turns,
            ConversationTurn(
              id: 'latest',
              role: 'user',
              text: 'Latest question',
              createdAt: DateTime.utc(2026, 10, 3),
              reportCitations: const ['r2/l1'],
            ),
          ],
        ),
        reports: [
          _report().copy(
            lines: const [
              SourceLine(
                id: 'p1-l1',
                page: 1,
                text: 'Hb 11.2 g/dL [12.0-16.0]',
                method: 'vision',
              ),
            ],
          ),
          Report(
            id: 'r2',
            profileId: 'p2',
            name: 'FOREIGN_PRIVATE_REPORT',
            extension: 'txt',
            digest: 'foreign',
            importedAt: DateTime(2026),
            lines: const [
              SourceLine(id: 'l1', page: 1, text: 'FOREIGN_PRIVATE_TEXT'),
            ],
          ),
        ],
      );
      expect(pack.markdown, contains('Unverified local vision transcription'));
      expect(pack.markdown, contains('page 1'));
      expect(pack.markdown, contains('Source unavailable in this profile'));
      expect(pack.markdown, isNot(contains('FOREIGN_PRIVATE')));
      expect(pack.profileId, 'p1');
      expect(pack.sessionId, 's1');
      expect(pack.reportIds, ['r1']);
      expect(() => pack.reportIds.add('foreign'), throwsUnsupportedError);
    },
  );

  test(
    'a large citation history keeps the newest source instead of oldest leftovers',
    () {
      final session = _session().copy(
        turns: [
          for (var i = 0; i < 30; i++)
            ConversationTurn(
              id: 't-$i',
              role: 'user',
              text: 'QUESTION_$i',
              createdAt: DateTime.utc(2026, 10, 1, 0, i),
              reportCitations: ['r1/l$i'],
            ),
        ],
      );
      final report = _report().copy(
        lines: [
          for (var i = 0; i < 30; i++)
            SourceLine(
              id: 'l$i',
              page: 1,
              text: 'SOURCE_$i ${List.filled(20, 'synthetic ').join()}',
            ),
        ],
      );
      final pack = buildSecondOpinionPack(
        profile: _profile(),
        session: session,
        reports: [report],
        maxChars: 1024,
      );
      expect(pack.markdown, contains('QUESTION_29'));
      expect(pack.markdown, contains('[r1/l29]'));
      expect(pack.markdown, contains('SOURCE_29'));
      expect(pack.markdown.length, lessThanOrEqualTo(1024));
      expect(pack.truncated, isTrue);
    },
  );

  test(
    'an oversized latest request retains its final question with explicit omission',
    () {
      final session = _session().copy(
        turns: [
          ConversationTurn(
            id: 'latest',
            role: 'user',
            text:
                'LATEST_CONTEXT ${List.filled(900, 'context ').join()} FINAL_QUESTION',
            createdAt: DateTime(2026),
          ),
        ],
      );
      final pack = buildSecondOpinionPack(
        profile: _profile(),
        session: session,
        reports: const [],
        maxChars: 1024,
      );
      expect(pack.markdown, contains('LATEST_CONTEXT'));
      expect(pack.markdown, contains('FINAL_QUESTION'));
      expect(pack.markdown, contains('[Middle omitted]'));
      expect(pack.markdown.length, lessThanOrEqualTo(1024));
      expect(pack.truncated, isTrue);
    },
  );

  test(
    'invalid tiny budgets are refused rather than dropping the review warning',
    () {
      expect(
        () => buildSecondOpinionPack(
          profile: _profile(),
          session: _session(),
          reports: const [],
          maxChars: 200,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'identifier hints compare short, accented, and punctuated names as words',
    () {
      Profile named(String name) => Profile(id: 'p', name: name, history: '');
      expect(
        identifierHints('Jose Li', named('José-Lí')),
        contains('profile name'),
      );
      expect(identifierHints('João', named('Joao')), contains('profile name'));
      expect(
        identifierHints('AnaMaria', named('Ana-Maria')),
        contains('profile name'),
      );
      expect(identifierHints('Li', named('Li')), contains('profile name'));
      expect(
        identifierHints('liquids', named('Li')),
        isNot(contains('profile name')),
      );
    },
  );

  test('identifier hints flag name/email without echoing values', () {
    final session = ConversationSession(
      id: 's1',
      profileId: 'p1',
      title: 'T',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 2),
      turns: [
        ConversationTurn(
          id: 't1',
          role: 'user',
          text: 'Synthetic Child contact zephyr@example.com 9876543210',
          createdAt: DateTime.utc(2026, 10, 1),
        ),
      ],
    );
    final pack = buildSecondOpinionPack(
      profile: _profile(),
      session: session,
      reports: const [],
    );
    expect(pack.identifierHints, contains('email address'));
    expect(pack.identifierHints, contains('long number (phone/MRN/ID?)'));
    expect(pack.identifierHints, contains('profile name'));
    for (final hint in pack.identifierHints) {
      expect(hint, isNot(contains('zephyr@example.com')));
      expect(hint, isNot(contains('9876543210')));
    }
  });

  test('cross-profile sessions are refused', () {
    final other = ConversationSession(
      id: 's9',
      profileId: 'p2',
      title: 'T',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 2),
    );
    expect(
      () => buildSecondOpinionPack(
        profile: _profile(),
        session: other,
        reports: const [],
      ),
      throwsStateError,
    );
  });

  test('audit stores metadata only; vault keeps it across decode', () {
    final audit = SecondOpinionAudit(
      id: 'e1',
      profileId: 'p1',
      sessionId: 's1',
      target: 'chatgpt',
      reportIds: const ['r1'],
      reviewed: true,
      createdAt: DateTime.utc(2026, 10, 12),
    );
    expect(audit.toJson().keys, isNot(contains('markdown')));
    final data = VaultData.decode(
      jsonEncode(
        VaultData(
          exports: [
            SecondOpinionAudit(
              id: 'e1',
              profileId: 'p1',
              sessionId: 's1',
              target: 'chatgpt',
              reportIds: const ['r1'],
              reviewed: true,
              createdAt: DateTime.utc(2026, 10, 12),
            ),
          ],
        ).toJson(),
      ),
    );
    expect(data.exports.single.target, 'chatgpt');
    expect(data.exports.single.reportIds, ['r1']);
    // Backward compatible: vaults written before exports gain an empty log.
    final legacy = VaultData.decode('{"schema":2,"profiles":[],"reports":[]}');
    expect(legacy.exports, isEmpty);
  });
}
