/// Small device facts the on-device AI needs: free storage (statvfs through dart:ffi, no
/// plugin) and whether the phone is on Wi-Fi (connectivity_plus).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ffi/ffi.dart';

typedef _StatvfsC = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _StatvfsDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

/// Free bytes available to the app on the filesystem holding [path], or null if unknown.
///
/// Uses libc `statvfs` on 64-bit Linux/Android, where glibc and bionic share the LP64 layout
/// (f_bsize, f_frsize, f_blocks, f_bfree, f_bavail, … all 8 bytes). Elsewhere: null, and the
/// download then only fails if the disk really fills up.
Future<int?> freeDiskBytes(String path) async {
  if (!(Platform.isAndroid || Platform.isLinux) || sizeOf<IntPtr>() != 8) return null;
  try {
    final fn = DynamicLibrary.process().lookupFunction<_StatvfsC, _StatvfsDart>('statvfs');
    final buf = calloc<Uint8>(256);
    final p = path.toNativeUtf8();
    try {
      if (fn(p, buf) != 0) return null;
      final words = buf.cast<Uint64>();
      final frsize = words[1] == 0 ? words[0] : words[1];
      return frsize * words[4]; // f_bavail: blocks available to unprivileged users
    } finally {
      calloc.free(buf);
      calloc.free(p);
    }
  } catch (_) {
    return null;
  }
}

/// True when a Wi-Fi or Ethernet network is up (the "Wi-Fi only" download rule).
Future<bool> onUnmeteredNetwork() async {
  try {
    final r = await Connectivity().checkConnectivity();
    return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
  } catch (_) {
    return false;
  }
}

/// MemAvailable from /proc/meminfo (bytes), or null.
Future<int?> availableRamBytes({String path = '/proc/meminfo'}) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final m = RegExp(r'MemAvailable:\s+(\d+)\s*kB').firstMatch(await f.readAsString());
    return m == null ? null : int.parse(m.group(1)!) * 1024;
  } catch (_) {
    return null;
  }
}
