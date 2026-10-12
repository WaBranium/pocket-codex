import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';

/// The agent a new host runs, as picked in [AgentChoiceGrid].
///
/// `codex` (native app-server), `preset:<id>` (a built-in ACP preset),
/// `saved:<profileId>` (one of "my agents") or `custom` (a new ACP agent).
typedef AgentChoice = String;

/// The native Codex choice.
const AgentChoice codexChoice = 'codex';

/// A new custom ACP agent.
const AgentChoice customAgentChoice = 'custom';

/// Whether [choice] hosts an ACP agent.
bool isAcpChoice(AgentChoice choice) => choice != codexChoice;

/// Clickable tiles, one per agent this device can host: Codex, the ACP
/// presets, saved custom agents and "custom". Each tile leads with the
/// agent's own mark; presets and saved agents are identified by their
/// profile id, never by a host name.
///
/// A [Wrap] of fixed-width tiles, so it flows to two columns on a 320 px
/// phone and stays a compact row on desktop.
class AgentChoiceGrid extends StatelessWidget {
  /// Creates the grid with [value] selected.
  const AgentChoiceGrid({
    super.key,
    required this.value,
    required this.presets,
    required this.saved,
    required this.onChanged,
  });

  /// The selected choice.
  final AgentChoice value;

  /// Built-in ACP presets.
  final List<AcpPreset> presets;

  /// Saved custom ACP agents.
  final List<AcpAgentSpec> saved;

  /// Called with a new choice; null disables every tile.
  final ValueChanged<AgentChoice>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tiles = <Widget>[
      _AgentTile(
        choice: codexChoice,
        selected: value == codexChoice,
        title: l10n.providerCodex,
        subtitle: l10n.agentChoiceNative,
        icon: const AgentIcon(kind: AgentKind.codex, size: 22),
        onTap: onChanged,
      ),
      for (final preset in presets)
        _AgentTile(
          choice: 'preset:${preset.id}',
          selected: value == 'preset:${preset.id}',
          title: preset.displayName,
          subtitle: l10n.protocolAcpTag,
          icon: AgentIcon.of(
            provider: 'acp',
            profileId: preset.id,
            name: preset.displayName,
            size: 22,
          ),
          onTap: onChanged,
        ),
      for (final agent in saved)
        _AgentTile(
          choice: 'saved:${agent.profileId}',
          selected: value == 'saved:${agent.profileId}',
          title: agent.displayName,
          subtitle: l10n.agentChoiceSaved,
          icon: AgentIcon.of(
            provider: 'acp',
            profileId: agent.profileId,
            name: agent.displayName,
            size: 22,
          ),
          onTap: onChanged,
        ),
      _AgentTile(
        choice: customAgentChoice,
        selected: value == customAgentChoice,
        title: l10n.acpAgentCustom,
        subtitle: l10n.protocolAcpTag,
        icon: Icon(
          Icons.add_rounded,
          size: 22,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onTap: onChanged,
      ),
    ];
    return Semantics(
      container: true,
      label: l10n.providerLabel,
      child: Wrap(
        key: const Key('agent-choice-grid'),
        spacing: 8,
        runSpacing: 8,
        children: tiles,
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.choice,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final AgentChoice choice;
  final bool selected;
  final String title;
  final String subtitle;
  final Widget icon;
  final ValueChanged<AgentChoice>? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final border = selected ? scheme.primary : scheme.outlineVariant;
    return Tooltip(
      message: title,
      waitDuration: const Duration(milliseconds: 600),
      // The node below already carries the title.
      excludeFromSemantics: true,
      // One node with the full label, the selection state and the action;
      // the InkWell beneath keeps keyboard focus and Enter/Space.
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        enabled: enabled,
        label: '$title, $subtitle',
        onTap: enabled ? () => onTap!(choice) : null,
        excludeSemantics: true,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Material(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.35)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(kControlRadius),
            child: InkWell(
              key: Key('agent-choice-$choice'),
              mouseCursor: enabled ? clickable : SystemMouseCursors.basic,
              borderRadius: BorderRadius.circular(kControlRadius),
              onTap: enabled ? () => onTap!(choice) : null,
              child: Container(
                width: 112,
                constraints: const BoxConstraints(minHeight: 72),
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(kControlRadius),
                  border: Border.all(color: border, width: selected ? 1.5 : 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        icon,
                        const Spacer(),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: scheme.primary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [base] when no running host on this device uses it, else the first free
/// `base-2`, `base-3`, …. Names are shared by every provider on a device.
String uniqueHostName(String base, Iterable<String> taken) {
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var n = 2; ; n++) {
    final candidate = '$base-$n';
    if (!used.contains(candidate)) return candidate;
  }
}
