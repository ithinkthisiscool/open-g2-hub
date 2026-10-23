/// First-time setup guide (like the hub's wizard): Bluetooth → get ready → find → connect →
/// optional notification access and location.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../hub/background_service.dart';
import '../hub/hub_controller.dart';
import '../services/data_services.dart';
import 'app_scope.dart';
import 'scan_screen.dart';

class SetupGuide extends StatefulWidget {
  const SetupGuide({super.key});
  @override
  State<SetupGuide> createState() => _SetupGuideState();
}

class _SetupGuideState extends State<SetupGuide> {
  int _step = 0;

  Future<void> _permissions() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    await BackgroundLink.requestPermissions();
    if (mounted) setState(() => _step = 1);
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final notif = hub.services.notifications;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your glasses')),
      body: Stepper(
        currentStep: _step,
        onStepTapped: (i) => setState(() => _step = i),
        controlsBuilder: (context, d) => const SizedBox.shrink(),
        steps: [
          Step(
            title: const Text('Bluetooth'),
            isActive: _step >= 0,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('The app talks to your glasses over Bluetooth and keeps the link alive in the background.'),
                const SizedBox(height: 8),
                FilledButton(onPressed: _permissions, child: const Text('Allow')),
              ],
            ),
          ),
          Step(
            title: const Text('Get ready'),
            isActive: _step >= 1,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Take your glasses out of the case. If the official Even app is connected to them, close it '
                  '(or turn off its Bluetooth access): glasses talk to one phone app at a time.',
                ),
                const SizedBox(height: 8),
                FilledButton(onPressed: () => setState(() => _step = 2), child: const Text('Next')),
              ],
            ),
          ),
          Step(
            title: const Text('Find'),
            isActive: _step >= 2,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Look for glasses nearby and pick yours. Accept the pairing request for each lens.'),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () async {
                    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ScanScreen()));
                    if (ok == true) {
                      hub.data.onboarded = true;
                      await hub.save();
                      unawaited(hub.connectByUser());
                      if (mounted) setState(() => _step = 3);
                    }
                  },
                  child: const Text('Find glasses'),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('Connect'),
            isActive: _step >= 3,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (hub.status) {
                  LinkStatus.connected => '✓ Connected. Your glasses are ready to use.',
                  LinkStatus.connecting => 'Connecting…',
                  _ => 'Waiting for the glasses. Keep them out of the case and close to the phone.',
                }),
                const SizedBox(height: 8),
                FilledButton(onPressed: () => setState(() => _step = 4), child: Text(hub.status == LinkStatus.connected ? 'Next' : 'Skip')),
              ],
            ),
          ),
          Step(
            title: const Text('Extras (optional)'),
            isActive: _step >= 4,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Phone notifications on the glasses need notification access. Live weather and navigation use your location.'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (notif.supported) OutlinedButton(onPressed: notif.openAccessSettings, child: const Text('Notification access')),
                    OutlinedButton(onPressed: LocationService.request, child: const Text('Allow location')),
                    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
