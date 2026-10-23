import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../hub/background_service.dart';
import 'app_scope.dart';
import 'scan_screen.dart';

/// First run: explain, ask for Bluetooth (Android 12+: Nearby devices = BLUETOOTH_SCAN +
/// BLUETOOTH_CONNECT; Android <= 11: location, which the OS requires for BLE scans) and the
/// notification permission for the background-connection notification, then pair.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String? _error;
  bool _busy = false;

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return true;
    final perms = <Permission>[
      if (Platform.isAndroid) ...[Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse],
      if (Platform.isIOS) Permission.bluetooth,
    ];
    final res = await perms.request();
    // On Android 12+ location is not needed (BLUETOOTH_SCAN is neverForLocation); it is only
    // requested so scans work on Android 11 and older.
    final needed = Platform.isAndroid ? [Permission.bluetoothScan, Permission.bluetoothConnect] : [Permission.bluetooth];
    // (permission_handler reports the Android 12 permissions as granted on Android <= 11,
    // where the location grant is what matters.)
    final ok = needed.every((p) => res[p]?.isGranted ?? false);
    await BackgroundLink.requestPermissions();
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Icon(Icons.visibility_outlined, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('G2 Hub', style: t.headlineMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Run your Even G2 glasses straight from this phone over Bluetooth: dashboard widgets, '
              'menu, tasks, teleprompter and settings. No account, no server, no PC.',
              style: t.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const _Bullet(icon: Icons.bluetooth, text: 'Bluetooth ("Nearby devices") to find and talk to both lenses.'),
            const _Bullet(
              icon: Icons.notifications_outlined,
              text: 'Notifications, for the "connected" notice that keeps the link alive in the background.',
            ),
            const _Bullet(icon: Icons.battery_saver_outlined, text: 'Battery optimisation exemption (optional), so Android does not cut the link.'),
            const _Bullet(
              icon: Icons.warning_amber_outlined,
              text: 'Close the official Even app (or turn off its Bluetooth access) first: the glasses accept one phone at a time and the two apps will fight over them.',
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      final ok = await _requestPermissions();
                      if (!context.mounted) return;
                      setState(() => _busy = false);
                      if (!ok) {
                        setState(() => _error = 'Bluetooth permission is required. Grant it in system settings.');
                        return;
                      }
                      final paired = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ScanScreen()));
                      if (paired == true) {
                        hub.data.onboarded = true;
                        await hub.save();
                        unawaited(hub.connectByUser());
                      }
                    },
              icon: const Icon(Icons.search),
              label: const Text('Allow Bluetooth and find my glasses'),
            ),
            TextButton(onPressed: openAppSettings, child: const Text('Open system app settings')),
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => ListTile(leading: Icon(icon), title: Text(text), contentPadding: EdgeInsets.zero);
}
