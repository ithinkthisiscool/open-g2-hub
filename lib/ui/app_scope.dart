import 'package:flutter/material.dart';

import '../hub/features.dart';
import '../hub/hub_controller.dart';

/// Makes the [HubController] available to every screen (and rebuilds on change).
class AppScope extends InheritedNotifier<HubController> {
  const AppScope({super.key, required HubController hub, required super.child}) : super(notifier: hub);

  static HubController of(BuildContext context, {bool listen = true}) => listen
      ? context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!
      : context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// Show a push result as a snackbar.
void showResult(BuildContext context, PushResult r) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(r.message), backgroundColor: r.ok ? null : Theme.of(context).colorScheme.error));
}
