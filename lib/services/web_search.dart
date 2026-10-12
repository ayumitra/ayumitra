import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/records.dart';

class WebSource {
  const WebSource({
    required this.id,
    required this.title,
    required this.url,
    required this.excerpt,
    required this.retrievedAt,
  });
  final String id, title, excerpt;
  final Uri url;
  final DateTime retrievedAt;
  Json toJson() => {
    'id': id,
    'title': title,
    'url': url.toString(),
    'excerpt': excerpt,
    'retrievedAt': retrievedAt.toIso8601String(),
  };
}

/// A standalone public query is the ONLY data this service can receive.
/// It has no vault/repository dependency and cannot upload files or call an LLM.
class WebSearch {
  WebSearch({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  String? apiKey;
  bool get available => apiKey?.isNotEmpty ?? false;

  Future<List<WebSource>> search(String query) async {
    if (!available) {
      throw StateError(
        'Add a Brave Search API key in settings to enable web search.',
      );
    }
    if (query.isEmpty || query.length > 180) {
      throw const FormatException('Invalid public search query.');
    }
    final uri = Uri.https('api.search.brave.com', '/res/v1/web/search', {
      'q': query,
      'count': '5',
      'search_lang': 'en',
      'safesearch': 'strict',
    });
    final request = http.Request('GET', uri)..followRedirects = false;
    request.headers.addAll({
      'Accept': 'application/json',
      'X-Subscription-Token': apiKey!,
    });
    final stream = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (stream.statusCode != 200) {
      throw StateError(
        'Web search is unavailable (${stream.statusCode}). No AI fallback was used.',
      );
    }
    final bytes = <int>[];
    await for (final part in stream.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(part);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException(
          'Search response exceeded the local limit.',
        );
      }
    }
    final data = jsonDecode(utf8.decode(bytes)) as Map;
    final rows = (data['web'] as Map?)?['results'] as List? ?? [];
    final result = <WebSource>[];
    for (final row in rows.take(5)) {
      final url = Uri.tryParse(row['url'] as String? ?? '');
      if (url == null || url.scheme != 'https' || url.host.isEmpty) continue;
      String plain(String value) =>
          value.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      result.add(
        WebSource(
          id: 'web-${result.length + 1}',
          title: plain(row['title'] ?? ''),
          url: url,
          excerpt: plain(row['description'] ?? ''),
          retrievedAt: DateTime.now().toUtc(),
        ),
      );
    }
    return result;
  }
}

/// Defense in depth for planner queries. Checks cannot prove anonymity: the
/// planner sees only the user's request, and never sees retrieved records here.
bool publicQueryAllowed(String query, Profile profile) {
  if (query.trim().isEmpty || query.length > 180) return false;
  if (RegExp(
    r'\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b|[\w.+-]+@[\w.-]+\.[a-z]+|\b\d{7,}\b',
    caseSensitive: false,
  ).hasMatch(query)) {
    return false;
  }
  if (RegExp(
    r'\b\d+(?:\.\d+)?\s*(?:years?|months?|weeks?|g/dl|mg/dl|mmol/l|mmhg|%)',
    caseSensitive: false,
  ).hasMatch(query)) {
    return false;
  }
  if (RegExp(
    r'\b(my|mine|patient|child|daughter|son|born|dob|address|mrn)\b',
    caseSensitive: false,
  ).hasMatch(query)) {
    return false;
  }
  if (RegExp(
    r'https?://|www\.|file://|content://',
    caseSensitive: false,
  ).hasMatch(query)) {
    return false;
  }
  final withoutPublicNumbers = query.replaceAll(
    RegExp(
      r'\b\d+(?:\.\d+)?\s*(?:mg|mcg|ug|ml|g)\b|\btype\s*[12]\s+diabetes\b|\bcovid[- ]?19\b|\bvitamin\s+b12\b',
      caseSensitive: false,
    ),
    '',
  );
  if (RegExp(r'\b\d+(?:\.\d+)?\b').hasMatch(withoutPublicNumbers)) return false;
  final nameParts = _nameWords(profile.name);
  final words = _nameWords(query);
  if (nameParts.any(words.contains)) return false;
  // Also catch spellings that join a full hyphenated/apostrophized name.
  final compactName = nameParts.join();
  return compactName.isEmpty || !words.contains(compactName);
}

/// Same Unicode-aware comparison for names and proposed public queries. Common
/// Latin accents are folded so José/Jose and decomposed e + accent match too.
/// Short names are checked as complete tokens, never substrings of drug names.
List<String> _nameWords(String text) {
  var folded = text.toLowerCase();
  const groups = {
    'àáâãäåāăąǎǻ': 'a',
    'çćĉċč': 'c',
    'ďđð': 'd',
    'èéêëēĕėęě': 'e',
    'ĝğġģ': 'g',
    'ĥħ': 'h',
    'ìíîïĩīĭįıǐ': 'i',
    'ĵ': 'j',
    'ķ': 'k',
    'ĺļľŀł': 'l',
    'ñńņňŋ': 'n',
    'òóôõöøōŏőǒǿ': 'o',
    'ŕŗř': 'r',
    'śŝşšș': 's',
    'ţťŧț': 't',
    'ùúûüũūŭůűųǔǖǘǚǜ': 'u',
    'ŵ': 'w',
    'ýÿŷ': 'y',
    'źżž': 'z',
  };
  for (final group in groups.entries) {
    for (final rune in group.key.runes) {
      folded = folded.replaceAll(String.fromCharCode(rune), group.value);
    }
  }
  folded = folded
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe')
      .replaceAll('ß', 'ss');
  folded = folded.replaceAll(RegExp(r'\p{M}', unicode: true), '');
  return RegExp(
    r'\p{L}+',
    unicode: true,
  ).allMatches(folded).map((match) => match.group(0)!).toList();
}
