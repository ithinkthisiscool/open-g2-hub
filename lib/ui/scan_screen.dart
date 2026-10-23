import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/lens_link.dart';
import 'app_scope.dart';
import 'report_problem_screen.dart';

/// Scan for lenses and pick a complete pair (left + right). Returns true when saved.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.scanner});

  /// Tests inject a scanner; the app uses the Bluetooth one.
  final LensScanner? scanner;
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late final LensScanner _scanner = widget.scanner ?? LensScanner();
  StreamSubscription<List<LensPair>>? _sub;
  Timer? _stopTimer;
  bool _adopting = false;
  List<LensPair> _pairs = [];
  String? _error;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    unawaited(_sub?.cancel());
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final on = await _scanner.bluetoothOn();
      if (!mounted) return; // the page was closed meanwhile: never start a scan nobody stops
      if (!on) {
        setState(() {
          _error = 'Bluetooth is off. Turn it on and scan again.';
          _scanning = false;
        });
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    _sub = _scanner.scan().listen(
      (p) {
        if (mounted) setState(() => _pairs = p);
      },
      onError: (Object e) {
        if (mounted) {
          setState(
            () => _error =
                'Could not scan: $e. Check that Bluetooth is on and that G2 Hub may use "Nearby devices" '
                '(Android settings → Apps → G2 Hub → Permissions).',
          );
        }
      },
    );
    _stopTimer?.cancel(); // an earlier scan's timer must not stop this one
    _stopTimer = Timer(const Duration(seconds: 20), () async {
      unawaited(_sub?.cancel());
      _sub = null;
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _sub?.cancel();
    _scanner.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find your glasses'),
        actions: [IconButton(onPressed: _scanning ? null : _start, icon: const Icon(Icons.refresh))],
        bottom: _scanning ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Take the glasses out of the case (or open the lid) and keep them near the phone. '
            'Each lens shows up as "Even G2_<pair>_L/R_…". A lens that is connected to another phone '
            'or the official Even app does not advertise — close that app first.',
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const Align(alignment: Alignment.centerLeft, child: ReportProblemButton()),
          ],
          if (_pairs.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No glasses found yet.')),
            ),
          for (final p in _pairs)
            Card(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      leading: Icon(p.complete ? Icons.check_circle : Icons.hourglass_top),
                      title: Text('Even G2 pair ${p.pairId}${p.serial != null ? ' · ${p.serial}' : ''}'),
                      subtitle: Text(
                        'Right: ${p.right?.deviceId ?? 'not seen'} ${p.right?.rssi != null ? '(${p.right!.rssi} dBm)' : ''}\n'
                        'Left: ${p.left?.deviceId ?? 'not seen'} ${p.left?.rssi != null ? '(${p.left!.rssi} dBm)' : ''}',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: p.complete && !_adopting
                              ? () async {
                                  // One tap = one pair saved and one page closed (a double tap used to
                                  // pop the page behind this one too).
                                  if (_adopting) return; // two taps in one frame both get here
                                  setState(() => _adopting = true);
                                  try {
                                    unawaited(_sub?.cancel());
                                    await _scanner.stop();
                                    await hub.adoptPair(p);
                                    // Stay "adopting" after success: the page is closing, and a second
                                    // tap during the exit animation must not pop the page behind it.
                                    if (context.mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.of(context).pop(true);
                                  } catch (e) {
                                    if (mounted) {
                                      setState(() {
                                        _error = 'Could not save these glasses: $e';
                                        _adopting = false;
                                      });
                                    }
                                  }
                                }
                              : null,
                          child: Text(p.complete ? 'Use these glasses' : 'Waiting for both lenses…'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
