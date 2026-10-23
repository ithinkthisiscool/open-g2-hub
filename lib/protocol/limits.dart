/// Firmware field caps (port of g2/limits.py). Structural limits raise ([checkCount]);
/// free text is truncated on a UTF-8 character boundary ([utf8Fit]).
library;

import 'dart:convert';

import 'pb.dart';

// ---- EvenHub (SID 0xE0) ----
const int evenhubNameMaxBytes = 15;
const int evenhubTextMaxBytes = 998;
const int evenhubTextUpgradeMaxBytes = 1998;
const int evenhubListMaxItems = 20;
const int evenhubListItemMaxBytes = 62;

// ---- Watchface layout file ----
const int watchfaceVersionMaxBytes = 14;
const int watchfaceHashMaxBytes = 30;
const int watchfaceWidgetSeqMax = 5;

// ---- Translate (SID 0x05) ----
const int translateTextMaxBytes = 1024;
const int translateKeyMaxBytes = 8;

// ---- Navigation (SID 0x08) ----
const int navLocationMaxNames = 20;

// ---- Teleprompter (SID 0x06) ----
const int teleprompterPageMaxBytes = 1024;

// ---- Notification (SID 0x04) ----
const int notificationAppIdMaxBytes = 32;
const int notificationDisplayNameMaxBytes = 32;

// ---- Notification JSON file (EFS fileType 1; firmware strncpy caps, bytes) ----
const int notificationJsonAppIdMaxBytes = 63;
const int notificationJsonTitleMaxBytes = 63;
const int notificationJsonSubtitleMaxBytes = 63;
const int notificationJsonMessageMaxBytes = 511;
const int notificationJsonDisplayNameMaxBytes = 31;

// ---- Menu (SID 0x03) ----
const int menuItemNameMaxBytes = 31;

// ---- Dashboard stock (SID 0x01) ----
const int stockCodeMaxBytes = 63;
const int stockNameMaxBytes = 127;

/// [text] cut to at most [maxBytes] UTF-8 bytes, never splitting a character. In-limit text
/// is returned unchanged.
String utf8Fit(String text, int maxBytes) {
  final data = utf8.encode(text);
  if (data.length <= maxBytes) return text;
  var cut = maxBytes < 0 ? 0 : maxBytes;
  while (cut > 0 && (data[cut] & 0xC0) == 0x80) {
    cut -= 1;
  }
  return utf8.decode(data.sublist(0, cut));
}

/// Raise if a repeated field has more than [maxN] entries.
void checkCount(String name, int n, int maxN) {
  if (n > maxN) {
    throw G2ValueError('$name: $n entries exceeds the firmware limit of $maxN');
  }
}
