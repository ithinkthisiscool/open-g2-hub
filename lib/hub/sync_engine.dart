/// Central auto-sync: every piece of glasses state (settings, weather, menu, tasks, calendar,
/// news, stocks, health, widget order, notifications setup, ...) is a named *section* with a
/// push function. Nobody presses "Send": the app marks a section dirty when its data changes and
/// the engine pushes it.
///
/// * Debounce: edits are pushed [debounce] after the last change (default 1 s).
/// * Coalescing: a section marked dirty several times (or while it is already queued) is pushed
///   once; a change that arrives while it is being pushed queues exactly one more push.
/// * One push at a time (the glasses' dashboard channel is shared), in [order] priority.
/// * Offline queue: changes made while disconnected stay dirty and go out on connect.
/// * Reconnect restore: on every connect all sections are pushed in [order] (the hub's
///   apply_profile order: settings, weather, menu, tasks, calendar, news, ...).
/// * Failures retry with exponential backoff (2 s, 4 s, ... capped at [maxBackoff]) while connected.
///
/// Generic over the connection context [C] (G2Features in the app, a fake in tests).
library;

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart' as clk;
import 'package:flutter/foundation.dart';

/// Result of one section push.
class SyncOutcome {
  const SyncOutcome(this.ok, [this.message = '']);
  const SyncOutcome.ok([this.message = '']) : ok = true;
  const SyncOutcome.failed(this.message) : ok = false;

  /// Nothing to send (e.g. feature off / no data): counts as synced.
  const SyncOutcome.skipped([this.message = 'nothing to send']) : ok = true;
  final bool ok;
  final String message;
}

typedef SyncPush<C> = Future<SyncOutcome> Function(C ctx);

enum SectionStatus { idle, pending, syncing, synced, failed }

class SectionState {
  SectionState(this.key, this.label, this.push, this.restore);
  final String key;
  final String label;
  final Object push;

  /// Pushed as part of the reconnect restore.
  final bool restore;
  SectionStatus status = SectionStatus.idle;
  DateTime? lastSynced;
  String? lastError;
  int failures = 0;
  DateTime? dirtySince;

  /// Earliest time the next push may run: the debounce after the LAST edit, or the retry time
  /// after a failure. Every edit moves it, so a burst of edits is pushed once, after the pause.
  DateTime? dueAt;
}

class SyncEngine<C> extends ChangeNotifier {
  SyncEngine({
    this.debounce = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    DateTime Function()? clock,
    this.log,
  }) : _clock = clock ?? (() => clk.clock.now());

  final Duration debounce;
  final Duration maxBackoff;
  final DateTime Function() _clock;
  final void Function(String message, {bool warn})? log;

  final Map<String, SectionState> _sections = {};

  /// Priority / restore order (registration order).
  final List<String> order = [];
  final Set<String> _dirty = {};
  C? _ctx;
  Timer? _timer;
  bool _running = false;
  int _generation = 0;

  /// Keys pushed so far, in order (diagnostics and tests).
  final List<String> history = [];

  bool get connected => _ctx != null;
  bool get busy => _running;
  Iterable<SectionState> get sections => order.map((k) => _sections[k]!);
  SectionState? section(String key) => _sections[key];
  bool isDirty(String key) => _dirty.contains(key);
  Set<String> get dirty => Set.unmodifiable(_dirty);

  /// Register a section. Order of registration = push / restore priority.
  void register(String key, SyncPush<C> push, {String? label, bool restore = true}) {
    if (_sections.containsKey(key)) {
      _sections[key] = SectionState(key, label ?? key, push, restore)
        ..status = _sections[key]!.status
        ..lastSynced = _sections[key]!.lastSynced
        ..failures = _sections[key]!.failures
        ..dirtySince = _sections[key]!.dirtySince
        ..dueAt = _sections[key]!.dueAt;
      return;
    }
    _sections[key] = SectionState(key, label ?? key, push, restore);
    order.add(key);
  }

  /// The data behind [key] changed: push it [debounce] after the last change (or on connect).
  void markDirty(String key, {Duration? delay}) {
    final s = _sections[key];
    if (s == null) return;
    final wait = delay ?? debounce;
    _dirty.add(key);
    s.dirtySince ??= _clock();
    s.dueAt = _clock().add(wait);
    if (s.status != SectionStatus.syncing) s.status = SectionStatus.pending;
    notifyListeners();
    if (_ctx != null) _schedule(wait);
  }

  /// Push now, without waiting for the debounce (used by periodic refreshes).
  void pushNow(String key) => markDirty(key, delay: Duration.zero);

  /// Connected: queue every restore section (reconnect restore) plus anything dirty.
  void attach(C ctx, {bool restoreAll = true}) {
    _ctx = ctx;
    _generation++;
    // Changes queued while disconnected go out right away (their debounce ran long ago).
    for (final k in _dirty) {
      _sections[k]!.dueAt = _clock();
    }
    if (restoreAll) {
      for (final k in order) {
        if (_sections[k]!.restore) {
          _dirty.add(k);
          _sections[k]!.status = SectionStatus.pending;
          _sections[k]!.dirtySince ??= _clock();
          _sections[k]!.dueAt = _clock();
        }
      }
    }
    notifyListeners();
    _schedule(Duration.zero);
  }

  /// Disconnected: keep dirty sections queued for the next connect.
  void detach() {
    _ctx = null;
    _generation++;
    _timer?.cancel();
    _timer = null;
    for (final s in _sections.values) {
      if (s.status == SectionStatus.syncing) s.status = SectionStatus.pending;
      if (_dirty.contains(s.key) && s.status == SectionStatus.failed) s.status = SectionStatus.pending;
    }
    notifyListeners();
  }

  /// Developer "Force resync": everything, now.
  void resyncAll() {
    for (final k in order) {
      _dirty.add(k);
      _sections[k]!.status = SectionStatus.pending;
      _sections[k]!.dirtySince ??= _clock();
      _sections[k]!.dueAt = _clock();
    }
    notifyListeners();
    if (_ctx != null) _schedule(Duration.zero);
  }

  void _schedule(Duration d) {
    if (_running) return; // the running loop picks new dirty keys up itself
    _timer?.cancel();
    _timer = Timer(d, _drain);
  }

  /// Sections marked dirty in an earlier session (before [attach]) or before a restart have no
  /// due time yet: they are due now.
  DateTime _due(SectionState s, DateTime now) => s.dueAt ?? now;

  Duration _backoff(int failures) {
    final s = min(maxBackoff.inMilliseconds, 2000 * pow(2, max(0, failures - 1)).toInt());
    return Duration(milliseconds: s);
  }

  Future<void> _drain() async {
    _timer = null;
    if (_running || _ctx == null) return;
    _running = true;
    final gen = _generation;
    try {
      while (_ctx != null && gen == _generation) {
        // Only keys whose debounce has elapsed and whose retry time has come.
        final now = _clock();
        String? next;
        Duration? wait;
        for (final k in order) {
          if (!_dirty.contains(k)) continue;
          final s = _sections[k]!;
          final due = _due(s, now);
          if (!due.isAfter(now)) {
            next = k;
            break;
          }
          final w = due.difference(now);
          if (wait == null || w < wait) wait = w;
        }
        if (next == null) {
          if (wait != null) {
            _timer?.cancel();
            _timer = Timer(wait, _drain);
          }
          return;
        }
        final s = _sections[next]!;
        _dirty.remove(next);
        s.dirtySince = null;
        s.dueAt = null;
        s.status = SectionStatus.syncing;
        notifyListeners();
        SyncOutcome r;
        try {
          r = await (s.push as SyncPush<C>)(_ctx as C);
        } catch (e) {
          r = SyncOutcome.failed('$e');
        }
        history.add(next);
        if (gen != _generation) {
          // Disconnected mid-push: it goes again on the next connect.
          _dirty.add(next);
          s.dirtySince ??= _clock();
          s.dueAt ??= _clock();
          s.status = SectionStatus.pending;
          break;
        }
        if (r.ok) {
          s.failures = 0;
          s.lastError = null;
          s.lastSynced = _clock();
          s.status = _dirty.contains(next) ? SectionStatus.pending : SectionStatus.synced;
        } else {
          s.failures++;
          s.lastError = r.message;
          s.status = SectionStatus.failed;
          log?.call('Sync ${s.label}: ${r.message} (retry ${s.failures})', warn: true);
          if (!_dirty.contains(next)) {
            _dirty.add(next);
            s.dirtySince = _clock();
          }
          // Retry after the backoff (or later, if the user is still editing it).
          final retry = _clock().add(_backoff(s.failures));
          final cur = s.dueAt;
          s.dueAt = cur == null || cur.isBefore(retry) ? retry : cur;
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      if (_ctx != null && _dirty.isNotEmpty && _timer == null) _schedule(Duration.zero);
    }
  }

  /// Short human status of one section: "Synced · just now", "Will sync when glasses connect".
  String describe(String key) {
    final s = _sections[key];
    if (s == null) return '';
    if (_ctx == null && (_dirty.contains(key) || s.lastSynced == null)) return 'Will sync when glasses connect';
    switch (s.status) {
      case SectionStatus.pending:
        return 'Syncing soon…';
      case SectionStatus.syncing:
        return 'Syncing…';
      case SectionStatus.failed:
        return 'Not synced yet · retrying';
      case SectionStatus.synced:
      case SectionStatus.idle:
        return s.lastSynced == null ? 'Not synced yet' : 'Synced · ${ago(s.lastSynced!, _clock())}';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

String ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
