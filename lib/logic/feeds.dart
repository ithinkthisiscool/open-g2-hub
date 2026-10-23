/// News sources for the glasses' news widget. Port of g2-hub/hub/feeds.py: RSS/Atom parsing,
/// interleaving several feeds, skipping titles already shown, and turning an article page
/// (Jina AI Reader text, then a <p> fallback, then the feed summary) into glasses-safe text.
/// Pure functions here; the HTTP part lives in services/news_service.dart.
library;

import 'dart:convert';

import 'package:xml/xml.dart';

import '../protocol/dashboard.dart' show decodeUtf8PrefixIgnore;
import '../protocol/pytext.dart';
import 'html_unescape.dart';

/// id → (name, url): the hub's 9 sources.
const Map<String, (String, String)> feeds = {
  'hn': ('Hacker News', 'https://news.ycombinator.com/rss'),
  'bbc': ('BBC World', 'https://feeds.bbci.co.uk/news/world/rss.xml'),
  'bbc_tech': ('BBC Tech', 'https://feeds.bbci.co.uk/news/technology/rss.xml'),
  'npr': ('NPR', 'https://feeds.npr.org/1001/rss.xml'),
  'guardian': ('The Guardian', 'https://www.theguardian.com/world/rss'),
  'aljazeera': ('Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'),
  'ars': ('Ars Technica', 'https://feeds.arstechnica.com/arstechnica/index'),
  'verge': ('The Verge', 'https://www.theverge.com/rss/index.xml'),
  'techcrunch': ('TechCrunch', 'https://techcrunch.com/feed/'),
};
const List<String> defaultFeeds = ['hn'];
const int articleMaxChars = 3000;
const int titleMaxBytes = 126, sourceMaxBytes = 62;
const int seenTitlesMax = 60;
const Duration refreshEvery = Duration(minutes: 30); // HN_CACHE_MAX_AGE_S
const Duration deviceRefreshCooldown = Duration(seconds: 30);

final RegExp _unsupported = RegExp('[\u{1F000}-\u{1FFFF}☀-➿️‍]', unicode: true);

String cleanForGlasses(String? text) {
  var t = htmlUnescape(text ?? '');
  t = t.replaceAll(_unsupported, '');
  t = t.replaceAll('‘', "'").replaceAll('’', "'").replaceAll('“', '"').replaceAll('”', '"');
  t = t.replaceAll('‐', '-').replaceAll('‑', '-').replaceAll('‒', '-');
  t = t.replaceAll('–', '-').replaceAll('—', ' - ').replaceAll('…', '...').replaceAll(' ', ' ');
  return t;
}

/// feeds.limit_bytes: cut to max-3 bytes (ignoring a split character) + "...".
String limitBytes(String? text, int maxBytes) {
  final t = text ?? '';
  final b = utf8.encode(t);
  if (b.length <= maxBytes) return t;
  return '${decodeUtf8PrefixIgnore(b.sublist(0, maxBytes - 3))}...';
}

int _rfind(String s, String sub) => s.lastIndexOf(sub);

/// Cut at the last sentence end before [limit] if that keeps ≥60 % of the text.
String smartTrim(String text, int limit) {
  final r = text.runes.toList();
  if (r.length <= limit) return text;
  final cut = String.fromCharCodes(r.take(limit));
  final cands = [_rfind(cut, '. '), _rfind(cut, '.\n'), _rfind(cut, '? '), _rfind(cut, '! ')];
  final lastUnits = cands.reduce((a, b) => a > b ? a : b);
  // Python indexes code points; convert the UTF-16 index.
  final last = lastUnits < 0 ? -1 : cut.substring(0, lastUnits).runes.length;
  if (last > limit * 0.6) return String.fromCharCodes(cut.runes.take(last + 1));
  return '${_rstrip(cut)}...';
}

String _rstrip(String s) {
  final r = s.runes.toList();
  var e = r.length;
  while (e > 0 && pyIsSpace(r[e - 1])) {
    e--;
  }
  return String.fromCharCodes(r.take(e));
}

const List<String> _skip = [
  'Sign in', 'Subscribe', 'Login', 'Log in', 'Cookie', 'Privacy', 'Copyright', 'All rights reserved', //
  'Terms of', '©', 'Advertisement', 'URL Source:', 'Title:', 'Published Time:', 'Author:', 'Image:',
];

/// Python str.splitlines() separators.
final RegExp _lineBreaks = RegExp('\r\n|[\n\r\u000B\u000C\u001C\u001D\u001E\u0085  ]');

List<String> paragraphs(String text) {
  var lines = text.split(_lineBreaks).map(pyStrip).toList();
  if (text.isNotEmpty && RegExp('(\r\n|[\n\r\u000B\u000C\u001C\u001D\u001E\u0085  ])\$').hasMatch(text)) {
    lines = lines.sublist(0, lines.length - 1); // splitlines drops the final empty piece
  }
  if (text.isEmpty) lines = [];
  final paras = <String>[];
  final buf = <String>[];
  for (final line in [...lines, '']) {
    if (line.isNotEmpty) {
      buf.add(line);
    } else if (buf.isNotEmpty) {
      paras.add(buf.join(' '));
      buf.clear();
    }
  }
  return [for (final p in paras) if (p.runes.length > 40 && !_skip.any(p.startsWith)) p];
}

/// Jina Reader markdown → plain paragraphs.
String cleanJina(String text) {
  var t = text;
  final i = t.indexOf('Markdown Content:');
  if (i != -1) t = t.substring(i + 'Markdown Content:'.length);
  t = t.replaceAll(RegExp(r'!\[.*?\]\(.*?\)'), '');
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!);
  t = t.replaceAll(RegExp(r'```[\s\S]*?```'), '');
  t = t.replaceAll(RegExp(r'^#+\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^[-*]{3,}\s*$', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'[*_`]'), '');
  return paragraphs(cleanForGlasses(t)).join('\n\n');
}

/// Plain-<p> fallback for an article page; '' when nothing usable.
String htmlParagraphText(String page, {int maxChars = articleMaxChars}) {
  final paras = [
    for (final m in RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true, caseSensitive: false).allMatches(page))
      pyStrip(m[1]!.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll(RegExp(r'\s+'), ' '))
  ];
  final joined = paras.where((p) => p.runes.length > 40).join('\n\n');
  final head = String.fromCharCodes(joined.runes.take(maxChars * 2));
  final text = cleanForGlasses(head);
  return text.runes.length > 40 ? smartTrim(text, maxChars) : '';
}

class FeedItem {
  FeedItem(this.title, this.url, this.summary, [this.source = '']);
  final String title;
  final String url;
  final String summary;
  String source;
  Map<String, Object?> toJson() => {'title': title, 'url': url, 'summary': summary};
}

/// ElementTree's `.text`: the text before the first child element.
String _leadText(XmlElement e) {
  final b = StringBuffer();
  for (final n in e.children) {
    if (n is XmlElement) break;
    if (n is XmlText || n is XmlCDATA) b.write(n.value);
  }
  return b.toString();
}

String _text(XmlElement el, List<String> names) {
  for (final n in names) {
    XmlElement? found;
    for (final c in el.childElements) {
      if (c.name.local == n) {
        found = c;
        break;
      }
    }
    if (found != null && pyStrip(_leadText(found)).isNotEmpty) return pyStrip(_leadText(found));
    final href = found?.getAttribute('href');
    if (found != null && href != null && href.isNotEmpty) return href;
  }
  return '';
}

/// RSS 2.0 or Atom → items (namespaces dropped like the hub).
List<FeedItem> parseFeed(String xmlText) {
  var x = xmlText.replaceAll(RegExp(r'\sxmlns(:\w+)?="[^"]+"'), '');
  x = x.replaceAllMapped(RegExp(r'<(/?)\w+:(\w+)'), (m) => '<${m[1]}${m[2]}');
  final root = XmlDocument.parse(x).rootElement;
  var items = root.descendantElements.where((e) => e.name.local == 'item').toList();
  if (items.isEmpty) items = root.descendantElements.where((e) => e.name.local == 'entry').toList();
  final out = <FeedItem>[];
  for (final it in items) {
    final title = pyStrip(cleanForGlasses(_text(it, ['title']).replaceAll(RegExp(r'<[^>]+>'), '')));
    final link = _text(it, ['link']);
    final summary = cleanForGlasses(_text(it, ['description', 'summary', 'content']).replaceAll(RegExp(r'<[^>]+>'), ' '));
    if (title.isNotEmpty) out.add(FeedItem(title, link, pyStrip(summary.replaceAll(RegExp(r'\s+'), ' '))));
  }
  return out;
}

/// Round-robin [count] items across feeds, skipping titles in [skip].
List<FeedItem> interleave(List<List<FeedItem>> perFeed, int count, Set<String> skip) {
  final lists = [for (final l in perFeed) [for (final i in l) if (!skip.contains(i.title)) i]];
  final picked = <FeedItem>[];
  while (picked.length < count && lists.any((l) => l.isNotEmpty)) {
    for (final l in lists) {
      if (l.isNotEmpty && picked.length < count) picked.add(l.removeAt(0));
    }
  }
  return picked;
}

/// A story as the widget gets it (title ≤126 B, source ≤62 B, content never empty).
Map<String, Object?> finishStory(FeedItem item, String articleText) {
  final trimmed = smartTrim(item.summary, articleMaxChars);
  final content = articleText.isNotEmpty
      ? articleText
      : trimmed.isNotEmpty
          ? trimmed
          : item.url.isNotEmpty
              ? item.url
              : item.title;
  return {
    'title': limitBytes(item.title, titleMaxBytes),
    'source': limitBytes(item.source, sourceMaxBytes),
    'url': item.url,
    'content': content,
    'text_extracted': articleText.isNotEmpty,
  };
}

/// Feed id from [feeds] or a custom http(s) URL; null when neither.
(String, String)? feedSource(String id) {
  if (feeds.containsKey(id)) return feeds[id];
  if (id.startsWith('http://') || id.startsWith('https://')) return (id, id);
  return null;
}

/// The device news FIFO is filled completely: articles repeat to fill [count] slots and slot n
/// gets newsId n (hub routes/news.py push_news).
List<T> fillSlots<T>(List<T> articles, int count) => [for (var n = 0; n < count; n++) articles[n % articles.length]];

/// seen_titles bookkeeping: the last 60 titles shown.
List<String> updateSeen(List<String> seen, Iterable<String> shown) {
  final all = [...seen, ...shown];
  return all.length > seenTitlesMax ? all.sublist(all.length - seenTitlesMax) : all;
}
