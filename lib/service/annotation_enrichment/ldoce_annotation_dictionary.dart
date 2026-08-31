import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

const ldoceAnnotationDictionaryBaseUrl =
    'https://www.ldoceonline.com/dictionary/';

class LdoceSense {
  final String? number;
  final String? phrase;
  final List<String> labels;
  final String definition;
  final List<String> examples;

  const LdoceSense({
    this.number,
    this.phrase,
    this.labels = const [],
    required this.definition,
    this.examples = const [],
  });
}

class LdoceEntry {
  final String headword;
  final String? partOfSpeech;
  final String? pronunciation;
  final List<LdoceSense> senses;

  const LdoceEntry({
    required this.headword,
    this.partOfSpeech,
    this.pronunciation,
    required this.senses,
  });
}

class LdoceArticle {
  final String title;
  final String url;
  final List<LdoceEntry> entries;

  const LdoceArticle({
    required this.title,
    required this.url,
    required this.entries,
  });

  String? get shortDefinition =>
      entries.firstOrNull?.senses.firstOrNull?.definition;
}

Uri ldoceAnnotationDictionaryUri(
  String text, {
  String baseUrl = ldoceAnnotationDictionaryBaseUrl,
}) {
  final slug = text
      .trim()
      .toLowerCase()
      .replaceAll(RegExp("[’']"), '-')
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final normalized = slug.isEmpty ? text.trim() : slug;
  return Uri.parse(baseUrl).resolve(Uri.encodeComponent(normalized));
}

LdoceArticle parseLdoceArticle(String html, String requestedText) {
  final document = html_parser.parse(html);
  final entries = document
      .querySelectorAll('.dictionary .ldoceEntry.Entry')
      .map(_parseEntry)
      .whereType<LdoceEntry>()
      .where((entry) => entry.senses.isNotEmpty)
      .toList(growable: false);
  if (entries.isEmpty) {
    throw StateError(
      'LDOCE did not find a dictionary entry for “${requestedText.trim()}”.',
    );
  }
  return LdoceArticle(
    title: _clean(document.querySelector('.entry_content .pagetitle')?.text) ??
        requestedText.trim(),
    url: ldoceAnnotationDictionaryUri(requestedText).toString(),
    entries: entries,
  );
}

String ldoceArticleToMarkdown(LdoceArticle article) =>
    article.entries.map((entry) {
      final heading = [entry.headword, entry.partOfSpeech]
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .join(' · ');
      final pronunciation = entry.pronunciation == null
          ? ''
          : '\n\nPronunciation: ${entry.pronunciation}';
      final senses = <String>[];
      for (var index = 0; index < entry.senses.length; index++) {
        final sense = entry.senses[index];
        final lead = sense.number ?? '${index + 1}';
        final phrase = sense.phrase == null ? '' : ' **${sense.phrase}** —';
        final labels =
            sense.labels.isEmpty ? '' : ' _${sense.labels.join(', ')}_';
        final examples = sense.examples.isEmpty
            ? ''
            : '\n${sense.examples.map((example) => '   - $example').join('\n')}';
        senses.add('$lead.$phrase$labels ${sense.definition}$examples');
      }
      return '**LDOCE · $heading**$pronunciation\n\n${senses.join('\n')}';
    }).join('\n\n');

class LdoceAnnotationDictionaryService {
  final http.Client client;
  final Duration timeout;
  final String baseUrl;

  LdoceAnnotationDictionaryService({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.baseUrl = ldoceAnnotationDictionaryBaseUrl,
  }) : client = client ?? http.Client();

  Future<LdoceArticle> lookup(String text) async {
    final response = await client.get(
      ldoceAnnotationDictionaryUri(text, baseUrl: baseUrl),
      headers: const {
        'Accept': 'text/html',
        'Accept-Language': 'en',
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36',
      },
    ).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
          'LDOCE request failed with HTTP ${response.statusCode}.');
    }
    final article = parseLdoceArticle(response.body, text);
    return LdoceArticle(
      title: article.title,
      url: ldoceAnnotationDictionaryUri(text, baseUrl: baseUrl).toString(),
      entries: article.entries,
    );
  }
}

LdoceEntry? _parseEntry(Element element) {
  final head = element.children
      .where((child) => child.classes.contains('Head'))
      .firstOrNull;
  final headword = _clean(head?.querySelector('.HWD, .PHRVBHWD')?.text);
  if (headword == null) return null;
  final senses = element.children
      .where((child) => child.classes.contains('Sense'))
      .map(_parseSense)
      .whereType<LdoceSense>()
      .toList(growable: false);
  return LdoceEntry(
    headword: headword,
    partOfSpeech: _clean(head?.querySelector('.POS')?.text),
    pronunciation: _clean(head?.querySelector('.PRON, .PronCodes')?.text),
    senses: senses,
  );
}

LdoceSense? _parseSense(Element element) {
  final definition = _clean(element.querySelector('.DEF')?.text);
  if (definition == null) return null;
  return LdoceSense(
    number: _clean(element.querySelector('.sensenum')?.text),
    phrase: _clean(element.querySelector('.LEXUNIT, .LEXVAR')?.text),
    labels: const ['GRAM', 'GEO', 'REGISTERLAB', 'SIGNPOST', 'ACTIV']
        .expand((className) => element.querySelectorAll('.$className'))
        .map((label) => _clean(label.text))
        .whereType<String>()
        .toList(growable: false),
    definition: definition,
    examples: element
        .querySelectorAll('.EXAMPLE')
        .map((example) => _clean(example.text))
        .whereType<String>()
        .toList(growable: false),
  );
}

String? _clean(String? value) {
  final cleaned =
      value?.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned?.isNotEmpty == true ? cleaned : null;
}
