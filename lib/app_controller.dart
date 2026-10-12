import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'domain/agent_plan.dart';
import 'domain/clinical_date.dart';
import 'domain/extraction.dart';
import 'domain/records.dart';
import 'domain/retrieval.dart';
import 'services/local_embeddings.dart';
import 'services/camera_cache.dart';
import 'services/local_intelligence.dart';
import 'services/local_parser.dart';
import 'services/local_file_picker.dart';
import 'services/web_search.dart';
import 'storage/encrypted_vault.dart';

class ChatEntry {
  const ChatEntry(
    this.text, {
    this.isUser = false,
    this.hits = const [],
    this.web = const [],
  });
  final String text;
  final bool isUser;
  final List<EvidenceHit> hits;
  final List<WebSource> web;
}

class AppController extends ChangeNotifier {
  AppController({
    LocalIntelligence? intelligence,
    LocalEmbeddings? embeddings,
    WebSearch? webSearch,
  }) : intelligence = intelligence ?? LocalIntelligence(),
       embeddings = embeddings ?? LocalEmbeddings(),
       webSearch = webSearch ?? WebSearch();
  final LocalIntelligence intelligence;
  final LocalEmbeddings embeddings;
  final WebSearch webSearch;
  final _secure = const FlutterSecureStorage();
  final _uuid = const Uuid();
  late EncryptedVault vault;
  late LocalParser parser;
  late PickerCache pickerCache;
  late CameraCache cameraCache;
  late Directory modelDirectory;
  VaultData data = const VaultData();
  String? activeProfileId, failure;
  String activity = '';
  bool loaded = false, busy = false;
  final messages = <ChatEntry>[];
  bool get isPreview => false;

  Future<void> attachReport() async {
    if (busy) return;
    final file = await pickLocalFile(['pdf', 'png', 'jpg', 'jpeg', 'txt']);
    if (file != null) await importFile(file);
  }

  Profile? get profile =>
      data.profiles.where((p) => p.id == activeProfileId).firstOrNull;
  List<Report> get reports => timelineFor(activeProfileId ?? '', data.reports);

  void initializationFailed() {
    failure =
        'The local document engine could not start. Restart the app to retry.';
    notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/private-vault');
      final keyValue = await _secure.read(key: 'ayumitra-vault-key-v1');
      if (keyValue == null &&
          await File('${directory.path}/index.enc').exists()) {
        throw StateError('The vault key is unavailable.');
      }
      final SecretKey key;
      if (keyValue == null) {
        key = await AesGcm.with256bits().newSecretKey();
        await _secure.write(
          key: 'ayumitra-vault-key-v1',
          value: base64Encode(await key.extractBytes()),
        );
      } else {
        key = SecretKey(base64Decode(keyValue));
      }
      vault = EncryptedVault(directory: directory, key: key);
      await directory.create(recursive: true);
      modelDirectory = Directory('${support.path}/local-models');
      await modelDirectory.create(recursive: true);
      await for (final file in modelDirectory.list()) {
        if (file is File && file.path.endsWith('.importing')) {
          await file.delete();
        }
      }
      pickerCache = await PickerCache.forDevice();
      await pickerCache.clean();
      cameraCache = await CameraCache.forDevice();
      await cameraCache.clean();
      parser = LocalParser(
        Directory('${(await getTemporaryDirectory()).path}/ayumitra-ocr'),
        transcribe: intelligence.transcribeImage,
      );
      await parser.cleanScratch();
      if (Platform.isIOS) {
        await const MethodChannel(
          'app.ayumitra/privacy',
        ).invokeMethod('protectDirectory', {'path': directory.path});
        await const MethodChannel(
          'app.ayumitra/privacy',
        ).invokeMethod('protectDirectory', {'path': modelDirectory.path});
      }
      data = await vault.read();
      // Interrupted jobs remain retryable without losing the original.
      data = data.copy(
        reports: data.reports
            .map(
              (r) => r.status == ReportStatus.processing
                  ? r.copy(
                      status: ReportStatus.needsReview,
                      notice: 'Processing was interrupted. Retry when ready.',
                    )
                  : r,
            )
            .toList(),
      );
      await vault.save(data);
      activeProfileId = data.profiles.firstOrNull?.id;
      webSearch.apiKey = await _secure.read(key: 'ayumitra-web-search-key');
      if (data.modelPath != null) {
        try {
          await intelligence.configure(data.modelPath!, data.modelType);
        } catch (_) {
          failure =
              'Your local assistant model could not be restored. Re-select it in settings.';
        }
      }
      if (data.embeddingPath != null && data.embeddingVersion != null) {
        try {
          await embeddings.load(data.embeddingPath!, data.embeddingVersion!);
        } catch (_) {
          failure =
              'EmbeddingGemma 2 is not available. Keyword search remains local.';
        }
      }
      loaded = true;
    } catch (_) {
      failure =
          'The encrypted vault could not be opened. Existing data has been kept. Restart to retry.';
    }
    notifyListeners();
  }

  Future<void> _commit(VaultData next) async {
    await vault.save(next);
    data = next;
    notifyListeners();
  }

  Future<void> _replace(Report report) => _commit(
    data.copy(
      reports: data.reports
          .map(
            (r) => r.id == report.id && r.profileId == report.profileId
                ? report
                : r,
          )
          .toList(),
    ),
  );

  Future<void> _work(String label, Future<void> Function() task) async {
    if (busy) return;
    busy = true;
    activity = label;
    failure = null;
    notifyListeners();
    try {
      await task();
    } catch (_) {
      failure =
          'This action could not finish locally. Your saved records have been kept; please retry.';
    } finally {
      busy = false;
      activity = '';
      notifyListeners();
    }
  }

  Future<void> createProfile(
    String name,
    int age,
    String history,
    bool isChild,
  ) => _work('Creating your private history…', () async {
    if (name.trim().isEmpty || age < 0 || age > 125) {
      throw const FormatException('Invalid profile.');
    }
    final next = Profile(
      id: _uuid.v4(),
      name: name.trim(),
      age: age,
      ageRecordedAt: DateTime.now(),
      history: history.trim(),
      isChild: isChild,
    );
    await _commit(data.copy(profiles: [...data.profiles, next]));
    activeProfileId = next.id;
    messages.clear();
  });

  void selectProfile(String id) {
    if (busy || !data.profiles.any((p) => p.id == id)) return;
    activeProfileId = id;
    messages.clear();
    notifyListeners();
  }

  Future<void> importFile(PlatformFile file) =>
      _work('Saving and reading your report…', () async {
        try {
          if (profile == null) return;
          final ext = (file.extension ?? '').toLowerCase();
          if (!{'pdf', 'png', 'jpg', 'jpeg', 'txt'}.contains(ext) ||
              (await file.length() ?? 0) > 30 * 1024 * 1024) {
            failure = 'Choose a PDF, PNG, JPG, or text file up to 30 MB.';
            return;
          }
          if (!{'file', 'content'}.contains(file.uri.scheme)) {
            failure = 'Choose a file stored on this device.';
            return;
          }
          final buffer = BytesBuilder(copy: false);
          await for (final part in file.readAsByteStream()) {
            buffer.add(part);
            if (buffer.length > 30 * 1024 * 1024) {
              throw const FormatException('Report is too large.');
            }
          }
          final bytes = buffer.takeBytes();
          await _importBytes(
            file.name,
            ext,
            bytes,
            onSaved: () => pickerCache.remove(file),
          );
        } finally {
          await pickerCache.remove(file);
        }
      });

  Future<void> importSample(Uint8List bytes) => _work(
    'Adding a synthetic example…',
    () => _importBytes('Synthetic blood report.txt', 'txt', bytes),
  );

  /// Photograph a report with the rear camera into the active profile's vault.
  /// On-device only: the photo follows the same encrypted import path as files.
  Future<void> capturePhoto() => _work('Saving your photo…', () async {
    if (profile == null) return;
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      requestFullMetadata: false,
    );
    if (photo == null) {
      await cameraCache.clean();
      return;
    }
    try {
      if (await photo.length() > 30 * 1024 * 1024) {
        throw const FormatException('Photo is too large.');
      }
      final bytes = await photo.readAsBytes();
      if (bytes.lengthInBytes > 30 * 1024 * 1024) {
        throw const FormatException('Photo is too large.');
      }
      final candidate = photo.path.split('.').last.toLowerCase();
      final ext = RegExp(r'^[a-z0-9]{1,8}$').hasMatch(candidate)
          ? candidate
          : 'image';
      final stamp = DateTime.now().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      await _importBytes(
        'Camera report $stamp.$ext',
        ext,
        bytes,
        onSaved: () => cameraCache.remove(photo.path),
      );
    } finally {
      await cameraCache.remove(photo.path);
    }
  });

  Future<void> _importBytes(
    String name,
    String extension,
    Uint8List bytes, {
    Future<void> Function()? onSaved,
  }) async {
    final current = profile!;
    final digest = sha256.convert(bytes).toString();
    if (data.reports.any(
      (r) => r.profileId == current.id && r.digest == digest,
    )) {
      failure = 'This report is already saved for ${current.name}.';
      return;
    }
    final report = Report(
      id: _uuid.v4(),
      profileId: current.id,
      name: name,
      extension: extension,
      digest: digest,
      importedAt: DateTime.now(),
    );
    await vault.saveOriginal(report, bytes);
    await _commit(data.copy(reports: [...data.reports, report]));
    await onSaved?.call();
    await _process(report);
  }

  Future<void> retry(Report report) =>
      _work('Reading the saved report…', () => _process(report));

  Future<void> _process(Report report) async {
    final owner = profile;
    if (owner == null || owner.id != report.profileId) {
      throw StateError('Profile access denied.');
    }
    var next = report.copy(status: ReportStatus.processing, clearSummary: true);
    await _replace(next);
    try {
      final bytes = await vault.readOriginal(report, owner.id);
      final lines = await parser.parse(report, bytes);
      if (lines.isEmpty) {
        await _replace(
          next.copy(
            status: ReportStatus.needsReview,
            notice:
                'No readable text was found. The original is saved; try a clearer scan.',
          ),
        );
        return;
      }
      final aligned = reconcileSourceCorrections(
        previousFacts: report.facts,
        previousLines: report.lines,
        newLines: lines,
      );
      next = next.copy(
        lines: aligned.lines,
        facts: aligned.corrections,
        vectors: {},
        status: ReportStatus.needsReview,
      );
      await _replace(next);
      if (intelligence.available) {
        activity = 'Organizing the report by date and category…';
        notifyListeners();
        final organizerLines = [
          ...lines.take(16),
          ...lines
              .skip(16)
              .where(
                (l) => RegExp(
                  r'\b(?:date|report|collection|visit|issued|vaccination)\b',
                  caseSensitive: false,
                ).hasMatch(l.text),
              )
              .take(8),
        ];
        final organized =
            jsonDecode(
                  await intelligence.generate(
                    organizerPrompt,
                    jsonEncode({
                      'sourceLines': organizerLines
                          .map((x) => x.toJson())
                          .toList(),
                    }),
                  ),
                )
                as Map;
        const categories = {
          'lab',
          'prescription',
          'radiology',
          'discharge',
          'vaccination',
          'growth',
          'note',
          'other',
        };
        DateTime? event;
        if (organized['eventDate'] is String &&
            organized['dateEvidence'] is String) {
          final source = lines
              .where((l) => l.id == organized['dateSourceLineId'])
              .firstOrNull;
          final dateText = organized['eventDate'] as String;
          if (source != null) {
            event = validateClinicalDate(
              proposed: dateText,
              evidence: organized['dateEvidence'] as String,
              source: source,
              now: DateTime.now(),
            );
          }
        }

        next = next.copy(
          type: categories.contains(organized['type'])
              ? organized['type']
              : 'other',
          eventDate: event,
          clearEventDate: event == null,
        );
        final facts = <MedicalFact>[];
        var rejected = 0;
        for (var start = 0; start < lines.length; start += 12) {
          activity =
              'Extracting facts (${start + 1}/${lines.length} source rows)…';
          notifyListeners();
          final batch = lines.skip(start).take(12).toList();
          final output = await intelligence.generate(
            extractorPrompt,
            jsonEncode({'sourceLines': batch.map((x) => x.toJson()).toList()}),
          );
          final result = validateExtraction(output, batch);
          facts.addAll(result.facts);
          rejected += result.rejected;
        }
        next = next.copy(
          facts: preserveCorrections(facts, aligned.corrections),
          modelVersion: 'local:${data.modelType}:prompts-v1',
          notice: rejected > 0
              ? '$rejected unsupported proposals were excluded. Review the source.'
              : null,
        );
      }
      if (embeddings.available) {
        activity = 'Building the local search index…';
        notifyListeners();
        final vectors = <String, List<double>>{};
        for (final line in lines) {
          vectors[line.id] = await embeddings.embed(line.text, document: true);
        }
        next = next.copy(
          vectors: vectors,
          embeddingVersion: embeddings.version,
        );
      }
      final hasVisionTranscript = next.lines.any(
        (line) => line.method.contains('vision'),
      );
      final hasSparseText = lines.any((line) => line.method == 'text-sparse');
      next = next.copy(
        status: intelligence.available && !hasVisionTranscript && !hasSparseText
            ? ReportStatus.ready
            : ReportStatus.needsReview,
        notice: hasSparseText
            ? 'Only limited PDF text could be read. Clinical content may be in page images; retry with a vision model and check the original.'
            : hasVisionTranscript
            ? 'Image text was transcribed by the local model. Check every value against the original. ${next.notice ?? ""}'
            : intelligence.available
            ? next.notice
            : 'Text is searchable locally. Add an assistant model to extract structured facts.',
      );
      await _replace(next);
      if (intelligence.available && next.facts.isNotEmpty) {
        await _summarizeReport(next, owner);
      }
      messages.add(
        ChatEntry(
          'Saved **${report.name}** on this phone. ${next.lines.length} source rows are available.',
          hits: next.lines.take(2).map((l) => EvidenceHit(next, l, 1)).toList(),
        ),
      );
    } catch (_) {
      await _replace(
        next.copy(
          status: ReportStatus.needsReview,
          notice:
              'Processing stopped locally. The original and any saved text are available. Retry after checking model setup.',
        ),
      );
    }
  }

  Future<void> _summarizeReport(Report report, Profile owner) async {
    activity = 'Writing a source-linked Markdown summary…';
    notifyListeners();
    final sources = report.facts
        .map(
          (f) => {
            'sourceId': '${report.id}/${f.sourceLineId}',
            'sourceMethod': report.lines
                .where((l) => l.id == f.sourceLineId)
                .firstOrNull
                ?.method,
            ...f.toJson(),
          },
        )
        .toList();
    final output = await intelligence.generate(
      summaryPrompt,
      jsonEncode({
        'task': 'Summarize this report',
        'category': report.type,
        'eventDate': report.eventDate?.toIso8601String(),
        'estimatedAgeAtEvent': ageAtEvent(owner, report.eventDate),
        'facts': sources,
      }),
    );
    if (!validCitations(
      output,
      sources.map((x) => x['sourceId'] as String).toSet(),
    )) {
      await _replace(
        report.copy(
          notice:
              'Summary citations could not be validated. Review the extracted facts.',
        ),
      );
      return;
    }
    await _replace(report.copy(summaryMarkdown: output));
  }

  Future<void> correctFact(
    Report report,
    MedicalFact fact,
    String replacement,
  ) => _work('Saving your correction…', () async {
    if (report.profileId != profile?.id || replacement.trim().isEmpty) {
      throw StateError('Invalid correction.');
    }
    final current = data.reports.firstWhere(
      (r) => r.id == report.id && r.profileId == report.profileId,
    );
    await _replace(
      current.copy(
        facts: current.facts
            .map((f) => f.id == fact.id ? f.withValue(replacement.trim()) : f)
            .toList(),
        clearSummary: true,
        notice:
            'Your correction is saved. The previous summary was cleared; regenerate to update it.',
      ),
    );
  });

  Future<Uint8List> original(Report report) =>
      vault.readOriginal(report, profile!.id);

  Future<void> installModel(
    PlatformFile file, {
    required bool embedding,
    String family = 'gemma4',
  }) => _work(
    embedding
        ? 'Loading EmbeddingGemma 2 locally…'
        : 'Preparing your local assistant…',
    () async {
      File? staged;
      try {
        if (!{'file', 'content'}.contains(file.uri.scheme) ||
            file.extension?.toLowerCase() != 'litertlm') {
          failure = 'Choose a .litertlm model file stored on this device.';
          return;
        }
        final source = File('${modelDirectory.path}/${_uuid.v4()}.importing');
        staged = source;
        final sink = source.openWrite();
        try {
          await sink.addStream(file.readAsByteStream());
        } finally {
          await sink.close();
        }
        final fingerprint = (await sha256.bind(source.openRead()).first)
            .toString();
        final target = File('${modelDirectory.path}/$fingerprint.litertlm');
        if (!await target.exists()) {
          await source.rename(target.path);
        } else {
          await source.delete();
        }
        if (embedding) {
          await embeddings.load(target.path, fingerprint);
          await _commit(
            data.copy(
              embeddingPath: target.path,
              embeddingVersion: fingerprint,
            ),
          );
          // Reindex originals on demand. Old vectors never enter a new model's search.
          for (final report in reports.where((r) => r.lines.isNotEmpty)) {
            final vectors = <String, List<double>>{};
            for (final line in report.lines) {
              vectors[line.id] = await embeddings.embed(
                line.text,
                document: true,
              );
            }
            await _replace(
              report.copy(
                vectors: vectors,
                embeddingVersion: embeddings.version,
              ),
            );
          }
        } else {
          await intelligence.configure(target.path, family);
          await _commit(data.copy(modelPath: target.path, modelType: family));
        }
      } finally {
        if (staged != null && await staged.exists()) await staged.delete();
        await pickerCache.remove(file);
      }
    },
  );

  Future<void> setWebKey(String value) => _work(
    'Saving search settings…',
    () async {
      await _secure.write(key: 'ayumitra-web-search-key', value: value.trim());
      webSearch.apiKey = value.trim();
    },
  );

  Future<void> ask(
    String question,
  ) => _work('Thinking on this phone…', () async {
    final owner = profile;
    if (owner == null || question.trim().isEmpty) return;
    final recentUserRequests = messages
        .where((m) => m.isUser)
        .toList()
        .reversed
        .take(6)
        .toList()
        .reversed
        .map((m) => m.text.length > 1000 ? m.text.substring(0, 1000) : m.text)
        .toList();
    messages.add(ChatEntry(question.trim(), isUser: true));
    notifyListeners();
    if (!intelligence.available) {
      final hits = retrieve(
        profileId: owner.id,
        reports: data.reports,
        query: question,
      );
      messages.add(
        ChatEntry(
          hits.isEmpty
              ? 'Add a local assistant model in settings to start the conversation. Your reports stay on this phone.'
              : 'The assistant model is not set up yet. These are matching saved excerpts, using local keyword search.',
          hits: hits,
        ),
      );
      return;
    }
    // Reports/web results never re-enter the planner: their instructions cannot
    // request new tool calls. Only the USER request determines this bounded plan.
    final actions = validateAgentPlan(
      await intelligence.generate(
        plannerPrompt,
        jsonEncode({
          'userRequest': question,
          'recentUserRequests': recentUserRequests,
          'webSearchAvailable': webSearch.available,
        }),
      ),
    );
    if (actions.length == 1 && actions.first.tool == 'conversation') {
      messages.add(
        ChatEntry(
          await intelligence.generate(
            'You are Ayumitra, an English-speaking on-device medical companion. '
            'For this turn answer greetings or explain app capabilities only. '
            'Do not invent medical facts, tool results, or completed actions.',
            question,
          ),
        ),
      );
      return;
    }
    final hits = <EvidenceHit>[];
    final sources = <WebSource>[];
    final toolNotices = <String>[];
    bool historyRequested = false;
    for (final action in actions) {
      if (action.tool == 'search_records') {
        historyRequested = true;
        List<double>? vector;
        final query = action.query.isEmpty ? question : action.query;
        if (embeddings.available) {
          try {
            vector = await embeddings.embed(query);
          } catch (_) {
            toolNotices.add(
              'Semantic search failed locally; keyword matches were used.',
            );
          }
        }
        final found = retrieve(
          profileId: owner.id,
          reports: data.reports,
          query: query,
          queryVector: vector,
          embeddingVersion: embeddings.version,
        );
        for (final hit in found) {
          if (!hits.any((h) => h.citation == hit.citation)) hits.add(hit);
        }
      } else if (action.tool == 'web_search') {
        if (!publicQueryAllowed(action.query, owner)) {
          toolNotices.add(
            'The proposed web query contained personal details and was not sent.',
          );
          continue;
        }
        if (!webSearch.available) {
          toolNotices.add(
            'Web search needs a Brave Search API key in settings. No cloud AI fallback was used.',
          );
          continue;
        }
        activity = 'Looking up public information…';
        notifyListeners();
        try {
          final found = await webSearch.search(action.query);
          for (final source in found) {
            if (!sources.any((s) => s.url == source.url)) {
              sources.add(
                WebSource(
                  id: 'web-${sources.length + 1}',
                  title: source.title,
                  url: source.url,
                  excerpt: source.excerpt,
                  retrievedAt: source.retrievedAt,
                ),
              );
            }
          }
        } catch (_) {
          toolNotices.add(
            'Web search is unavailable. No remote AI fallback was used.',
          );
        }
      }
    }
    final includeHistory = historyRequested && owner.history.isNotEmpty;
    if (hits.isEmpty && sources.isEmpty && !includeHistory) {
      messages.add(
        ChatEntry(
          toolNotices.isEmpty
              ? 'I couldn’t find supporting information for that request.'
              : toolNotices.join('\n\n'),
        ),
      );
      return;
    }
    activity = 'Writing your answer locally…';
    notifyListeners();
    final allowed = {
      ...hits.map((h) => h.citation),
      ...sources.map((s) => s.id),
      if (includeHistory) 'user-history',
    };
    final answer = await intelligence.generate(
      summaryPrompt,
      jsonEncode({
        'question': question,
        'recentUserRequestsForContextOnly': recentUserRequests,
        'toolNotices': toolNotices,
        'userProvidedHistory': includeHistory
            ? {'sourceId': 'user-history', 'text': owner.history}
            : null,
        'evidence': hits
            .map(
              (h) => {
                'sourceId': h.citation,
                'reportName': h.report.name,
                'category': h.report.type,
                'eventDate': h.report.eventDate?.toIso8601String(),
                'estimatedAgeAtEvent': ageAtEvent(owner, h.report.eventDate),
                'text': h.line.text,
                'sourceMethod': h.line.method,
                'facts': h.report.facts
                    .where((f) => f.sourceLineId == h.line.id)
                    .map((f) => f.toJson())
                    .toList(),
              },
            )
            .toList(),
        'webSources': sources.map((s) => s.toJson()).toList(),
      }),
    );
    messages.add(
      ChatEntry(
        validCitations(answer, allowed)
            ? [answer, ...toolNotices].join('\n\n')
            : 'I could not validate the answer’s source links. Here is the retrieved evidence.',
        hits: hits,
        web: sources,
      ),
    );
  });
}
