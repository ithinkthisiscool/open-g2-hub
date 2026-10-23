import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'hub/background_service.dart';
import 'hub/even_ai_hub.dart';
import 'hub/hub_controller.dart';
import 'services/diagnostics_recorder.dart';
import 'ui/ai/ai_scope.dart';
import 'ui/app_scope.dart';
import 'ui/home_shell.dart';
import 'ui/onboarding_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Remember recent uncaught errors for Settings → Help → Report a problem (chains to the
  // existing handlers: nothing changes about how errors are shown or handled).
  DiagnosticsRecorder.instance.installHooks();
  FlutterForegroundTask.initCommunicationPort();
  BackgroundLink.init();
  final hub = HubController();
  await hub.load();
  final ai = AiHub(hub); // Even AI + live translate: follows the connection, no setup step
  await ai.load();
  ai.sync = hub.changed; // assistant edits go through the same debounced, offline-queued auto-sync
  runApp(G2App(hub: hub, ai: ai));
  if (hub.data.onboarded && hub.data.glasses != null && hub.data.autoConnect) {
    unawaited(hub.connect());
  }
}

class G2App extends StatelessWidget {
  const G2App({super.key, required this.hub, this.ai});
  final HubController hub;
  final AiHub? ai;

  @override
  Widget build(BuildContext context) {
    final app = AppScope(
      hub: hub,
      child: ListenableBuilder(
        listenable: hub,
        builder: (context, _) {
          final ui = hub.data.ui;
          return MaterialApp(
            title: 'G2 Hub',
            debugShowCheckedModeBanner: false,
            themeMode: themeModeFor(ui.theme),
            theme: buildTheme(ui.theme, ui.accent, Brightness.light),
            darkTheme: buildTheme(ui.theme, ui.accent, Brightness.dark),
            // WithForegroundTask keeps the service running when the user presses back.
            home: WithForegroundTask(child: hub.data.onboarded ? const HomeShell() : const OnboardingScreen()),
          );
        },
      ),
    );
    return ai == null ? app : AiScope(ai: ai!, child: app);
  }
}
