/// Shared building blocks for the screens: page layout, cards with a subtle sync status,
/// the connection chip, empty states and Beta badges.
library;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../hub/features.dart' show PushResult;
import '../hub/hub_controller.dart';
import '../hub/sync_engine.dart';
import '../services/data_services.dart' show LocationAccess, LocationService;
import 'app_scope.dart';

/// A tab page: big title, connection chip, optional intro text, then cards.
class PageList extends StatelessWidget {
  const PageList({super.key, required this.title, this.subtitle, required this.children});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [Text(title, style: t.headlineMedium), const ConnectionChip()],
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(subtitle!, style: t.bodyMedium),
          ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

/// "Even G2 42 · Connected" style chip.
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (hub.status) {
      LinkStatus.connected => ('Connected', Colors.green),
      LinkStatus.connecting => ('Connecting…', Colors.orange),
      _ when hub.data.handedOff => ('With the Even app', cs.tertiary),
      LinkStatus.disconnected => ('Not connected', cs.outline),
      LinkStatus.noGlasses => ('No glasses', cs.outline),
    };
    final name = hub.data.activePair?.name;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(name == null ? label : '$name · $label', style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// A compact connection indicator for app bars (a dot + one word), so a long pair name never
/// squeezes the title or the back button on a phone.
class ConnectionDot extends StatelessWidget {
  const ConnectionDot({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (hub.status) {
      LinkStatus.connected => ('On', Colors.green),
      LinkStatus.connecting => ('…', Colors.orange),
      _ when hub.data.handedOff => ('Even app', cs.tertiary),
      _ => ('Off', cs.outline),
    };
    final long = switch (hub.status) {
      LinkStatus.connected => 'Glasses connected',
      LinkStatus.connecting => 'Connecting to the glasses',
      _ when hub.data.handedOff => 'Glasses handed off to the Even app',
      LinkStatus.disconnected => 'Glasses not connected',
      LinkStatus.noGlasses => 'No glasses paired',
    };
    return Tooltip(
      message: long,
      child: Semantics(
        label: long,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key, this.label = 'Beta'});
  final String label;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onTertiaryContainer)),
    );
  }
}

/// The subtle sync line under a card title: "Synced · just now".
class SyncStatus extends StatelessWidget {
  const SyncStatus(this.section, {super.key});
  final String section;
  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).services.sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final s = sync.section(section);
        if (s == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final hub = AppScope.of(context);
        final text = hub.data.handedOff && !sync.connected && (sync.isDirty(section) || s.lastSynced == null)
            ? 'Will sync when you take the glasses back'
            : sync.describe(section);
        final (icon, color) = switch (s.status) {
          SectionStatus.syncing || SectionStatus.pending => (Icons.sync, cs.primary),
          SectionStatus.failed => (Icons.sync_problem, cs.error),
          _ => (sync.connected ? Icons.check_circle_outline : Icons.cloud_queue, cs.outline),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A rounded section card: icon, title (+ Beta), sync status, intro text and content.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.sync,
    this.beta = false,
    this.trailing,
    required this.children,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? sync;
  final bool beta;
  final Widget? trailing;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(title, style: t.titleLarge)),
                          if (beta) const BetaBadge(),
                        ],
                      ),
                      if (sync != null) SyncStatus(sync!),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(subtitle!, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.text, this.icon = Icons.inbox_outlined});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: cs.outline),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A button for a real action (start an app, find glasses, …): spinner while running, the
/// result as a snackbar. [needsGlasses] disables it while not connected.
class ActionButton extends StatefulWidget {
  const ActionButton({super.key, required this.label, required this.onPressed, this.icon, this.needsGlasses = true, this.outlined = false});
  final String label;
  final IconData? icon;
  final Future<Object?> Function() onPressed;
  final bool needsGlasses;
  final bool outlined;
  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final enabled = !_busy && (!widget.needsGlasses || hub.status == LinkStatus.connected);
    Future<void> go() async {
      setState(() => _busy = true);
      try {
        final r = await widget.onPressed();
        if (r is PushResult && context.mounted) showMessage(context, r.message, ok: r.ok);
      } catch (e) {
        if (context.mounted) showMessage(context, friendlyError(e), ok: false);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    final icon = _busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(widget.icon ?? Icons.play_arrow);
    final label = Text(widget.needsGlasses && hub.status != LinkStatus.connected ? '${widget.label} (connect first)' : widget.label);
    return widget.outlined
        ? OutlinedButton.icon(onPressed: enabled ? go : null, icon: icon, label: label)
        : FilledButton.icon(onPressed: enabled ? go : null, icon: icon, label: label);
  }
}

String friendlyError(Object e) {
  final s = '$e';
  for (final p in ['Bad state: ', 'FormatException: ', 'Exception: ']) {
    if (s.startsWith(p)) return s.substring(p.length);
  }
  return s;
}

void showMessage(BuildContext context, String text, {bool ok = true}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), backgroundColor: ok ? null : Theme.of(context).colorScheme.error));
}

/// Push a full-screen page.
void openPage(BuildContext context, String title, Widget body, {List<Widget>? actions}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        body: SafeArea(child: body),
      ),
    ),
  );
}

/// Text field that commits on every change (the sync engine debounces the push).
///
/// [validator] returns an error for a value that cannot be used: it is shown under the field
/// and [onChanged] is not called, so a typo never silently replaces a good value. When
/// [initial] changes from outside (profile applied, backup restored) and the field is not being
/// edited, the field shows the new value.
class CommitField extends StatefulWidget {
  const CommitField({
    super.key,
    required this.initial,
    required this.onChanged,
    this.label,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.maxLength,
    this.validator,
  });
  final String initial;
  final ValueChanged<String> onChanged;
  final String? label;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final int? maxLength;
  final String? Function(String value)? validator;
  @override
  State<CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<CommitField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  String? _error;

  @override
  void didUpdateWidget(CommitField old) {
    super.didUpdateWidget(old);
    if (widget.initial != old.initial && widget.initial != _c.text && !_focus.hasFocus) {
      _c.text = widget.initial;
      _error = null;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        focusNode: _focus,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(labelText: widget.label, hintText: widget.hint, errorText: _error, errorMaxLines: 3),
        onChanged: (v) {
          final err = widget.validator?.call(v);
          if (err != _error) setState(() => _error = err);
          if (err == null) widget.onChanged(v);
        },
      );
}

/// Explains a missing permission (or a switched-off phone setting) with the button that fixes it.
class PermissionBanner extends StatelessWidget {
  const PermissionBanner({super.key, required this.icon, required this.title, required this.text, this.actionLabel, this.onAction});
  final IconData icon;
  final String title;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.secondaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: cs.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSecondaryContainer))),
              ],
            ),
            const SizedBox(height: 4),
            Text(text, style: TextStyle(color: cs.onSecondaryContainer)),
            if (actionLabel != null && onAction != null)
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onAction, child: Text(actionLabel!))),
          ],
        ),
      ),
    );
  }
}

/// A permission was refused: say what it is for and offer the app's settings page.
void showPermissionMessage(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: 'Settings', onPressed: () => ph.openAppSettings()),
    ));
}

/// Ask for location from a user action. When it is not available, explain why and offer the
/// screen that fixes it. Returns true when the app may use the location.
Future<bool> ensureLocation(BuildContext context, {String why = 'this'}) async {
  final a = await LocationService.requestAccess();
  if (a == LocationAccess.granted) return true;
  if (!context.mounted) return false;
  final (text, label, action) = switch (a) {
    LocationAccess.serviceOff => ('Location is switched off on this phone. Turn it on to use $why.', 'Turn on', LocationService.openLocationSettings),
    LocationAccess.deniedForever => (
        'Location is blocked for G2 Hub. Allow it in the app settings (Permissions → Location) to use $why.',
        'Settings',
        LocationService.openAppSettings
      ),
    _ => ('Location was not allowed, so $why cannot use it. Allow it when asked, or use the settings.', 'Settings', LocationService.openAppSettings),
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(label: label, onPressed: () => action()),
    ));
  return false;
}
