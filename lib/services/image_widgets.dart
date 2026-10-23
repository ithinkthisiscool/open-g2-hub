/// Draws the hub's EvenHub image widgets (stock chart, line graph, big-number metric) as
/// 288x144 grey images (bright on black, like hub/stock_chart.py and hub/custom_widget.py) and
/// packs them to 4 bits per pixel. Pure Dart (package:image); fonts are its built-in bitmaps,
/// so the look matches the hub's layout, not its exact pixels. EXPERIMENTAL on the glasses.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../logic/pyfmt.dart';
import '../logic/widget_data.dart' as wd;
import '../protocol/evenhub.dart' as eh;
import '../protocol/evenhub_pages.dart' as ehp;

const int imgW = ehp.chartW, imgH = ehp.chartH;

img.Color _g(int v) => img.ColorRgb8(v, v, v);

img.Image _canvas() => img.Image(width: imgW, height: imgH)..clear(_g(0));

void _text(img.Image im, String t, int x, int y, {img.BitmapFont? font, int grey = 255, bool right = false, bool center = false}) {
  final f = font ?? img.arial14;
  var w = 0;
  for (final c in t.codeUnits) {
    w += f.characters[c]?.xAdvance ?? (f.size ~/ 2);
  }
  final xx = right ? x - w : (center ? x - w ~/ 2 : x);
  img.drawString(im, t, font: f, x: max(0, xx), y: y, color: _g(grey));
}

String _ascii(String s) => String.fromCharCodes(s.runes.map((c) => c < 0x20 || c > 0x7E ? 0x3F : c));

img.Image _line(String title, String right, List<double> vals, String Function(double) label) {
  final im = _canvas();
  _text(im, _ascii(title), 4, 2, font: img.arial24);
  _text(im, _ascii(right), imgW - 4, 6, right: true);
  const top = 30, left = 4;
  const bottom = imgH - 6, rgt = imgW - 4;
  final lo = vals.reduce(min), hi = vals.reduce(max);
  final span = (hi - lo) == 0 ? 1.0 : hi - lo;
  final pts = [
    for (var i = 0; i < vals.length; i++)
      (left + (rgt - left) * i / (vals.length - 1), bottom - (bottom - top) * (vals[i] - lo) / span)
  ];
  img.drawLine(im, x1: left, y1: bottom, x2: rgt, y2: bottom, color: _g(60));
  img.drawLine(im, x1: left, y1: top, x2: rgt, y2: top, color: _g(30));
  for (var i = 1; i < pts.length; i++) {
    img.drawLine(im,
        x1: pts[i - 1].$1.round(), y1: pts[i - 1].$2.round(), x2: pts[i].$1.round(), y2: pts[i].$2.round(), color: _g(255), thickness: 2);
  }
  img.fillCircle(im, x: pts.last.$1.round(), y: pts.last.$2.round(), radius: 3, color: _g(255));
  _text(im, label(lo), left, bottom - 15, grey: 120);
  _text(im, label(hi), left, top + 1, grey: 120);
  return im;
}

/// Stock line chart: symbol, last price and % change vs the first point.
img.Image renderStockChart(String symbol, List<double> prices) {
  if (prices.length < 2) throw const FormatException('need at least 2 price points');
  final last = prices.last, first = prices.first;
  final pct = first != 0 ? (last - first) / first * 100 : 0.0;
  final sym = symbol.toUpperCase();
  return _line(sym.length > 10 ? sym.substring(0, 10) : sym, '${pyFixed(last, 2)}  ${pct >= 0 ? '+' : ''}${pyFixed(pct, 2)}%', prices,
      (v) => pyFixed(v, 2));
}

/// Titled line graph (custom widget 'graph').
img.Image renderGraph(String title, List<double> values, {String unit = ''}) {
  if (values.length < wd.minPoints) throw const FormatException('need at least 2 numbers');
  final u = unit.length > 6 ? unit.substring(0, 6) : unit;
  final t = title.isEmpty ? 'Graph' : title;
  return _line(t.length > 14 ? t.substring(0, 14) : t, '${wd.fmtNumber(values.last)}$u', values, wd.fmtNumber);
}

/// Big-number card (custom widget 'metric').
img.Image renderMetric(String title, String value, {String label = ''}) {
  final v = value.trim();
  if (v.isEmpty) throw const FormatException('value required');
  final im = _canvas();
  _text(im, _ascii(title.length > 24 ? title.substring(0, 24) : title), 6, 4, grey: 160);
  final vv = _ascii(v.length > 12 ? v.substring(0, 12) : v);
  final font = vv.length <= 5 ? img.arial48 : img.arial24;
  _text(im, vv, imgW ~/ 2, imgH ~/ 2 - font.size ~/ 2, font: font, center: true);
  if (label.isNotEmpty) _text(im, _ascii(label.length > 30 ? label.substring(0, 30) : label), imgW ~/ 2, imgH - 22, grey: 120, center: true);
  return im;
}

/// Grey image → packed 4 bpp (high nibble = left pixel), the format the hub sends.
Uint8List pack(img.Image im) {
  final pix = <int>[];
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      pix.add(im.getPixel(x, y).r.toInt() >> 4);
    }
  }
  return eh.pack4bpp(pix, im.width, im.height);
}

/// Any picture (PNG/JPEG/...) → packed 4-bit grey resized to the container (EvenHub apps).
Uint8List? decodeToGray4(List<int> data, int width, int height) {
  final raw = ehp.imageToGray4Raw(data, width, height);
  if (raw != null) return raw;
  final im = img.decodeImage(Uint8List.fromList(data));
  if (im == null) return null;
  final flat = img.Image(width: im.width, height: im.height)..clear(_g(0));
  img.compositeImage(flat, im);
  final sized = flat.width == width && flat.height == height ? flat : img.copyResize(flat, width: width, height: height);
  final pix = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      pix.add(sized.getPixel(x, y).luminance.toInt() >> 4);
    }
  }
  return eh.pack4bpp(pix, width, height);
}
