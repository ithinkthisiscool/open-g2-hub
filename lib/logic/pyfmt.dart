/// Python number formatting/rounding on the exact binary value of a double (half to even),
/// so formatted numbers match the hub byte for byte (f'{x:.1f}', round(x, 2), round(x, -1)).
library;

/// Exact rational value of a finite double: (numerator, denominator).
(BigInt, BigInt) _exact(double x) {
  if (x == 0) return (BigInt.zero, BigInt.one);
  final bits = x.abs();
  // Decompose with repeated scaling (exact for doubles).
  var m = bits;
  var e = 0;
  while (m != m.truncateToDouble()) {
    m *= 2;
    e++;
  }
  var num = BigInt.from(m);
  var den = BigInt.one << e;
  if (x < 0) num = -num;
  return (num, den);
}

/// round-half-even of num/den to an integer.
BigInt _roundHalfEven(BigInt num, BigInt den) {
  final neg = num.isNegative;
  final n = num.abs();
  final q = n ~/ den;
  final r = n - q * den;
  final twice = r * BigInt.two;
  BigInt res;
  if (twice > den) {
    res = q + BigInt.one;
  } else if (twice < den) {
    res = q;
  } else {
    res = q.isEven ? q : q + BigInt.one;
  }
  return neg ? -res : res;
}

/// Python `f'{x:.Nf}'`.
String pyFixed(double x, int digits) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x > 0 ? 'inf' : '-inf';
  final (num, den) = _exact(x);
  final scaled = _roundHalfEven(num * BigInt.from(10).pow(digits), den);
  final neg = scaled.isNegative || (x.isNegative && scaled == BigInt.zero);
  var s = scaled.abs().toString();
  if (digits > 0) {
    s = s.padLeft(digits + 1, '0');
    s = '${s.substring(0, s.length - digits)}.${s.substring(s.length - digits)}';
  }
  return neg ? '-$s' : s;
}

/// Python round(x, digits) for a float result (digits may be negative).
double pyRoundTo(double x, int digits) {
  if (!x.isFinite) return x;
  final (num, den) = _exact(x);
  if (digits >= 0) {
    final p = BigInt.from(10).pow(digits);
    final r = _roundHalfEven(num * p, den);
    return double.parse(_ratioString(r, digits));
  }
  final p = BigInt.from(10).pow(-digits);
  final r = _roundHalfEven(num, den * p);
  return (r * p).toDouble();
}

String _ratioString(BigInt r, int digits) {
  var s = r.abs().toString().padLeft(digits + 1, '0');
  if (digits > 0) s = '${s.substring(0, s.length - digits)}.${s.substring(s.length - digits)}';
  return r.isNegative ? '-$s' : s;
}

/// Python round(x) → int (half to even).
int pyRoundInt(double x) {
  final (num, den) = _exact(x);
  return _roundHalfEven(num, den).toInt();
}

/// Python str(float) for plain values (repr): 1.0 → '1.0', 1e16 → '1e+16'.
String pyFloatRepr(double x) {
  if (x == x.truncateToDouble() && x.abs() < 1e16) return '${x.toInt()}.0';
  return x.toString();
}
