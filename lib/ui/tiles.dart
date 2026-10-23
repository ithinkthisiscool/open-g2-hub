/// Widget-style tiles for the top-level tabs: each feature is a tile (icon, title, a one-line
/// live status such as "Sunny 18°" or "3 tasks") in a responsive grid; tapping it opens the
/// feature's own page. Pages put basic options first and fold the rest into "Advanced".
library;

import 'package:flutter/material.dart';

import 'common.dart';

/// One feature tile.
class FeatureTile extends StatelessWidget {
  const FeatureTile({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.onTap,
    this.beta = false,
    this.active = false,
    this.attention = false,
  });
  final IconData icon;
  final String title;

  /// The one-line live status under the title.
  final String status;
  final VoidCallback onTap;
  final bool beta;

  /// Highlighted (feature on / running).
  final bool active;

  /// Needs the user (permission missing, error): the status is shown in the error colour.
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fg = active ? cs.onPrimaryContainer : cs.onSurface;
    return Semantics(
      button: true,
      label: '$title, $status',
      excludeSemantics: true,
      child: Material(
        color: active ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: cs.surface.withValues(alpha: active ? 0.5 : 1), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, size: 20, color: active ? cs.primary : cs.onSurfaceVariant),
                    ),
                    const Spacer(),
                    if (beta) const BetaBadge(),
                  ],
                ),
                const Spacer(),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(color: attention ? cs.error : (active ? fg : cs.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Columns for a width: 2 on phones, 3 on small tablets / landscape, 4 on large screens.
int tileColumns(double width) => width >= 900 ? 4 : (width >= 560 ? 3 : 2);

/// A responsive grid of tiles that sizes itself (use inside a scrolling page).
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.tiles});
  final List<Widget> tiles;
  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    // Taller tiles when the user enlarged the text, so nothing is cut off.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final extent = 112 + 30 * (scale - 1).clamp(0.0, 2.0);
    return LayoutBuilder(
      builder: (context, c) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: tiles.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: tileColumns(c.maxWidth),
          mainAxisExtent: extent,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemBuilder: (_, i) => tiles[i],
      ),
    );
  }
}

/// A small heading above a group of tiles.
class TileHeading extends StatelessWidget {
  const TileHeading(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// Less-used options, folded away (progressive disclosure).
class AdvancedSection extends StatelessWidget {
  const AdvancedSection({super.key, required this.children, this.title = 'Advanced'});
  final List<Widget> children;
  final String title;
  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          leading: const Icon(Icons.tune),
          title: Text(title),
          children: children,
        ),
      );
}

/// A feature's own page: app bar with the connection chip, then its cards.
class SectionPage extends StatelessWidget {
  const SectionPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: const [Padding(padding: EdgeInsets.only(right: 16), child: ConnectionDot())],
        ),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: children),
        ),
      );
}

/// Open a feature page.
Future<void> openSection(BuildContext context, String title, List<Widget> children) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SectionPage(title: title, children: children)));
