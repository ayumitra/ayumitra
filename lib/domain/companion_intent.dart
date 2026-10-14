import 'records.dart';

/// Request classification is deliberately about language and intent, rather
/// than a list of medical conditions. It must not turn an instruction into a
/// patient-reported observation simply because it contains a measurement.
bool isAssistantRequest(String request) {
  var text = request.trim();
  text = text.replaceFirst(
    RegExp(
      r'^(?:please\s+)?(?:remember|record|save|log|note|add|update)(?:\s+that)?\s+',
      caseSensitive: false,
    ),
    '',
  );
  if (text.isEmpty) return false;
  if (_isCompositionRequest(text)) return true;
  if (text.endsWith('?') || _questionStart.hasMatch(text)) return true;
  return _requestStart.hasMatch(text) ||
      RegExp(
        r'\b(?:i (?:would like|want|need) (?:you to |to )?|can you |could you |would you |will you |please )(?:help me )?(?:compose|create|craft|write|compile|summari[sz]e|draft|find|show|explain|generate|prepare|make|compare|review|search|look|tell|give|describe|delete|remove)\b',
        caseSensitive: false,
      ).hasMatch(text);
}

bool isHealthReportRequest(String request) =>
    _isCompositionRequest(request) &&
    RegExp(
      r'\b(?:health|medical|patient|clinical|wellness)\s+(?:history\s+)?(?:report|summary|overview|record|draft)\b|\b(?:report|summary|overview)\s+(?:of|about|on)\s+(?:(?:my|our|their|the|this|his|her)\s+)?(?:health|medical|history)\b|\b(?:summari[sz]e|compile)\s+(?:(?:my|our|their|the|this|his|her)\s+)?(?:health|medical)\s+history\b',
      caseSensitive: false,
    ).hasMatch(request);

/// Drafting includes summaries, letters and handover notes; it does not require
/// uploaded evidence to be useful. Provenance is attached during composition.
bool isDraftRequest(String request) {
  if (!_isCompositionRequest(request)) return false;
  if (isHealthReportRequest(request)) return true;
  // Summarizing a previously saved note is a private recall answer, while
  // requests to create a health report/letter/brief use the composition role.
  final summarizingSavedContext = RegExp(
    r'^(?:(?:please|kindly)\s+)?(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?summari[sz]e\s+(?:my|our|the|that|these|earlier|previous)\b[\s\S]*\b(?:notes?|messages?|chats?|conversations?|memories|memory)\b',
    caseSensitive: false,
  ).hasMatch(request.trim());
  return !summarizingSavedContext;
}

/// Mentioning a report or asking how to write one is an explanation request,
/// not permission to compose a document. Require an actual composition command
/// or a direct request for a document; verbs inside "how to write" do not count.
bool _isCompositionRequest(String request) {
  final text = request.trim().replaceFirst(
    RegExp(r'^(?:hi|hello|hey)[,!]?\s+', caseSensitive: false),
    '',
  );
  const verb =
      r'(?:compose|create|craft|write|compile|summari[sz]e|draft|generate|prepare|make)';
  if (RegExp(
    r'^(?:(?:please|kindly)\s+)?(?:help\s+me\s+)?' + verb + r'\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return true;
  }
  if (RegExp(
    r"^(?:(?:please|kindly)\s+)?(?:(?:can|could|would|will)\s+you\s+(?:(?:please|kindly)\s+)?(?:help\s+me\s+)?|i\s+(?:would\s+like|want|need)\s+(?:you\s+to\s+|to\s+)|i['’]d\s+like\s+(?:you\s+to\s+|to\s+)|let['’]s\s+)" +
        verb +
        r'\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return true;
  }
  return RegExp(
    r"^(?:(?:please|kindly)\s+)?(?:i\s+(?:would\s+like|want|need)|i['’]d\s+like|(?:can|could)\s+i\s+(?:get|have))\s+(?:a|an|the|my)\s+(?:(?:health|medical|clinical|patient|wellness|second-opinion|handover)\s+)*(?:report|summary|overview|letter|brief|draft|note)\b",
    caseSensitive: false,
  ).hasMatch(text);
}

/// General explanations can use model knowledge and public sources. Questions
/// asking for a person's recorded result instead need their private history.
/// These heuristics are routing hints, never a substitute for the model's tool
/// choices or a reason to refuse an answer.
bool isInformationRequest(String request) {
  if (!isAssistantRequest(request) || isDraftRequest(request)) return false;
  final text = request.trim();
  final privateRecall = RegExp(
    r'\bwhat\s+(?:(?:did|have|had)\s+)?i\s+(?:tell|told|note|noted|report|reported|say|said|mention|mentioned|record|recorded|log|logged|measure|measured|observe|observed)\b|\b(?:what|that)\s+i\s+(?:previously\s+)?(?:told|said|reported|noted|recorded|mentioned|logged)\b|^(?:please\s+)?(?:recall|remind\s+me)\b|\b(?:search|find|look\s+up|show|summari[sz]e)\b.*\b(?:my|our|saved|previous|earlier)\s+(?:[\w-]+\s+){0,4}(?:conversation|chat|memory|memories|notes?|logs?)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (privateRecall) return false;
  final historical = RegExp(
    r'\b(?:what|how much|when|which)\s+(?:was|were|did|has|have)\b|\b(?:latest|previous|last|recorded|measured|tested|reading|result|trend|history)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final personal = RegExp(
    r'\b(?:my|our|his|her|their|mine|child.s|daughter.s|son.s)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final dated = RegExp(
    r'\b(?:today|yesterday|week|month|year|(?:19|20|21)\d{2})\b|\d{1,2}[-/.]\d{1,2}',
    caseSensitive: false,
  ).hasMatch(text);
  if (personal && (historical || dated)) return false;
  if (RegExp(
    r'\b(?:find|show|retrieve|search|look up)\b.*\b(?:my|our|his|her|their|uploaded|saved)\b.*\b(?:files?|reports?|records?|results?)\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return false;
  }
  return _questionStart.hasMatch(text) ||
      RegExp(
        r'\b(?:explain|tell me (?:about|how)|describe|help me understand|what does|what is|what are|is it|can it|should i|could it)\b',
        caseSensitive: false,
      ).hasMatch(text);
}

final _questionStart = RegExp(
  r'^(?:(?:hi|hello|hey)[,!]?\s+)?(?:what|why|how|when|where|which|who|is|are|was|were|do|does|did|can|could|should|would|will|has|have)\b',
  caseSensitive: false,
);
final _requestStart = RegExp(
  r'^(?:(?:hi|hello|hey)[,!]?\s+)?(?:please\s+)?(?:compose|create|craft|write|compile|summari[sz]e|draft|find|show|explain|generate|prepare|make|compare|review|search|look|tell|give|describe|delete|remove|recall|remind|help)\b',
  caseSensitive: false,
);

/// Calendar windows are half-open and use UTC solely as a timezone-neutral
/// representation of calendar components. The caller supplies its local `now`.
class ReportDateWindow {
  const ReportDateWindow(this.start, this.end);
  final DateTime start;
  final DateTime end;
  bool contains(DateTime date) {
    final day = DateTime.utc(date.year, date.month, date.day);
    return !day.isBefore(start) && day.isBefore(end);
  }
}

class ReportDateFilter {
  const ReportDateFilter({
    required this.windows,
    this.usesFilingDate = false,
    this.ambiguous = false,
  });
  final List<ReportDateWindow> windows;
  final bool usesFilingDate;

  /// An ambiguous/invalid explicit date yields no matches, rather than silently
  /// broadening a request or interpreting 03/04 as either March 4 or April 3.
  final bool ambiguous;
  bool contains(DateTime date) =>
      windows.any((window) => window.contains(date));
}

/// Returns null only when the request contains no recognized date constraint.
/// The caller can use [ReportDateFilter.ambiguous] to ask for clarification.
ReportDateFilter? reportDateFilterForRequest(String request, DateTime now) {
  final filing = RegExp(
    r'\b(?:uploaded|upload|imported|import|filed|filing|added|saved|received)\b',
    caseSensitive: false,
  ).hasMatch(request);
  ReportDateFilter result(
    List<ReportDateWindow> windows, {
    bool invalid = false,
  }) => ReportDateFilter(
    windows: List.unmodifiable(windows),
    usesFilingDate: filing,
    ambiguous: invalid,
  );
  final text = request.toLowerCase();
  final today = DateTime.utc(now.year, now.month, now.day);
  final windows = <ReportDateWindow>[];
  final covered = <(int, int)>[];
  var invalid = false;

  // A shared trailing year/month is explicit, e.g. March 14 to 16, 2026.
  final sharedRanges = RegExp(
    r'\b(' +
        _monthExpression +
        r')\.?\s+(\d{1,2})(?:st|nd|rd|th)?\s*(?:,?\s*(\d{4}))?\s*(?:to|through|until|–|—|-)\s*(?:(' +
        _monthExpression +
        r')\.?\s+)?(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b',
    caseSensitive: false,
  );
  for (final match in sharedRanges.allMatches(text)) {
    final firstYear = int.tryParse(match.group(3) ?? match.group(6) ?? '');
    final endYear = int.tryParse(match.group(6) ?? match.group(3) ?? '');
    if (firstYear == null || endYear == null) continue;
    final start = _checkedDate(
      firstYear,
      _month(match.group(1)!),
      int.parse(match.group(2)!),
    );
    final end = _checkedDate(
      endYear,
      _month(match.group(4) ?? match.group(1)!),
      int.parse(match.group(5)!),
    );
    covered.add((match.start, match.end));
    if (start == null || end == null || end.isBefore(start)) {
      invalid = true;
    } else {
      windows.add(ReportDateWindow(start, end.add(const Duration(days: 1))));
    }
  }

  final tokens = <_DateToken>[];
  for (final match in _fullDatePattern.allMatches(text)) {
    if (_overlaps(covered, match.start, match.end)) continue;
    final date = _normalizeDate(match);
    tokens.add(_DateToken(match.start, match.end, date));
    covered.add((match.start, match.end));
    if (date == null) invalid = true;
  }
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final start = token.date;
    if (start == null) continue;
    if (i + 1 < tokens.length &&
        RegExp(
          r'^\s*(?:to|through|until|–|—|-)\s*$',
        ).hasMatch(text.substring(token.end, tokens[i + 1].start))) {
      final end = tokens[++i].date;
      if (end == null || end.isBefore(start)) {
        invalid = true;
      } else {
        windows.add(ReportDateWindow(start, end.add(const Duration(days: 1))));
      }
    } else {
      windows.add(ReportDateWindow(start, start.add(const Duration(days: 1))));
    }
  }
  if (covered.isNotEmpty) {
    return result(invalid ? const [] : windows, invalid: invalid);
  }

  // Month/year and bare years are considered only outside full date tokens.
  final monthYear = RegExp(
    r'\b(' + _monthExpression + r')\.?\s+(\d{4})\b',
    caseSensitive: false,
  );
  final monthMatches = monthYear.allMatches(text).toList();
  for (var i = 0; i < monthMatches.length; i++) {
    final match = monthMatches[i];
    final year = int.parse(match.group(2)!);
    final month = _month(match.group(1)!);
    final start = DateTime.utc(year, month);
    if (i + 1 < monthMatches.length &&
        RegExp(
          r'^\s*(?:to|through|until|–|—|-)\s*$',
        ).hasMatch(text.substring(match.end, monthMatches[i + 1].start))) {
      final last = monthMatches[++i];
      final lastYear = int.parse(last.group(2)!);
      final lastMonth = _month(last.group(1)!);
      final lastStart = DateTime.utc(lastYear, lastMonth);
      if (lastStart.isBefore(start)) return result(const [], invalid: true);
      windows.add(
        ReportDateWindow(start, DateTime.utc(lastYear, lastMonth + 1)),
      );
    } else {
      windows.add(ReportDateWindow(start, DateTime.utc(year, month + 1)));
    }
  }
  if (windows.isNotEmpty) return result(windows);

  final years = RegExp(r'\b(?:19|20|21)\d{2}\b').allMatches(text).toList();
  if (years.isNotEmpty) {
    for (var i = 0; i < years.length; i++) {
      final year = int.parse(years[i].group(0)!);
      if (i + 1 < years.length &&
          RegExp(
            r'^\s*(?:to|through|until|–|—|-)\s*$',
          ).hasMatch(text.substring(years[i].end, years[i + 1].start))) {
        final endYear = int.parse(years[++i].group(0)!);
        if (endYear < year) return result(const [], invalid: true);
        windows.add(
          ReportDateWindow(DateTime.utc(year), DateTime.utc(endYear + 1)),
        );
      } else {
        windows.add(
          ReportDateWindow(DateTime.utc(year), DateTime.utc(year + 1)),
        );
      }
    }
    return result(windows);
  }

  if (RegExp(r'\btoday\b').hasMatch(text)) {
    windows.add(ReportDateWindow(today, today.add(const Duration(days: 1))));
  }
  if (RegExp(r'\byesterday\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(today.subtract(const Duration(days: 1)), today),
    );
  }
  if (RegExp(r'\b(?:last|past)\s+7\s+days\b|\bpast\s+week\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(
        today.subtract(const Duration(days: 6)),
        today.add(const Duration(days: 1)),
      ),
    );
  } else if (RegExp(r'\blast\s+week\b').hasMatch(text)) {
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));
    windows.add(
      ReportDateWindow(
        thisMonday.subtract(const Duration(days: 7)),
        thisMonday,
      ),
    );
  } else if (RegExp(r'\bthis\s+week\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(
        today.subtract(Duration(days: today.weekday - 1)),
        today.add(const Duration(days: 1)),
      ),
    );
  }
  if (RegExp(r'\blast\s+month\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(
        DateTime.utc(today.year, today.month - 1),
        DateTime.utc(today.year, today.month),
      ),
    );
  } else if (RegExp(r'\bthis\s+month\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(
        DateTime.utc(today.year, today.month),
        today.add(const Duration(days: 1)),
      ),
    );
  }
  if (RegExp(r'\blast\s+year\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(DateTime.utc(today.year - 1), DateTime.utc(today.year)),
    );
  } else if (RegExp(r'\bthis\s+year\b').hasMatch(text)) {
    windows.add(
      ReportDateWindow(
        DateTime.utc(today.year),
        today.add(const Duration(days: 1)),
      ),
    );
  }
  return windows.isEmpty ? null : result(windows);
}

/// Restricts candidates before semantic ranking, so a low keyword score cannot
/// discard a report that the person selected by its date. Input order is kept.
List<Report> reportsForRequest(
  List<Report> reports,
  String profileId,
  String request,
  DateTime now,
) {
  final filter = reportDateFilterForRequest(request, now);
  final today = DateTime.utc(now.year, now.month, now.day);
  return reports
      .where((report) {
        if (report.profileId != profileId) return false;
        if (filter == null) return true;
        final date = filter.usesFilingDate
            ? report.importedAt
            : report.dateIsFallback
            ? null
            : report.eventDate;
        if (date == null) return false;
        final calendarDate = DateTime.utc(date.year, date.month, date.day);
        return !calendarDate.isAfter(today) && filter.contains(date);
      })
      .toList(growable: false);
}

bool _overlaps(List<(int, int)> covered, int start, int end) =>
    covered.any((span) => start < span.$2 && end > span.$1);

const _monthExpression =
    r'(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec)';
final _fullDatePattern = RegExp(
  r'\b(?:(\d{4})[-/](\d{1,2})[-/](\d{1,2})|(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})|(\d{1,2})(?:st|nd|rd|th)?[\s-]+(' +
      _monthExpression +
      r')\.?[\s,-]+(\d{4})|(' +
      _monthExpression +
      r')\.?[\s-]+(\d{1,2})(?:st|nd|rd|th)?[\s,-]+(\d{4}))\b',
  caseSensitive: false,
);
DateTime? _normalizeDate(RegExpMatch match) {
  if (match.group(1) != null) {
    return _checkedDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }
  if (match.group(4) != null) {
    final first = int.parse(match.group(4)!);
    final second = int.parse(match.group(5)!);
    if (first <= 12 && second <= 12 && first != second) return null;
    return _checkedDate(
      int.parse(match.group(6)!),
      first > 12 ? second : first,
      first > 12 ? first : second,
    );
  }
  final dayFirst = match.group(7) != null;
  return _checkedDate(
    int.parse(match.group(dayFirst ? 9 : 12)!),
    _month(match.group(dayFirst ? 8 : 10)!),
    int.parse(match.group(dayFirst ? 7 : 11)!),
  );
}

int _month(String name) => const {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
}[name.toLowerCase().substring(0, 3)]!;

DateTime? _checkedDate(int year, int month, int day) {
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

class _DateToken {
  const _DateToken(this.start, this.end, this.date);
  final int start;
  final int end;
  final DateTime? date;
}
