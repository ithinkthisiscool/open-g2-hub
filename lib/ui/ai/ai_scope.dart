import 'package:flutter/material.dart';

import '../../hub/even_ai_hub.dart';

/// Makes the [AiHub] available to the AI screens (rebuilds on change).
class AiScope extends InheritedNotifier<AiHub> {
  const AiScope({super.key, required AiHub ai, required super.child}) : super(notifier: ai);

  static AiHub of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AiScope>()!.notifier!;

  static AiHub? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AiScope>()?.notifier;
}

void snack(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), backgroundColor: error ? Theme.of(context).colorScheme.error : null));
}

/// Section header used across the AI screens.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ),
        ?trailing,
      ],
    ),
  );
}
