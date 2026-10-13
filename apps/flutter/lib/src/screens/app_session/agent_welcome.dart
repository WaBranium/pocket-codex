/// The opening view of a new ACP conversation: which agent, which project,
/// and whether its session is ready — one calm card instead of a setup step.
///
/// Everything it states comes from the screen: the agent's identity from the
/// host's explicit profile id, readiness from the draft-owned session
/// opening, the model label only when the agent reported one. Projects come
/// from the host's own session list, so they stay offered whatever folder is
/// chosen now.
library;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/screens/app_session/agent_session_options.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';

/// The welcome card of an ACP conversation that has not sent anything yet.
class AgentWelcome extends StatelessWidget {
  /// Creates the card.
  const AgentWelcome({
    super.key,
    required this.agentKind,
    required this.agentName,
    required this.project,
    required this.phase,
    this.cwd,
    this.failure,
    this.modelLabel,
    this.recent = const [],
    this.onPickRecent,
    this.onChooseFolder,
    this.onRetry,
    this.onHostSettings,
    this.connecting = false,
    this.opensOnFirstMessage = false,
  });

  /// Which mark to show.
  final AgentKind agentKind;

  /// The agent's display name.
  final String agentName;

  /// The project switcher (the headline control).
  final Widget project;

  /// The full project path, shown under the switcher.
  final String? cwd;

  /// Where the session stands.
  final AgentSessionPhase phase;

  /// The safe reason opening failed, with [AgentSessionPhase.failed].
  final String? failure;

  /// The model the agent reported for the open session, if any.
  final String? modelLabel;

  /// Other projects on this host, most recent first.
  final List<String> recent;

  /// Start the conversation in one of [recent].
  final ValueChanged<String>? onPickRecent;

  /// Open the folder chooser.
  final VoidCallback? onChooseFolder;

  /// Open the session again after a failure.
  final VoidCallback? onRetry;

  /// Open this host's settings (only where this device hosts the agent).
  final VoidCallback? onHostSettings;

  /// The view waits for its host connection.
  final bool connecting;

  /// The agent reports no per-session options: its session simply opens
  /// with the first message.
  final bool opensOnFirstMessage;

  static String _leaf(String path) {
    final segs = path.split(RegExp(r'[\\/]'))..removeWhere((s) => s.isEmpty);
    return segs.isEmpty ? path : segs.last;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final path = cwd?.trim() ?? '';
    final shown = [
      for (final p in recent)
        if (p.trim() != path) p,
    ].take(4).toList();
    return Center(
      child: SingleChildScrollView(
        key: const Key('agent-welcome'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The agent's own mark on a soft tile: who this conversation
              // is with, before anything else.
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: accentWash(scheme),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                alignment: Alignment.center,
                child: AgentIcon(kind: agentKind, name: agentName, size: 28),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.agentWelcomeTitle(agentName),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              project,
              if (path.isNotEmpty)
                Text(
                  path,
                  key: const Key('new-session-cwd'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: monoFontFamily,
                    fontFamilyFallback: monoCjkFallback,
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 16),
              _readiness(context, l10n, scheme),
              if (shown.isNotEmpty) ...[
                const SizedBox(height: 22),
                _recent(context, l10n, scheme, shown),
              ],
              if (phase != AgentSessionPhase.needsProject &&
                  onChooseFolder != null) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  key: const Key('agent-welcome-choose-folder'),
                  onPressed: onChooseFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 17),
                  label: Text(l10n.chooseFolder),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// One line that says where the session stands, and what to do about it.
  Widget _readiness(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    final muted = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final Widget body = switch (phase) {
      AgentSessionPhase.opening => _opening(context, l10n, muted),
      AgentSessionPhase.ready => _line(
        Icon(Icons.check_circle_outline, size: 16, color: successColor(scheme)),
        modelLabel == null || modelLabel!.isEmpty
            ? l10n.agentWelcomeReady
            : l10n.agentWelcomeReadyModel(modelLabel!),
        muted,
      ),
      AgentSessionPhase.failed => _failed(l10n, scheme),
      AgentSessionPhase.needsProject => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.agentWelcomeNeedsProject(agentName),
            textAlign: TextAlign.center,
            style: muted,
          ),
          const SizedBox(height: 10),
          if (onChooseFolder != null)
            FilledButton.tonalIcon(
              key: const Key('agent-welcome-choose-folder'),
              onPressed: onChooseFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(l10n.chooseFolder),
            ),
        ],
      ),
      AgentSessionPhase.idle =>
        connecting
            ? _line(null, l10n.agentWelcomeConnecting, muted)
            : opensOnFirstMessage
            ? _line(null, l10n.agentWelcomeLater, muted)
            : const SizedBox.shrink(),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: AnimatedSwitcher(
        duration: Motion.of(context, Motion.medium),
        switchInCurve: Motion.enter,
        child: KeyedSubtree(
          key: ValueKey('agent-welcome-phase-${phase.name}'),
          child: body,
        ),
      ),
    );
  }

  Widget _line(Widget? icon, String text, TextStyle style) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) ...[icon, const SizedBox(width: 6)],
      Flexible(
        child: Text(text, textAlign: TextAlign.center, style: style),
      ),
    ],
  );

  /// Opening: the text says what happens; a thin indeterminate bar shows it
  /// is happening (no bar under reduced motion — it would not move).
  Widget _opening(BuildContext context, AppLocalizations l10n, TextStyle s) {
    final ambient = Motion.ambientAllowed(context);
    return Column(
      key: const Key('agent-welcome-opening'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _line(
          ambient
              ? null
              : Icon(Icons.hourglass_empty, size: 15, color: s.color),
          l10n.agentWelcomeOpening(agentName),
          s,
        ),
        if (ambient) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
        ],
      ],
    );
  }

  /// A failed opening: the safe reason, then the ways forward. Never a
  /// sign-in flow — the agent uses its host's environment.
  Widget _failed(AppLocalizations l10n, ColorScheme scheme) => Container(
    key: const Key('agent-welcome-failed'),
    padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
    decoration: BoxDecoration(
      color: scheme.errorContainer.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(kPanelRadius),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.agentWelcomeFailed(failure ?? ''),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.agentErrorHint,
          style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          children: [
            if (onHostSettings != null)
              TextButton(
                key: const Key('agent-welcome-host-settings'),
                onPressed: onHostSettings,
                child: Text(l10n.agentHostSettings),
              ),
            if (onRetry != null)
              TextButton(
                key: const Key('agent-welcome-retry'),
                onPressed: onRetry,
                child: Text(l10n.retry),
              ),
          ],
        ),
      ],
    ),
  );

  /// Other projects as one-tap rows: picking one starts the new
  /// conversation there.
  Widget _recent(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
    List<String> projects,
  ) {
    final touch = !isDesktop;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          child: Text(
            l10n.recentProjects,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final p in projects)
          Tooltip(
            message: p,
            child: InkWell(
              key: Key('agent-welcome-recent-$p'),
              mouseCursor: clickable,
              borderRadius: BorderRadius.circular(kControlRadius),
              onTap: onPickRecent == null ? null : () => onPickRecent!(p),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: touch ? 44 : 34),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: _recentRow(scheme, p),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _recentRow(ColorScheme scheme, String path) => Row(
    children: [
      Icon(Icons.folder_outlined, size: 16, color: scheme.onSurfaceVariant),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          _leaf(path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: scheme.onSurface),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: TextStyle(
            fontFamily: monoFontFamily,
            fontFamilyFallback: monoCjkFallback,
            fontSize: 11,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );
}
