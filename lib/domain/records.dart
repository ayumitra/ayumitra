import 'dart:convert';

import 'conversations.dart';

typedef Json = Map<String, dynamic>;

enum ReportStatus { saved, processing, needsReview, ready, failed }

class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.history,
    this.isChild = true,
    this.dateOfBirth,
    this.age,
    this.ageRecordedAt,
  });
  final String id, name, history;
  final bool isChild;
  // Preferred dating: exact date of birth. Legacy profiles carry an integer
  // age with its reference date instead. One of the two must be present;
  // a missing DOB is never invented from a legacy age.
  final DateTime? dateOfBirth;
  final int? age;
  final DateTime? ageRecordedAt;
  Json toJson() => {
    'id': id,
    'name': name,
    'history': history,
    'isChild': isChild,
    'dateOfBirth': dateOfBirth?.toIso8601String(),
    'age': age,
    'ageRecordedAt': ageRecordedAt?.toIso8601String(),
  };
  factory Profile.fromJson(Json j) {
    final dob = j['dateOfBirth'] == null
        ? null
        : DateTime.parse(j['dateOfBirth'] as String);
    // Stored data is never trusted blindly: a future DOB is rejected rather
    // than decoded, and no legacy age is invented to replace it.
    if (validateDateOfBirth(dob) != null) {
      throw const FormatException('Invalid date of birth.');
    }
    return Profile(
      id: j['id'] as String,
      name: j['name'] as String,
      history: j['history'] as String,
      isChild: j['isChild'] as bool? ?? true,
      dateOfBirth: dob,
      age: j['age'] as int?,
      ageRecordedAt: j['ageRecordedAt'] == null
          ? null
          : DateTime.parse(j['ageRecordedAt'] as String),
    );
  }
}

/// Pure DOB check for forms and imports. Null means absent (legacy), not
/// invalid. Returns an error message, or null when acceptable.
String? validateDateOfBirth(DateTime? dob, {DateTime? now}) {
  if (dob == null) return null;
  if (dob.isAfter(now ?? DateTime.now())) {
    return 'Date of birth cannot be in the future.';
  }
  return null;
}

class SourceLine {
  const SourceLine({
    required this.id,
    required this.page,
    required this.text,
    this.bounds,
    this.pageWidth,
    this.pageHeight,
    this.method = 'text',
  });
  final String id, text, method;
  final int page;
  // Top-left origin, in the coordinate space defined by pageWidth/pageHeight.
  final List<double>? bounds;
  final double? pageWidth, pageHeight;
  Json toJson() => {
    'id': id,
    'page': page,
    'text': text,
    'bounds': bounds,
    'pageWidth': pageWidth,
    'pageHeight': pageHeight,
    'method': method,
  };
  factory SourceLine.fromJson(Json j) => SourceLine(
    id: j['id'],
    page: j['page'],
    text: j['text'],
    bounds: (j['bounds'] as List?)?.map((x) => (x as num).toDouble()).toList(),
    pageWidth: (j['pageWidth'] as num?)?.toDouble(),
    pageHeight: (j['pageHeight'] as num?)?.toDouble(),
    method: j['method'] ?? 'text',
  );
}

class MedicalFact {
  const MedicalFact({
    required this.id,
    required this.kind,
    required this.name,
    required this.value,
    required this.unit,
    required this.range,
    required this.sourceLineId,
    required this.evidence,
    this.corrected = false,
    this.originalValue,
  });
  final String id, kind, name, value, unit, range, sourceLineId, evidence;
  final bool corrected;
  final String? originalValue;
  MedicalFact withValue(String replacement) => MedicalFact(
    id: id,
    kind: kind,
    name: name,
    value: replacement,
    unit: unit,
    range: range,
    sourceLineId: sourceLineId,
    evidence: evidence,
    corrected: true,
    originalValue: originalValue ?? value,
  );
  Json toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'value': value,
    'unit': unit,
    'range': range,
    'sourceLineId': sourceLineId,
    'evidence': evidence,
    'corrected': corrected,
    'originalValue': originalValue,
  };
  factory MedicalFact.fromJson(Json j) => MedicalFact(
    id: j['id'],
    kind: j['kind'],
    name: j['name'],
    value: j['value'],
    unit: j['unit'],
    range: j['range'],
    sourceLineId: j['sourceLineId'],
    evidence: j['evidence'],
    corrected: j['corrected'] ?? false,
    originalValue: j['originalValue'],
  );
}

class Report {
  const Report({
    required this.id,
    required this.profileId,
    required this.name,
    required this.extension,
    required this.digest,
    required this.importedAt,
    this.eventDate,
    this.status = ReportStatus.saved,
    this.lines = const [],
    this.facts = const [],
    this.type = 'Report',
    this.notice,
    this.vectors = const {},
    this.embeddingVersion,
    this.modelVersion,
    this.summaryMarkdown,
  });
  final String id, profileId, name, extension, digest, type;
  final DateTime importedAt;
  final DateTime? eventDate;
  final ReportStatus status;
  final List<SourceLine> lines;
  final List<MedicalFact> facts;
  final String? notice, embeddingVersion, modelVersion, summaryMarkdown;
  final Map<String, List<double>> vectors;
  Report copy({
    ReportStatus? status,
    List<SourceLine>? lines,
    List<MedicalFact>? facts,
    String? type,
    String? notice,
    Map<String, List<double>>? vectors,
    String? embeddingVersion,
    String? modelVersion,
    DateTime? eventDate,
    String? summaryMarkdown,
    bool clearSummary = false,
    bool clearEventDate = false,
  }) => Report(
    id: id,
    profileId: profileId,
    name: name,
    extension: extension,
    digest: digest,
    importedAt: importedAt,
    eventDate: clearEventDate ? null : eventDate ?? this.eventDate,
    status: status ?? this.status,
    lines: lines ?? this.lines,
    facts: facts ?? this.facts,
    type: type ?? this.type,
    notice: notice,
    vectors: vectors ?? this.vectors,
    embeddingVersion: embeddingVersion ?? this.embeddingVersion,
    modelVersion: modelVersion ?? this.modelVersion,
    summaryMarkdown: clearSummary
        ? null
        : summaryMarkdown ?? this.summaryMarkdown,
  );
  Json toJson() => {
    'id': id,
    'profileId': profileId,
    'name': name,
    'extension': extension,
    'digest': digest,
    'importedAt': importedAt.toIso8601String(),
    'eventDate': eventDate?.toIso8601String(),
    'status': status.name,
    'lines': lines.map((x) => x.toJson()).toList(),
    'facts': facts.map((x) => x.toJson()).toList(),
    'type': type,
    'notice': notice,
    'vectors': vectors,
    'embeddingVersion': embeddingVersion,
    'modelVersion': modelVersion,
    'summaryMarkdown': summaryMarkdown,
  };
  factory Report.fromJson(Json j) => Report(
    id: j['id'],
    profileId: j['profileId'],
    name: j['name'],
    extension: j['extension'],
    digest: j['digest'],
    importedAt: DateTime.parse(j['importedAt']),
    eventDate: j['eventDate'] == null ? null : DateTime.parse(j['eventDate']),
    status: ReportStatus.values.byName(j['status']),
    lines: (j['lines'] as List)
        .map((x) => SourceLine.fromJson(Json.from(x)))
        .toList(),
    facts: (j['facts'] as List)
        .map((x) => MedicalFact.fromJson(Json.from(x)))
        .toList(),
    type: j['type'],
    notice: j['notice'],
    vectors: (j['vectors'] as Map? ?? {}).map(
      (k, v) => MapEntry(
        k as String,
        (v as List).map((n) => (n as num).toDouble()).toList(),
      ),
    ),
    embeddingVersion: j['embeddingVersion'],
    modelVersion: j['modelVersion'],
    summaryMarkdown: j['summaryMarkdown'],
  );
}

String ageAtEvent(Profile profile, DateTime? event) {
  if (event == null) return 'Age at event unknown';
  final dob = profile.dateOfBirth;
  if (dob != null) {
    if (event.isBefore(dob)) return 'Age at event unknown';
    var totalMonths = (event.year - dob.year) * 12 + (event.month - dob.month);
    if (event.day < dob.day) totalMonths -= 1;
    if (totalMonths < 0) return 'Age at event unknown';
    // Exact calendar age from DOB: years from age 1, months for infants.
    if (totalMonths >= 12) return 'Age ${totalMonths ~/ 12}';
    return 'Age $totalMonths months';
  }
  final recordedAt = profile.ageRecordedAt;
  final age = profile.age;
  if (recordedAt == null || age == null) return 'Age at event unknown';
  final elapsed = event.difference(recordedAt).inDays / 365.2425;
  // Integer age describes a one-year interval. Use its midpoint for an
  // explicitly approximate label; never turn it into an inferred birth date.
  final estimated = age + .5 + elapsed;
  if (estimated < 0) return 'Age at event unknown';
  return 'About age ${estimated.floor()}';
}

List<Report> timelineFor(
  String profileId,
  List<Report> reports, {
  String? category,
}) {
  final result = reports
      .where(
        (r) =>
            r.profileId == profileId &&
            (category == null || r.type == category),
      )
      .toList();
  result.sort((a, b) {
    if (a.eventDate == null && b.eventDate == null) {
      return b.importedAt.compareTo(a.importedAt);
    }
    if (a.eventDate == null) return 1;
    if (b.eventDate == null) return -1;
    return b.eventDate!.compareTo(a.eventDate!);
  });
  return result;
}

/// Metadata for one explicit-tap second-opinion export. The pack content is
/// never logged — only the target, date, session, and report ids.
class SecondOpinionAudit {
  const SecondOpinionAudit({
    required this.id,
    required this.profileId,
    required this.sessionId,
    required this.target,
    required this.reportIds,
    required this.reviewed,
    required this.createdAt,
  });
  final String id, profileId, sessionId, target;
  final List<String> reportIds;
  final bool reviewed;
  final DateTime createdAt;
  Json toJson() => {
    'id': id,
    'profileId': profileId,
    'sessionId': sessionId,
    'target': target,
    'reportIds': reportIds,
    'reviewed': reviewed,
    'createdAt': createdAt.toIso8601String(),
  };
  factory SecondOpinionAudit.fromJson(Json j) => SecondOpinionAudit(
    id: j['id'] as String,
    profileId: j['profileId'] as String,
    sessionId: j['sessionId'] as String,
    target: j['target'] as String,
    reportIds: (j['reportIds'] as List? ?? []).cast<String>(),
    reviewed: j['reviewed'] as bool? ?? false,
    createdAt: DateTime.parse(j['createdAt'] as String),
  );
}

class VaultData {
  const VaultData({
    this.profiles = const [],
    this.reports = const [],
    this.sessions = const [],
    this.memories = const [],
    this.exports = const [],
    this.modelPath,
    this.modelType = 'gemma4',
    this.embeddingPath,
    this.embeddingVersion,
    this.activeProfileId,
    this.activeSessionId,
    this.activeSessionByProfile = const {},
  });
  final List<Profile> profiles;
  final List<Report> reports;
  final List<ConversationSession> sessions;
  final List<ConversationMemory> memories;
  // Explicit-tap second-opinion audit log (metadata only, never pack content).
  final List<SecondOpinionAudit> exports;
  final String? modelPath, embeddingPath, embeddingVersion;
  final String modelType;
  final String? activeProfileId, activeSessionId;
  // Selected conversation per profile. Managed explicitly by the controller;
  // the clear flags below touch only the scalar ids, never this map.
  final Map<String, String> activeSessionByProfile;
  VaultData copy({
    List<Profile>? profiles,
    List<Report>? reports,
    List<ConversationSession>? sessions,
    List<ConversationMemory>? memories,
    List<SecondOpinionAudit>? exports,
    String? modelPath,
    String? modelType,
    String? embeddingPath,
    String? embeddingVersion,
    String? activeProfileId,
    String? activeSessionId,
    Map<String, String>? activeSessionByProfile,
    bool clearActiveSession = false,
    bool clearActiveProfile = false,
  }) => VaultData(
    profiles: profiles ?? this.profiles,
    reports: reports ?? this.reports,
    sessions: sessions ?? this.sessions,
    memories: memories ?? this.memories,
    exports: exports ?? this.exports,
    modelPath: modelPath ?? this.modelPath,
    modelType: modelType ?? this.modelType,
    embeddingPath: embeddingPath ?? this.embeddingPath,
    embeddingVersion: embeddingVersion ?? this.embeddingVersion,
    activeSessionByProfile:
        activeSessionByProfile ?? this.activeSessionByProfile,
    activeProfileId: clearActiveProfile
        ? null
        : activeProfileId ?? this.activeProfileId,
    activeSessionId: clearActiveSession || clearActiveProfile
        ? null
        : activeSessionId ?? this.activeSessionId,
  );
  Json toJson() => {
    'schema': 2,
    'profiles': profiles.map((x) => x.toJson()).toList(),
    'reports': reports.map((x) => x.toJson()).toList(),
    'sessions': sessions.map((x) => x.toJson()).toList(),
    'memories': memories.map((x) => x.toJson()).toList(),
    'exports': exports.map((x) => x.toJson()).toList(),
    'modelPath': modelPath,
    'modelType': modelType,
    'embeddingPath': embeddingPath,
    'embeddingVersion': embeddingVersion,
    'activeProfileId': activeProfileId,
    'activeSessionId': activeSessionId,
    'activeSessionByProfile': activeSessionByProfile,
  };
  factory VaultData.decode(String text) {
    final j = jsonDecode(text) as Json;
    final schema = j['schema'];
    if (schema != 1 && schema != 2) {
      throw const FormatException('Unsupported vault version.');
    }
    return VaultData(
      profiles: (j['profiles'] as List)
          .map((x) => Profile.fromJson(Json.from(x)))
          .toList(),
      reports: (j['reports'] as List)
          .map((x) => Report.fromJson(Json.from(x)))
          .toList(),
      sessions: (j['sessions'] as List? ?? [])
          .map((x) => ConversationSession.fromJson(Json.from(x)))
          .toList(),
      memories: (j['memories'] as List? ?? [])
          .map((x) => ConversationMemory.fromJson(Json.from(x)))
          .toList(),
      exports: (j['exports'] as List? ?? [])
          .map((x) => SecondOpinionAudit.fromJson(Json.from(x)))
          .toList(),
      modelPath: j['modelPath'],
      modelType: j['modelType'] ?? 'gemma4',
      embeddingPath: j['embeddingPath'],
      embeddingVersion: j['embeddingVersion'],
      activeProfileId: j['activeProfileId'],
      activeSessionId: j['activeSessionId'],
      activeSessionByProfile: (j['activeSessionByProfile'] as Map? ?? {}).map(
        (k, v) => MapEntry(k as String, v as String),
      ),
    );
  }
}
