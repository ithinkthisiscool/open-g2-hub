/// Stock quotes from Yahoo Finance's public chart endpoint (no key; unofficial, so failures per
/// symbol are normal). Port of g2-hub/hub/stock_quotes.py.
library;

import 'pyfmt.dart';

const String chartUrl = 'https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=1d&interval=30m';
const Map<String, String> headers = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) g2hub'};
final RegExp symbolRe = RegExp(r'^[A-Za-z0-9.\-^=]{1,15}$');
const int maxSymbols = 8;
const int maxPoints = 24;
const Set<String> usExchanges = {'NMS', 'NGM', 'NCM', 'NYQ', 'ASE', 'PCX', 'BTS', 'NAS', 'NYS', 'PNK', 'OQB', 'OQX'};
const int trendFlat = 0, trendUp = 1, trendDown = 2;

/// 'aapl, MSFT tsla' → ['AAPL', 'MSFT', 'TSLA']; throws FormatException on bad input.
List<String> parseSymbols(String? text) {
  final items = <String>[];
  for (final s in (text ?? '').split(RegExp(r'[\s,;]+'))) {
    final t = s.trim().toUpperCase();
    if (t.isNotEmpty && !items.contains(t)) items.add(t);
  }
  if (items.isEmpty) throw const FormatException('enter at least one symbol');
  if (items.length > maxSymbols) throw const FormatException('at most $maxSymbols symbols');
  final bad = items.where((s) => !symbolRe.hasMatch(s)).toList();
  if (bad.isNotEmpty) throw FormatException('invalid symbol(s): ${bad.join(', ')}');
  return items;
}

/// One chart API result → quote map for stocks.buildStock(); throws StateError (LookupError).
Map<String, Object?> quoteFromChart(String symbol, Map<String, Object?> chart) {
  final c = (chart['chart'] as Map?)?.cast<String, Object?>() ?? const {};
  final result = (c['result'] as List?) ?? const [];
  if (result.isEmpty) {
    final err = ((c['error'] as Map?)?['description']) ?? 'no data';
    throw StateError('$symbol: $err');
  }
  final r0 = (result.first as Map).cast<String, Object?>();
  final meta = (r0['meta'] as Map?)?.cast<String, Object?>() ?? const {};
  final price = meta['regularMarketPrice'] as num?;
  final prevRaw = meta['chartPreviousClose'] ?? meta['previousClose'];
  final prev = (prevRaw == 0 || prevRaw == null) ? (meta['previousClose'] as num?) : prevRaw as num;
  if (price == null) throw StateError('$symbol: no price');
  final change = (prev != null && prev != 0) ? (price - prev) / prev * 100 : 0.0;
  final quotes = ((r0['indicators'] as Map?)?['quote'] as List?) ?? const [{}];
  final quote = (quotes.isEmpty ? const {} : quotes.first as Map).cast<String, Object?>();
  final closes = [for (final x in (quote['close'] as List?) ?? const []) if (x != null) (x as num)];
  final last = closes.length > maxPoints ? closes.sublist(closes.length - maxPoints) : closes;
  final opens = [for (final x in (quote['open'] as List?) ?? const []) if (x != null) x as num];
  final exchange = (meta['exchangeName'] ?? '').toString();
  final name = [meta['longName'], meta['shortName']].firstWhere((x) => x != null && x != '', orElse: () => symbol);
  final q = <String, Object?>{
    'code': symbol,
    'market_suffix': usExchanges.contains(exchange) ? 'US' : (exchange.length > 8 ? exchange.substring(0, 8) : exchange),
    'name': name,
    'price': price.toDouble(),
    'change_percent': pyRoundTo(change.toDouble(), 2),
    'trend': change > 0 ? trendUp : (change < 0 ? trendDown : trendFlat),
    'day_high': meta['regularMarketDayHigh'],
    'day_low': meta['regularMarketDayLow'],
    'open': opens.isNotEmpty ? opens.first : null,
    'volume': meta['regularMarketVolume'],
    'dark_price': prev,
  };
  if (last.isNotEmpty) q['points'] = last;
  q.removeWhere((k, v) => v == null);
  return q;
}

String summary(Map<String, Object?> q) =>
    '${q['code']} ${pyFixed((q['price'] as num).toDouble(), 2)} (${(q['change_percent'] as num) >= 0 ? '+' : ''}${pyFixed((q['change_percent'] as num).toDouble(), 2)}%)';
