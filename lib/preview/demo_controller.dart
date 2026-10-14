import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';

import '../app_controller.dart';
import '../domain/chat_vitals.dart';
import '../domain/measurement_dates.dart';
import '../domain/profile_context.dart';
import '../domain/conversations.dart';
import '../domain/extraction.dart';
import '../domain/records.dart';
import '../domain/profile_deletion.dart';
import '../domain/processing_jobs.dart';
import '../domain/retrieval.dart';
import '../services/web_parser.dart';
import '../services/report_markdown.dart';
import '../services/task_cancellation.dart';
import '../domain/report_metadata.dart';

/// An in-memory replica of the production companion for desktop testing.
///
/// No sample data is bundled: the vault starts empty and the user imports
/// their own documents, which stay in memory and clear on reload. All
/// intelligence comes from the user's own localhost model server (see
/// `services/web_llm.dart`) — never a cloud service, never scripted answers.
class DemoController extends AppController {
  DemoController({
    super.intelligence,
    super.embeddings,
    super.webSearch,
    super.frontierGateway,
    super.secureStorage,
  });
  int _nextProfile = 0;
  int _nextConversation = 0;
  final Map<String, Uint8List> _originals = {};

  @override
  bool get isPreview => true;

  @override
  Future<void> initialize() async {
    data = const VaultData();
    activeProfileId = null;
    activeSessionId = null;
    messages.clear();
    _originals.clear();
    failure = null;
    busy = false;
    activity = '';
    stepLog.clear();
    extendedThinking = false;
    loaded = true;
    notifyListeners();
  }

  @override
  Future<void> createProfile(
    String name,
    DateTime dateOfBirth,
    String history,
    bool isChild,
  ) async {
    if (busy || !_validProfile(name, dateOfBirth)) return;
    stepLog.clear();
    failure = null;
    final next = Profile(
      id: 'preview-profile-${++_nextProfile}',
      name: name.trim(),
      dateOfBirth: dateOfBirth,
      history: history.trim(),
      isChild: isChild,
    );
    data = data.copy(
      profiles: [...data.profiles, next],
      activeProfileId: next.id,
      clearActiveSession: true,
    );
    activeProfileId = next.id;
    activeSessionId = null;
    messages.clear();
    // Seed the background as the first user turn so the assistant's work
    // starts from it: visible in the transcript, feeding session memory and
    // request context from the first question. Empty histories seed nothing.
    if (next.history.trim().isNotEmpty) {
      final now = DateTime.now();
      final seeded = ConversationSession(
        id: 'preview-conversation-${++_nextConversation}',
        profileId: next.id,
        title: 'New conversation',
        createdAt: now,
        updatedAt: now,
        turns: [
          ConversationTurn(
            id: 'preview-conversation-$_nextConversation-turn-background',
            role: 'user',
            text:
                'Background I provided when creating this profile:\n'
                '${next.history.trim()}',
            createdAt: now,
          ),
        ],
      );
      final memory = buildConversationMemory(seeded);
      data = data.copy(
        sessions: [...data.sessions, seeded],
        memories: [...data.memories, if (memory.text.isNotEmpty) memory],
        activeSessionId: seeded.id,
        activeSessionByProfile: {
          ...data.activeSessionByProfile,
          next.id: seeded.id,
        },
        activeProfileId: next.id,
      );
      activeSessionId = seeded.id;
      restoreConversation();
    }
    notifyListeners();
  }

  bool _validProfile(String name, DateTime dob) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return name.trim().isNotEmpty &&
        !dob.isAfter(today) &&
        dob.year >= today.year - 130;
  }

  @override
  Future<void> updateProfile(
    String id, {
    required String name,
    required DateTime dateOfBirth,
    required String history,
    required bool isChild,
  }) async {
    if (busy || !_validProfile(name, dateOfBirth)) return;
    try {
      for (final reading in data.vitals.where((v) => v.profileId == id)) {
        validateMeasurementDate(reading.measuredAt, dateOfBirth: dateOfBirth);
      }
    } on FormatException catch (error) {
      failure = 'Date of birth was not changed: ${error.message}';
      notifyListeners();
      return;
    }
    data = data.copy(
      profiles: data.profiles
          .map(
            (profile) => profile.id == id
                ? Profile(
                    id: id,
                    name: name.trim(),
                    dateOfBirth: dateOfBirth,
                    history: history.trim(),
                    isChild: isChild,
                  )
                : profile,
          )
          .toList(),
    );
    data = data.copy(
      reports: data.reports
          .map(
            (report) => report.profileId == id
                ? report.copy(
                    clearSummary: true,
                    notice:
                        'Date of birth was updated. Reprocess the report to refresh age at the event.',
                  )
                : report,
          )
          .toList(),
    );
    notifyListeners();
  }

  @override
  Future<void> deleteProfile(String id) async {
    if (busy) return;
    try {
      final next = withoutProfile(
        data.copy(
          activeProfileId: activeProfileId,
          activeSessionId: activeSessionId,
          clearActiveProfile: activeProfileId == null,
          clearActiveSession: activeSessionId == null,
        ),
        id,
        queueFileDeletion: false,
      );
      _originals.removeWhere((key, _) => key.startsWith('$id:'));
      data = next;
      activeProfileId = next.activeProfileId;
      activeSessionId = next.activeSessionId;
      extendedThinking = false;
      failure = null;
      restoreConversation();
      notifyListeners();
    } catch (_) {
      failure = 'This profile could not be removed. Please retry.';
      notifyListeners();
    }
  }

  @override
  Future<void> selectProfile(String id) async {
    if (busy || !data.profiles.any((profile) => profile.id == id)) return;
    stepLog.clear();
    activeProfileId = id;
    final remembered = data.activeSessionByProfile[id];
    activeSessionId = sessions.any((session) => session.id == remembered)
        ? remembered
        : sessions.firstOrNull?.id;
    data = data.copy(
      activeProfileId: id,
      activeSessionId: activeSessionId,
      clearActiveSession: activeSessionId == null,
      activeSessionByProfile: {
        ...data.activeSessionByProfile,
        id: ?activeSessionId,
      },
    );
    restoreConversation();
    failure = null;
    notifyListeners();
  }

  ConversationSession _createConversation() {
    final now = DateTime.now();
    final session = ConversationSession(
      id: 'preview-conversation-${++_nextConversation}',
      profileId: profile!.id,
      title: 'New conversation',
      createdAt: now,
      updatedAt: now,
    );
    data = data.copy(
      sessions: [...data.sessions, session],
      activeProfileId: profile!.id,
      activeSessionId: session.id,
      activeSessionByProfile: {
        ...data.activeSessionByProfile,
        profile!.id: session.id,
      },
    );
    activeSessionId = session.id;
    return session;
  }

  @override
  Future<void> newConversation() async {
    if (busy || profile == null) return;
    stepLog.clear();
    _createConversation();
    messages.clear();
    failure = null;
    notifyListeners();
  }

  @override
  Future<void> selectConversation(String id) async {
    if (busy || !sessions.any((session) => session.id == id)) return;
    stepLog.clear();
    activeSessionId = id;
    data = data.copy(
      activeSessionId: id,
      activeSessionByProfile: {...data.activeSessionByProfile, profile!.id: id},
    );
    restoreConversation();
    failure = null;
    notifyListeners();
  }

  @override
  Future<void> deleteConversation(String id) async {
    if (busy || !sessions.any((session) => session.id == id)) return;
    stepLog.clear();
    final ownerId = profile!.id;
    final remaining = data.sessions
        .where((session) => !(session.id == id && session.profileId == ownerId))
        .toList();
    final selections = {...data.activeSessionByProfile}
      ..removeWhere((key, value) => key == ownerId && value == id);
    final selected = activeSessionId == id
        ? remaining
              .where((session) => session.profileId == ownerId)
              .firstOrNull
              ?.id
        : activeSessionId;
    data = data.copy(
      sessions: remaining,
      vitals: withoutChatVitals(
        data.vitals,
        data.sessions.firstWhere((s) => s.id == id && s.profileId == ownerId),
      ),
      memories: data.memories
          .where(
            (memory) =>
                !(memory.sessionId == id && memory.profileId == ownerId),
          )
          .toList(),
      activeSessionId: selected,
      clearActiveSession: selected == null,
      activeSessionByProfile: {...selections, ownerId: ?selected},
    );
    activeSessionId = selected;
    restoreConversation();
    notifyListeners();
  }

  @override
  Future<void> attachReport() async {
    final owner = profile;
    if (owner == null || busy) return;
    await runCancellableTask(
      'Reading your file…',
      () async {
        final file = await taskCall(
          () => FilePicker.pickFile(
            type: FileType.custom,
            allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg', 'txt'],
          ),
        );
        if (file == null ||
            profile?.id != owner.id ||
            !libraryImportOwnerIsCurrent) {
          return;
        }
        if ((await file.length() ?? 0) > 30 * 1024 * 1024) {
          failure = 'Choose a file up to 30 MB.';
          return;
        }
        final bytes = await taskCall(file.readAsBytes);
        if (bytes.isEmpty ||
            profile?.id != owner.id ||
            !libraryImportOwnerIsCurrent) {
          return;
        }
        await _importBytes(file.name, _extensionOf(file.name), bytes);
      },
      failureMessage:
          'The selected file could not be read locally. Please retry.',
    );
  }

  String _extensionOf(String name) {
    final candidate = name.split('.').last.toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(candidate) ? candidate : 'txt';
  }

  void _save(VaultData next) {
    checkTaskActive();
    data = next;
    notifyListeners();
  }

  Future<void> _appendTurn(ChatEntry entry) async {
    checkTaskActive();
    if (profile == null) return;
    if (activeSession == null) {
      final now = DateTime.now();
      final created = ConversationSession(
        id: 'inmemory-conversation-$now',
        profileId: profile!.id,
        title: 'New conversation',
        createdAt: now,
        updatedAt: now,
      );
      data = data.copy(
        sessions: [...data.sessions, created],
        activeSessionId: created.id,
        activeProfileId: profile!.id,
        activeSessionByProfile: {
          ...data.activeSessionByProfile,
          profile!.id: created.id,
        },
      );
      activeSessionId = created.id;
    }
    final session = activeSession!;
    final now = DateTime.now();
    final turn = ConversationTurn(
      id: 'inmemory-turn-${now.microsecondsSinceEpoch}',
      role: entry.isUser ? 'user' : 'assistant',
      text: entry.text,
      createdAt: now,
      reportCitations: entry.hits.map((h) => h.citation).toList(),
      webSources: entry.web
          .map(
            (s) => ConversationWebSource(
              id: s.id,
              title: s.title,
              url: s.url.toString(),
              excerpt: s.excerpt,
              retrievedAt: s.retrievedAt,
            ),
          )
          .toList(),
    );
    final title =
        (session.title == 'New conversation' ||
                !session.turns.any((t) => t.role == 'user')) &&
            entry.isUser
        ? entry.text.replaceAll(RegExp(r'\s+'), ' ').trim()
        : session.title;
    final next = session.copy(
      title: title.length > 64 ? '${title.substring(0, 61)}…' : title,
      updatedAt: now,
      turns: [...session.turns, turn],
    );
    final extracted = buildConversationMemory(next);
    final prior = data.memories
        .where((m) => m.sessionId == next.id && m.profileId == next.profileId)
        .firstOrNull;
    final rebuilt = prior?.text == extracted.text
        ? prior!.copy(updatedAt: now)
        : extracted;
    _save(
      data.copy(
        sessions: data.sessions
            .map(
              (s) =>
                  s.id == next.id && s.profileId == next.profileId ? next : s,
            )
            .toList(),
        memories: [
          ...data.memories.where(
            (m) => !(m.sessionId == next.id && m.profileId == next.profileId),
          ),
          if (rebuilt.text.isNotEmpty) rebuilt,
        ],
      ),
    );
    restoreConversation();
    if (entry.isUser && embeddings.available && rebuilt.text.isNotEmpty) {
      try {
        final indexed = rebuilt.copy(
          vector: await taskCall(
            () => embeddings.embed(rebuilt.text, document: true),
          ),
          embeddingVersion: embeddings.version,
        );
        _save(
          data.copy(
            memories: data.memories
                .map(
                  (m) => m.id == indexed.id && m.profileId == indexed.profileId
                      ? indexed
                      : m,
                )
                .toList(),
          ),
        );
      } catch (_) {
        /* Durable keyword memory remains available locally. */
      }
    }
  }

  /// Imports report bytes into the active profile's in-memory vault and
  /// processes them with the configured local models. Testable seam used by
  /// [attachReport]; the bytes never leave this machine.
  Future<void> importBytes(
    String name,
    String extension,
    Uint8List bytes,
  ) async {
    if (busy || profile == null) return;
    await runCancellableTask(
      'Saving and reading your report…',
      () => _importBytes(name, extension.toLowerCase(), bytes),
      failureMessage:
          'This file could not be read locally. Please check the file and retry.',
    );
  }

  Future<void> _importBytes(
    String name,
    String extension,
    Uint8List bytes,
  ) async {
    final current = profile!;
    if (bytes.isEmpty || bytes.length > 30 * 1024 * 1024) {
      failure = 'Choose a non-empty file up to 30 MB.';
      return;
    }
    if (!{'pdf', 'png', 'jpg', 'jpeg', 'txt'}.contains(extension)) {
      failure = 'Choose a PDF, PNG, JPG, or text file up to 30 MB.';
      return;
    }
    final digest = sha256.convert(bytes).toString();
    if (data.reports.any(
      (r) => r.profileId == current.id && r.digest == digest,
    )) {
      failure = 'This report is already saved for ${current.name}.';
      return;
    }
    final importedAt = DateTime.now();
    final report = Report(
      id: 'inmemory-report-${current.id}-${digest.substring(0, 24)}',
      profileId: current.id,
      name: name,
      extension: extension,
      digest: digest,
      importedAt: importedAt,
      eventDate: DateTime(importedAt.year, importedAt.month, importedAt.day),
      dateIsFallback: true,
    );
    trackTaskReport(report);
    _originals['${report.profileId}:${report.id}'] = Uint8List.fromList(bytes);
    _save(data.copy(reports: [...data.reports, report]));
    await _process(report);
  }

  /// Parses plain text locally. Scans and PDFs without a text layer go
  /// through the user's local vision model when one is configured;
  /// otherwise they stay unread with an honest notice — never invented text.
  Future<List<SourceLine>> _parseText(Report report, Uint8List bytes) async {
    final owner = data.profiles
        .where((p) => p.id == report.profileId)
        .firstOrNull;
    if (owner == null) throw StateError('Profile access denied.');
    final previous = intelligence.visionProfileContext;
    intelligence.visionProfileContext = buildProfileContext(owner, data.vitals);
    try {
      return await WebParser(
        transcribe: (bytes) =>
            taskCall(() => intelligence.transcribeImage(bytes)),
      ).parse(report, bytes);
    } finally {
      intelligence.visionProfileContext = previous;
    }
  }

  Future<void> _process(Report report) async {
    final stored = _storedOwnedReport(report);
    if (stored == null) return;
    report = stored;
    trackTaskReport(report);
    final owner = profile;
    if (owner == null || owner.id != report.profileId) return;
    stepLog.clear();
    var next = report.copy(status: ReportStatus.processing);
    _save(
      data.copy(
        reports: data.reports
            .map(
              (r) => r.id == report.id && r.profileId == report.profileId
                  ? next
                  : r,
            )
            .toList(),
      ),
    );
    try {
      final bytes = _originals['${report.profileId}:${report.id}'];
      if (bytes == null) throw const FormatException('Original missing.');
      announceStep('Reading the document…');
      final parsedLines = await taskCall(() => _parseText(report, bytes));
      final lines = parsedLines.where((l) => l.text.trim().isNotEmpty).toList();
      if (lines.isEmpty) {
        _save(
          data.copy(
            reports: data.reports
                .map(
                  (r) => r.id == report.id && r.profileId == report.profileId
                      ? next.copy(
                          status: ReportStatus.needsReview,
                          notice:
                              'No readable text was found. Try a clearer file.',
                        )
                      : r,
                )
                .toList(),
          ),
        );
        return;
      }
      next = next.copy(lines: parsedLines, facts: const [], vectors: {});
      // User corrections survive reprocessing: align carried facts to the
      // fresh lines, then keep corrected values across regenerated output.
      final aligned = reconcileSourceCorrections(
        previousFacts: report.facts,
        previousLines: report.lines,
        newLines: parsedLines,
      );
      next = next.copy(lines: aligned.lines, facts: aligned.corrections);
      final discovered = discoverReportDate(lines);
      next = next.copy(
        eventDate: discovered.date,
        dateIsFallback: discovered.isFallback,
        type: discoverReportCategory(lines),
      );
      if (embeddings.available) {
        announceStep('Building the local search index…');
        final vectors = <String, List<double>>{};
        for (final line in lines) {
          vectors[line.id] = await taskCall(
            () => embeddings.embed(line.text, document: true),
          );
        }
        next = next.copy(
          vectors: vectors,
          embeddingVersion: embeddings.version,
        );
      }
      final hasVisionTranscript = next.lines.any(
        (line) => line.method.contains('vision'),
      );
      final hasSparseText = next.lines.any((l) => l.method == 'text-sparse');
      next = next.copy(
        status: intelligence.available && !hasVisionTranscript && !hasSparseText
            ? ReportStatus.ready
            : ReportStatus.needsReview,
        notice: hasSparseText
            ? 'Some PDF pages have limited readable text. Check the original; retry with a local vision model for image content.'
            : hasVisionTranscript
            ? 'Image text was transcribed by your local model. Check every value against the original. ${next.notice ?? ""}'
            : intelligence.available
            ? next.notice
            : 'Text is searchable locally. Connect the local assistant to prepare Markdown notes.',
      );
      _save(
        data.copy(
          reports: data.reports
              .map(
                (r) => r.id == report.id && r.profileId == report.profileId
                    ? next
                    : r,
              )
              .toList(),
        ),
      );
      final notesGenerated =
          intelligence.available && await _summarizeReport(next, owner);
      if (notesGenerated && embeddings.available && !hasSparseText) {
        _save(finishReportJob(data, report.id, owner.id));
      }
      if (importBelongsInConversation) {
        await _appendTurn(
          ChatEntry(
            'Saved **${report.name}** in memory. ${next.lines.length} source rows are available.',
            hits: next.lines
                .take(2)
                .map((l) => EvidenceHit(next, l, 1))
                .toList(),
          ),
        );
      }
    } on TaskCancelled {
      rethrow;
    } catch (_) {
      checkTaskActive();
      _save(
        data.copy(
          reports: data.reports
              .map(
                (r) => r.id == report.id && r.profileId == report.profileId
                    ? next.copy(
                        status: ReportStatus.needsReview,
                        notice:
                            'Processing stopped locally. Retry after checking your local model setup.',
                      )
                    : r,
              )
              .toList(),
        ),
      );
    }
  }

  Future<bool> _summarizeReport(Report report, Profile owner) async {
    announceStep('Writing report notes as Markdown…');
    final output = await generateReportMarkdown(
      contextualIntelligence(intelligence, owner),
      report,
      owner,
      discovered: ReportDate(
        date: report.eventDate ?? DateTime.now(),
        isFallback: report.dateIsFallback,
      ),
      category: report.type,
      ageAtEvent: report.dateIsFallback
          ? null
          : ageAtEvent(owner, report.eventDate),
      status: announceStep,
    );
    _save(
      data.copy(
        reports: data.reports
            .map(
              (r) => r.id == report.id && r.profileId == report.profileId
                  ? output == null
                        ? report.copy(
                            status: ReportStatus.needsReview,
                            notice:
                                'Report notes could not be linked to their sources. The original is saved; please retry.',
                          )
                        : report.copy(
                            summaryMarkdown: output,
                            modelVersion: 'local:web:markdown-v1',
                            notice: report.notice,
                          )
                  : r,
            )
            .toList(),
      ),
    );
    return output != null;
  }

  @override
  Future<SecondOpinionAudit> recordSecondOpinionExport({
    required String target,
    required List<String> reportIds,
    required String profileId,
    required String sessionId,
  }) async {
    if (!{'copy', 'chatgpt', 'claude'}.contains(target) ||
        busy ||
        profile?.id != profileId ||
        activeSession?.id != sessionId ||
        !data.sessions.any(
          (s) => s.id == sessionId && s.profileId == profileId,
        ) ||
        reportIds.any(
          (id) =>
              !data.reports.any((r) => r.id == id && r.profileId == profileId),
        )) {
      throw StateError(
        'The reviewed export no longer belongs to the active profile.',
      );
    }
    final audit = SecondOpinionAudit(
      id: 'browser-export-${DateTime.now().microsecondsSinceEpoch}',
      profileId: profileId,
      sessionId: sessionId,
      target: target,
      createdAt: DateTime.now(),
      reviewed: true,
      reportIds: List.unmodifiable(reportIds.toSet()),
    );
    _save(data.copy(exports: [...data.exports, audit]));
    return audit;
  }

  @override
  Future<void> importSample(Uint8List bytes) async {
    if (profile == null || busy) return;
    messages.add(
      const ChatEntry(
        'No sample data is bundled. Use the attachment button to add your own report — it stays in this browser tab’s memory and clears on reload.',
      ),
    );
    notifyListeners();
  }

  // Defense in depth: even accidental calls from a native UI path cannot read
  // a personal file or invoke a platform plugin in this preview.
  @override
  Future<void> importFile(PlatformFile file) => attachReport();

  @override
  Future<void> capturePhoto() => attachReport();

  @override
  Future<void> captureReportPages({
    Future<bool> Function(int)? onAnotherPage,
  }) => attachReport();

  @override
  Future<void> installModel(
    PlatformFile file, {
    required bool embedding,
    String family = 'gemma4',
  }) async => _unavailable('Model files belong to the mobile app.');

  @override
  Future<void> setWebKey(String value) async =>
      _unavailable('Web search is disabled in this client. No key is saved.');

  void _unavailable(String message) {
    failure = message;
    notifyListeners();
  }

  Report? _storedOwnedReport(Report supplied) {
    if (supplied.profileId != profile?.id) return null;
    return data.reports
        .where(
          (r) =>
              r.id == supplied.id &&
              r.profileId == profile?.id &&
              r.profileId == supplied.profileId,
        )
        .firstOrNull;
  }

  @override
  Future<Uint8List> original(Report report) async {
    final stored = _storedOwnedReport(report);
    if (stored == null ||
        !_originals.containsKey('${stored.profileId}:${stored.id}')) {
      throw StateError('This source is not in the active profile.');
    }
    return Uint8List.fromList(_originals['${stored.profileId}:${stored.id}']!);
  }

  @override
  Future<void> retry(Report report) async {
    if (profile == null || busy) return;
    final stored = _storedOwnedReport(report);
    if (stored == null) return;
    await runCancellableTask('Reading the saved report…', () async {
      trackTaskReport(stored);
      _save(
        enqueueReportJob(
          data,
          stored.id,
          stored.profileId,
          DateTime.now(),
          resetAttempts: true,
        ),
      );
      await _process(stored);
    });
  }

  @override
  Future<void> correctFact(
    Report report,
    MedicalFact fact,
    String replacement,
  ) async {
    if (busy ||
        _storedOwnedReport(report) == null ||
        replacement.trim().isEmpty) {
      return;
    }
    _save(
      data.copy(
        reports: data.reports.map((current) {
          if (current.id != report.id ||
              current.profileId != report.profileId) {
            return current;
          }
          return current.copy(
            facts: current.facts
                .map(
                  (item) => item.id == fact.id
                      ? item.withValue(replacement.trim())
                      : item,
                )
                .toList(),
            clearSummary: true,
            notice:
                'Correction recorded in memory. Regenerate to refresh the summary; the original stays unchanged.',
          );
        }).toList(),
      ),
    );
  }

  /// Production-equivalent conversation flow against the in-memory vault:
  /// local planner → profile-scoped retrieval → bounded local research →
  /// source-grounded answer. The models are the user's own localhost server.
  @override
  Future<void> ask(String question) => super.ask(question);

  @override
  Future<void> appendConversationEntry(ChatEntry entry) => _appendTurn(entry);
}
