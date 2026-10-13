import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/widgets/brand_logo.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/theme_transition.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/window_title_bar.dart';

/// Shared shell for secondary, full-window pages.
///
/// Desktop pages use an origin breadcrumb (Conversation / Current page), keep
/// page-specific actions on the right, and move cross-page navigation into one
/// quiet overflow menu. Mobile retains the platform-standard implied back
/// button because it is the familiar compact-screen interaction.
class UtilityPage extends StatelessWidget {
  /// Creates a secondary page shell.
  const UtilityPage({
    super.key,
    required this.route,
    required this.title,
    required this.body,
    this.parent,
    this.actions = const [],
    this.primaryAction,
    this.bottomNavigationBar,
    this.floatingActionButton,
  });

  /// The top-level route represented by this page.
  final String route;

  /// Localized page title.
  final String title;

  /// The list this page drilled down from, for a detail page. Renders as a third
  /// breadcrumb (`Conversation / Services / <name>`) whose middle segment is the
  /// way back up; omit it on a top-level page.
  final UtilityParent? parent;

  /// Page content below the shared title bar.
  final Widget body;

  /// Actions specific to this page, rendered before the desktop page menu.
  final List<Widget> actions;

  /// The page's main action, after [actions]; see [UtilityPrimaryAction].
  final UtilityPrimaryAction? primaryAction;

  /// Optional narrow-layout navigation supplied by the page.
  final Widget? bottomNavigationBar;

  /// Optional page floating action button.
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final scaffold = Scaffold(
      appBar: UtilityPageTitleBar(
        route: route,
        title: title,
        parent: parent,
        actions: actions,
        primaryAction: primaryAction,
      ),
      body: wide
          ? Row(
              children: [
                SizedBox(
                  width: 208,
                  child: _WorkspaceNavigation(route: parent?.route ?? route),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar:
          bottomNavigationBar ??
          (wide
              ? null
              : _WorkspaceNavigation(
                  route: parent?.route ?? route,
                  compact: true,
                )),
      floatingActionButton: floatingActionButton,
    );
    return AppPageShortcuts(currentRoute: route, child: scaffold);
  }
}

/// Persistent destinations use the same order on touch and wide layouts.
class _WorkspaceNavigation extends StatelessWidget {
  const _WorkspaceNavigation({required this.route, this.compact = false});
  final String route;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final entries = [
      ('/', Icons.chat_bubble_outline_rounded, l10n.utilityChat),
      ('/manage', Icons.dns_outlined, l10n.manageServices),
      ('/sessions', Icons.history_rounded, l10n.localSessionsTitle),
      ('/logs', Icons.article_outlined, l10n.logsTitle),
      ('/settings', Icons.settings_outlined, l10n.settingsTitle),
    ];
    Widget destination((String, IconData, String) entry) {
      final selected = entry.$1 == route;
      return Semantics(
        selected: selected,
        button: true,
        child: Tooltip(
          message: entry.$3,
          child: Material(
            color: selected ? surfaceSelection(scheme) : Colors.transparent,
            borderRadius: BorderRadius.circular(kRowRadius),
            child: InkWell(
              key: Key('workspace-nav-${entry.$1}'),
              mouseCursor: clickable,
              borderRadius: BorderRadius.circular(kRowRadius),
              onTap: selected
                  ? null
                  : () => _openUtilityRoute(context, route, entry.$1),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: compact ? 12 : 8,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Icon(
                      entry.$2,
                      size: compact ? 21 : 18,
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry.$3,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: selected
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(compact ? 8 : 10),
          child: compact
              ? Row(
                  children: [
                    for (final entry in entries)
                      Expanded(child: destination(entry)),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 18),
                      child: Row(
                        children: [
                          const BrandLogo(size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              l10n.appTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final entry in entries) ...[
                      destination(entry),
                      const SizedBox(height: 2),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// The list a detail page sits under, named so the breadcrumb can lead back to
/// it. [route] is the top-level route the page menu should treat as current, so a
/// detail page highlights the section it belongs to.
@immutable
class UtilityParent {
  /// Creates a parent breadcrumb segment.
  const UtilityParent({required this.title, required this.route});

  /// Localized title of the list this page came from.
  final String title;

  /// Route that list lives at.
  final String route;
}

/// Installs app-level page shortcuts while leaving [child] unchanged.
///
/// Home uses route `/`, so a utility page is pushed above the live
/// conversation. Utility pages replace one another and retain that same
/// conversation beneath them. Compact platforms do not install desktop keys.
class AppPageShortcuts extends StatelessWidget {
  /// Creates a shortcut scope for [currentRoute].
  const AppPageShortcuts({
    super.key,
    required this.currentRoute,
    required this.child,
  });

  /// The top-level route rendered by [child].
  final String currentRoute;

  /// Content receiving the shortcut scope.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return child;
    return CallbackShortcuts(
      bindings: _pageShortcuts(context, currentRoute),
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// A page's main title-bar action. It is labelled while the bar has room for
/// the label beside the title, the page's other actions and the page menu;
/// otherwise it is a filled icon button whose tooltip (and so its semantics)
/// carries the full [label]. Either form keeps [key], focus and activation.
@immutable
class UtilityPrimaryAction {
  /// Creates a primary action.
  const UtilityPrimaryAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// Key of the button, in either form.
  final Key key;

  /// The button's icon.
  final IconData icon;

  /// The full label: shown, or the icon button's tooltip.
  final String label;

  /// Called on activation.
  final VoidCallback onPressed;

  // The labelled form's own geometry, so its width is known before layout.
  static const _padding = EdgeInsetsDirectional.fromSTEB(12, 0, 16, 0);
  static const _iconSize = 18.0;
  static const _gap = 8.0;

  /// The labelled form's width in [context].
  double labelledWidth(BuildContext context) {
    final style = FilledButtonTheme.of(context).style;
    final text = _textWidth(context, label, _labelStyle(context));
    final minimum = style?.minimumSize?.resolve(const {})?.width ?? 0;
    return math.max(minimum, _padding.horizontal + _iconSize + _gap + text);
  }

  /// The height the labelled form's content needs in [context]: the label's
  /// natural line (its style's line height at the current text scale) or the
  /// icon, whichever is taller. Its own padding adds nothing vertically.
  double labelledHeight(BuildContext context) => math.max(
    _iconSize,
    measureTextLine(context, label, _labelStyle(context)).height,
  );

  /// The label's style: the filled button theme's, else Material's.
  TextStyle? _labelStyle(BuildContext context) =>
      FilledButtonTheme.of(context).style?.textStyle?.resolve(const {}) ??
      Theme.of(context).textTheme.labelLarge;

  /// The labelled form's vertical inset inside the bar.
  static const double _barInset = 8;

  /// The labelled form.
  Widget labelled() => Padding(
    padding: const EdgeInsets.symmetric(vertical: _barInset),
    child: FilledButton(
      key: key,
      onPressed: onPressed,
      style: FilledButton.styleFrom(padding: _padding),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: _iconSize),
          const SizedBox(width: _gap),
          Text(label, maxLines: 1, softWrap: false),
        ],
      ),
    ),
  );

  /// The icon form. Its colours are explicit: an icon button reads its
  /// foreground from the ambient [IconTheme] when that is not the default,
  /// and a title bar's icon colour can equal the filled background, which
  /// would leave a blank disc.
  Widget compact() => Builder(
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return IconButton.filled(
        key: key,
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
        icon: Icon(icon),
      );
    },
  );
}

/// The width of [text] in [style] at the current text scale.
double _textWidth(BuildContext context, String text, TextStyle? style) =>
    measureTextLine(context, text, style).width;

/// Shared title bar used by [UtilityPage].
class UtilityPageTitleBar extends ConsumerWidget
    implements PreferredSizeWidget {
  /// Creates a utility-page title bar.
  const UtilityPageTitleBar({
    super.key,
    required this.route,
    required this.title,
    this.parent,
    this.actions = const [],
    this.primaryAction,
  });

  /// The current top-level route.
  final String route;

  /// Localized current-page title.
  final String title;

  /// The list this page drilled down from, if any.
  final UtilityParent? parent;

  /// Actions that belong only to the current page.
  final List<Widget> actions;

  /// The page's main action, after [actions].
  final UtilityPrimaryAction? primaryAction;

  /// The narrowest a title keeps before it ellipsizes: about four glyphs.
  static const double _titleMinimum = 4 * 15;

  @override
  Size get preferredSize => Size.fromHeight(
    (isFramelessDesktop ? WindowChrome.barHeight : kToolbarHeight) +
        (isDesktop ? 1 : 0),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktop) {
      return WindowTitleBar(
        title: Text(title),
        actions: [
          ...actions,
          if (primaryAction != null) primaryAction!.compact(),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => _desktop(context, ref, constraints),
    );
  }

  /// The width the title row needs at its narrowest: the way back to the
  /// chat, the parent breadcrumb and separators, and a minimal title.
  double _titleRowMinimum(BuildContext context, bool compact) {
    final l10n = AppLocalizations.of(context);
    // The separator inherits the bar's title style.
    final theme = Theme.of(context);
    final separator =
        14 +
        _textWidth(
          context,
          '/',
          theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge,
        );
    final scaler = MediaQuery.textScalerOf(context);
    final title = scaler.scale(_titleMinimum);
    if (compact) {
      // The 30 px origin button, its 7 px gap and the parent's icon target.
      final up = parent == null ? 0.0 : 12 + 17 + separator;
      return 30 + 7 + up + title;
    }
    // The origin button's own padding (4 + 10) and 20 px icon, set below,
    // plus Material's icon-to-label gap (8 at most).
    final origin =
        4 +
        10 +
        20 +
        8 +
        _textWidth(
          context,
          l10n.utilityChat,
          Theme.of(context).textTheme.bodyMedium,
        );
    final up = parent == null
        ? 0.0
        : 12 +
              _textWidth(
                context,
                parent!.title,
                const TextStyle(fontSize: 15),
              ) +
              separator;
    return origin + separator + up + title;
  }

  /// [primaryAction] in the form the bar has room for: what remains of the
  /// bar's actual width after its insets, the toolbar's spacing on both
  /// sides of the title, every other action and the menu at the largest
  /// interactive size, and the title row at its narrowest. The label must
  /// also fit the bar's height: large text whose line is taller than the
  /// button would be cut off, so it gets the icon form instead.
  Widget _primary(
    BuildContext context,
    UtilityPrimaryAction action,
    double width,
    bool compact,
  ) {
    final reserved =
        WindowChrome.leadingInset +
        WindowChrome.trailingInset +
        2 * NavigationToolbar.kMiddleSpacing +
        (actions.length + 1) * kMinInteractiveDimension +
        _titleRowMinimum(context, compact);
    final height =
        (isFramelessDesktop ? WindowChrome.barHeight : kToolbarHeight) -
        2 * UtilityPrimaryAction._barInset;
    return action.labelledWidth(context) <= width - reserved &&
            action.labelledHeight(context) <= height
        ? action.labelled()
        : action.compact();
  }

  Widget _desktop(
    BuildContext context,
    WidgetRef ref,
    BoxConstraints constraints,
  ) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 620;
    final primary = primaryAction;
    Widget compactTitle() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('utility-chat-origin'),
          tooltip: l10n.utilityChat,
          onPressed: () => _openUtilityRoute(context, route, '/'),
          icon: const Icon(Icons.chevron_left_rounded, size: 20),
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            foregroundColor: scheme.onSurfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kControlRadius),
            ),
          ),
        ),
        const SizedBox(width: 7),
        // Compact drops the parent's label but keeps its tap target, so
        // a detail page still has a way up when the bar can't spell the
        // chain out.
        if (parent != null) ...[
          _BreadcrumbLink(
            label: parent!.title,
            onTap: () => _openParent(context, parent!),
            compact: true,
          ),
          _breadcrumbSeparator(scheme),
        ],
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
    Widget fullTitle() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The way back to the conversation: a quiet back-chevron text
        // button, the same weight as the breadcrumb it heads.
        TextButton.icon(
          key: const Key('utility-chat-origin'),
          onPressed: () => _openUtilityRoute(context, route, '/'),
          icon: const Icon(Icons.chevron_left_rounded, size: 20),
          label: Text(l10n.utilityChat),
          style: TextButton.styleFrom(
            foregroundColor: scheme.onSurfaceVariant,
            // From the theme, so the CJK fallback chain comes along.
            textStyle: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w400),
            padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kControlRadius),
            ),
          ),
        ),
        _breadcrumbSeparator(scheme),
        if (parent != null) ...[
          _BreadcrumbLink(
            label: parent!.title,
            onTap: () => _openParent(context, parent!),
          ),
          _breadcrumbSeparator(scheme),
        ],
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
    return WindowTitleBar(
      automaticallyImplyLeading: false,
      // A breadcrumb reads from the leading edge, so it is not centred even on
      // macOS; it starts clear of the traffic lights instead.
      centerTitle: false,
      backgroundColor: surfaceBackground(scheme),
      // The full breadcrumb only where the title slot itself holds it at its
      // narrowest: the slot is what the bar leaves after its actions, which
      // the window width alone does not tell (large text, many actions).
      title: compact
          ? compactTitle()
          : LayoutBuilder(
              builder: (context, slot) =>
                  slot.maxWidth >= _titleRowMinimum(context, false)
                  ? fullTitle()
                  : compactTitle(),
            ),
      actions: [
        ...actions,
        if (primary != null)
          _primary(context, primary, constraints.maxWidth, compact),
        PopupMenuButton<String>(
          key: const Key('utility-page-menu'),
          tooltip: l10n.utilitySwitchPage,
          position: PopupMenuPosition.under,
          icon: const Icon(Icons.more_horiz),
          onSelected: (value) {
            if (value == _themeValue) {
              final dark = Theme.of(context).brightness == Brightness.dark;
              ThemeTransition.run(
                context,
                () => ref
                    .read(uiPrefsProvider.notifier)
                    .setThemeMode(dark ? 'light' : 'dark'),
              );
              return;
            }
            _openUtilityRoute(context, route, value);
          },
          // A detail page marks its parent section as current, so the menu shows
          // where you are rather than nothing at all.
          itemBuilder: (context) => _menuItems(context, parent?.route ?? route),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, color: scheme.outlineVariant),
      ),
    );
  }
}

const _themeValue = '__theme__';

/// Climb from a detail page to the list it came from.
///
/// Pops when that list is the route directly beneath — the usual case, since the
/// detail was pushed from it — which keeps the list's scroll position and
/// selection. Only when the detail was reached some other way (a deep link, or a
/// sibling swap that left no list underneath) does it navigate instead. Note this
/// can't go through `_openUtilityRoute`: a detail page reports its parent's
/// section as its own `route` so the page menu highlights correctly, so that
/// helper would see target == current and do nothing.
void _openParent(BuildContext context, UtilityParent parent) =>
    UtilityLeaveGuard.leave(context, () {
      final router = GoRouter.of(context);
      if (router.canPop()) {
        router.pop();
        return;
      }
      context.go(parent.route);
    });

/// The `/` between breadcrumb segments — ink at 28%, well under the labels it
/// divides so the chain reads as one line rather than three words.
Widget _breadcrumbSeparator(ColorScheme scheme) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 7),
  child: Text(
    '/',
    style: TextStyle(
      color: scheme.onSurface.withValues(alpha: 0.28),
      fontWeight: FontWeight.w400,
    ),
  ),
);

/// A middle breadcrumb segment: the current page's parent, tappable to go up.
/// Quieter than the chat origin button (no border, no fill) because the origin
/// leaves the section entirely while this only climbs one level inside it.
class _BreadcrumbLink extends StatelessWidget {
  const _BreadcrumbLink({
    required this.label,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final VoidCallback onTap;

  /// Narrow bars show the icon-sized hit area without the label.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton(
      key: const Key('utility-parent-origin'),
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: compact
          ? const Icon(Icons.chevron_left, size: 17)
          : Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
            ),
    );
  }
}

List<PopupMenuEntry<String>> _menuItems(BuildContext context, String route) {
  final l10n = AppLocalizations.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final modifier = defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl';
  final pages =
      <({String route, IconData icon, String label, String shortcut})>[
        (
          route: '/',
          icon: Icons.chat_bubble_outline,
          label: l10n.utilityChat,
          shortcut: '$modifier 0',
        ),
        (
          route: '/manage',
          icon: Icons.dns_outlined,
          label: l10n.manageServices,
          shortcut: '$modifier 1',
        ),
        (
          route: '/sessions',
          icon: Icons.history,
          label: l10n.localSessionsTitle,
          shortcut: '$modifier 2',
        ),
        (
          route: '/logs',
          icon: Icons.article_outlined,
          label: l10n.logsTitle,
          shortcut: '$modifier 3',
        ),
        (
          route: '/settings',
          icon: Icons.settings_outlined,
          label: l10n.settingsTitle,
          shortcut: '$modifier ,',
        ),
      ];
  return [
    PopupMenuItem<String>(
      enabled: false,
      height: 32,
      child: Text(
        l10n.utilityPages,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
    for (final page in pages)
      PopupMenuItem<String>(
        value: page.route,
        enabled: page.route != route,
        child: _PageMenuRow(
          icon: page.icon,
          label: page.label,
          shortcut: page.shortcut,
          selected: page.route == route,
        ),
      ),
    const PopupMenuDivider(),
    PopupMenuItem<String>(
      value: _themeValue,
      child: _PageMenuRow(
        icon: dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        label: dark ? l10n.appearanceLight : l10n.appearanceDark,
      ),
    ),
  ];
}

class _PageMenuRow extends StatelessWidget {
  const _PageMenuRow({
    required this.icon,
    required this.label,
    this.shortcut,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? shortcut;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (shortcut != null)
            Text(
              shortcut!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.38),
              ),
            ),
        ],
      ),
    );
  }
}

/// Lets a page with unsaved edits decide before the shared navigation (page
/// menu, breadcrumbs, origin button and page shortcuts) leaves it. Those go
/// through the router (`go`, `pushReplacement`), which a `PopScope` does not
/// see; the page's own back gesture stays with its `PopScope`.
class UtilityLeaveGuard extends InheritedWidget {
  /// Creates a guard; [confirm] answers whether leaving may proceed.
  const UtilityLeaveGuard({
    super.key,
    required this.confirm,
    required super.child,
  });

  /// Asked before navigating away; `true` lets the navigation proceed.
  final Future<bool> Function() confirm;

  /// Run [navigate] once the page around [context] may be left: at once
  /// without a guard, else after its [confirm] agreed while still mounted.
  static void leave(BuildContext context, VoidCallback navigate) {
    final guard = context.getInheritedWidgetOfExactType<UtilityLeaveGuard>();
    if (guard == null) {
      navigate();
      return;
    }
    unawaited(
      guard.confirm().then((ok) {
        if (ok && context.mounted) navigate();
      }),
    );
  }

  @override
  bool updateShouldNotify(UtilityLeaveGuard oldWidget) =>
      confirm != oldWidget.confirm;
}

void _openUtilityRoute(
  BuildContext context,
  String currentRoute,
  String targetRoute,
) {
  if (targetRoute == currentRoute) return;
  UtilityLeaveGuard.leave(
    context,
    () => _navigateUtility(context, currentRoute, targetRoute),
  );
}

void _navigateUtility(
  BuildContext context,
  String currentRoute,
  String targetRoute,
) {
  if (targetRoute == '/') {
    // The root route keeps a stable page key when it already sits below this
    // page, so `go` removes every utility/detail route above it without
    // rebuilding the conversation. It also behaves correctly for a direct
    // utility deep link whose stack has no conversation yet.
    context.go('/');
    return;
  }
  // Open above Home, then swap sibling utility pages without replacing the
  // live conversation route underneath.
  if (currentRoute == '/') {
    context.push(targetRoute);
  } else {
    context.pushReplacement(targetRoute);
  }
}

Map<ShortcutActivator, VoidCallback> _pageShortcuts(
  BuildContext context,
  String currentRoute,
) {
  void open(String targetRoute) {
    final current = ModalRoute.of(context);
    if (current != null && !current.isCurrent) return;
    _openUtilityRoute(context, currentRoute, targetRoute);
  }

  final meta = defaultTargetPlatform == TargetPlatform.macOS;
  ShortcutActivator shortcut(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: meta, control: !meta);
  return {
    shortcut(LogicalKeyboardKey.digit0): () => open('/'),
    shortcut(LogicalKeyboardKey.digit1): () => open('/manage'),
    shortcut(LogicalKeyboardKey.digit2): () => open('/sessions'),
    shortcut(LogicalKeyboardKey.digit3): () => open('/logs'),
    shortcut(LogicalKeyboardKey.comma): () => open('/settings'),
  };
}
