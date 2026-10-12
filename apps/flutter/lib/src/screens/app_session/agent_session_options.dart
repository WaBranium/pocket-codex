/// An ACP agent's own per-session controls in the composer toolbar: one chip
/// per select configuration option it reported (model, effort, mode, …), the
/// legacy mode when it reports no mode option, and — before the first send —
/// the project folder plus an explicit "prepare session" action that opens
/// the agent's session early, so its model and effort can be chosen before
/// anything is sent. An agent that reports nothing gets no chips: there is no
/// invented model catalog behind them.
///
/// Options follow ACP's session config options: categories are UX hints that
/// order the chips (model, then thought level, then mode, then the rest);
/// ids and values are opaque and sent back verbatim. After every change the
/// agent returns its complete option set, which replaces this one — a model
/// change may add, drop or reset the effort option.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session/option_picker.dart';

/// [options] in display order: model, thought level, mode, then the others,
/// each group in agent order.
List<SessionConfigOption> orderedOptions(List<SessionConfigOption> options) {
  int rank(SessionConfigOption option) => switch (option.category) {
    'model' => 0,
    'thought_level' => 1,
    'mode' => 2,
    _ => 3,
  };
  final indexed = options.indexed.toList()
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final (_, option) in indexed) option];
}

/// Whether the legacy `modes` should show: ACP clients that use config
/// options ignore them once a `mode` option exists.
bool showsLegacyModes(SessionSettings settings) =>
    settings.modes.isNotEmpty &&
    !settings.configOptions.any((o) => o.category == 'mode');

/// The chips; selecting a value calls back with the opaque ids verbatim.
class AgentSessionOptions extends StatelessWidget {
  /// Creates the chips from [settings].
  const AgentSessionOptions({
    super.key,
    required this.settings,
    required this.enabled,
    required this.onSelectConfig,
    required this.onSelectMode,
    this.projectLabel,
    this.onPickProject,
    this.onPrepare,
    this.preparing = false,
  });

  /// The agent's current session state, or null before a session exists.
  final SessionSettings? settings;

  /// Whether the chips can be used right now.
  final bool enabled;

  /// Sets select option `configId` to `value`.
  final Future<void> Function(String configId, String value) onSelectConfig;

  /// Switches the legacy mode.
  final Future<void> Function(String modeId) onSelectMode;

  /// The project chip label, before the first send.
  final String? projectLabel;

  /// Opens the project picker.
  final Future<void> Function()? onPickProject;

  /// Opens the agent's session for the chosen project without sending, so
  /// its options can be set first; null when not applicable.
  final Future<void> Function()? onPrepare;

  /// A prepare is in flight.
  final bool preparing;

  // The chips scroll horizontally inside the space the composer leaves;
  // each one is bounded by that space too, so a revealed chip is always
  // entirely visible and a long label ellipsizes inside it instead.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(context, constraints.maxWidth),
  );

  Widget _build(BuildContext context, double room) {
    final l10n = AppLocalizations.of(context);
    final settings = this.settings;
    // Never below a chip's icon, chevron and padding (10 + 15 + 4 + 15 + 10).
    double fit(double width) =>
        room.isFinite ? math.min(width, math.max(room, 54)) : width;
    Widget bounded(Widget chip) => room.isFinite
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room),
            child: chip,
          )
        : chip;
    final chips = <Widget>[
      if (projectLabel != null && onPickProject != null)
        bounded(
          ActionChip(
            key: const Key('agent-project-chip'),
            avatar: const Icon(Icons.folder_outlined, size: 16),
            label: Text(projectLabel!, overflow: TextOverflow.ellipsis),
            onPressed: preparing ? null : () => onPickProject!(),
          ),
        ),
      if (settings == null && onPrepare != null)
        bounded(
          Tooltip(
            message: l10n.agentPrepareHint,
            child: ActionChip(
              key: const Key('agent-prepare-session'),
              avatar: preparing
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Icon(Icons.tune, size: 16),
              label: Text(
                l10n.agentPrepareSession,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: preparing || !enabled ? null : () => onPrepare!(),
            ),
          ),
        ),
      if (settings != null)
        for (final option in orderedOptions(settings.configOptions))
          _OptionChip(
            key: Key('agent-config-${option.id}'),
            title: option.name,
            description: option.description,
            label: option.currentLabel,
            fullLabel:
                option.values
                    .where((v) => v.value == option.currentValue)
                    .map(optionValueLabel)
                    .firstOrNull ??
                option.currentValue,
            icon: switch (option.category) {
              'model' => Icons.auto_awesome,
              'thought_level' => Icons.psychology_outlined,
              _ => Icons.tune,
            },
            maxWidth: fit(option.category == 'model' ? 220 : 160),
            enabled: enabled,
            entries: [
              for (final value in option.values)
                (
                  id: value.value,
                  label: optionValueLabel(value),
                  selected: value.value == option.currentValue,
                ),
            ],
            onSearch: option.values.length > kOptionMenuLimit
                ? (context) => showOptionPicker(context, option)
                : null,
            onSelected: (value) => onSelectConfig(option.id, value),
          ),
      if (settings != null && showsLegacyModes(settings))
        _OptionChip(
          key: const Key('agent-mode'),
          title: l10n.agentMode,
          label:
              settings.modes
                  .where((m) => m.id == settings.currentMode)
                  .firstOrNull
                  ?.name ??
              l10n.agentMode,
          icon: Icons.swap_horiz,
          maxWidth: fit(160),
          enabled: enabled,
          entries: [
            for (final mode in settings.modes)
              (
                id: mode.id,
                label: mode.name,
                selected: mode.id == settings.currentMode,
              ),
          ],
          onSelected: onSelectMode,
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: l10n.agentOptions,
      child: SingleChildScrollView(
        key: const Key('agent-session-options'),
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              chips[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One option's trigger. Short lists open a menu; long ones the searchable
/// list ([onSearch]). While a change is in flight the chip shows progress
/// and ignores taps; the agent's answer (or the failure the screen reports)
/// settles it.
///
/// The selection callback and the offered values are captured when the menu
/// or list OPENS, not when it closes: a menu left open across a conversation,
/// host or catalog change answers to the target it was opened for (which the
/// screen then refuses as stale) and never to whatever the chip shows now.
class _OptionChip extends StatefulWidget {
  const _OptionChip({
    super.key,
    required this.title,
    required this.label,
    required this.icon,
    required this.maxWidth,
    required this.enabled,
    required this.entries,
    required this.onSelected,
    this.description,
    this.fullLabel,
    this.onSearch,
  });

  final String title;
  final String? description;
  final String label;
  final String? fullLabel;
  final IconData icon;
  final double maxWidth;
  final bool enabled;
  final List<({String id, String label, bool selected})> entries;
  final Future<String?> Function(BuildContext context)? onSearch;
  final Future<void> Function(String id) onSelected;

  @override
  State<_OptionChip> createState() => _OptionChipState();
}

class _OptionChipState extends State<_OptionChip> {
  bool _pending = false;
  bool _open = false;

  bool get _usable =>
      widget.enabled && !_pending && !_open && widget.entries.isNotEmpty;

  Future<void> _activate() async {
    if (!_usable) return;
    // Bound now: see the class doc.
    final select = widget.onSelected;
    final entries = widget.entries;
    final search = widget.onSearch;
    setState(() => _open = true);
    String? id;
    try {
      id = search != null ? await search(context) : await _showMenu(entries);
    } finally {
      if (mounted) setState(() => _open = false);
    }
    if (id == null || !mounted) return;
    final offered = entries.where((e) => e.id == id).firstOrNull;
    if (offered == null || offered.selected) return;
    setState(() => _pending = true);
    try {
      await select(id);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<String?> _showMenu(
    List<({String id, String label, bool selected})> entries,
  ) {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    return showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final entry in entries)
          CheckedPopupMenuItem<String>(
            value: entry.id,
            checked: entry.selected,
            child: Text(entry.label, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usable = _usable;
    final full = widget.fullLabel ?? widget.label;
    // Name and full value, so a truncated label is still readable (hover)
    // and announced completely.
    final tooltip = widget.description == null
        ? '${widget.title}: $full'
        : '${widget.title}: $full\n${widget.description}';
    final face = ConstrainedBox(
      constraints: BoxConstraints(minHeight: 40, maxWidth: widget.maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pending)
              const SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              Icon(widget.icon, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: TailEllipsisText(
                widget.label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: usable || _pending
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              widget.onSearch == null ? Icons.expand_more : Icons.search,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
    // One node: the full label, the button role and the action that opens
    // the menu or list. The InkWell beneath keeps focus and Enter/Space.
    return Semantics(
      container: true,
      button: true,
      enabled: usable,
      label: '${widget.title}: $full',
      onTap: usable ? _activate : null,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: usable ? _activate : null,
          child: face,
        ),
      ),
    );
  }
}

/// One line of [text] that, when too long, drops its START ("…tail"). Agent
/// labels tend to lead with what all values share (a provider) and end with
/// what tells them apart (the model), so the tail is the part worth keeping.
/// The text itself is not parsed or altered otherwise.
class TailEllipsisText extends StatelessWidget {
  /// Creates the text.
  const TailEllipsisText(this.text, {super.key, this.style});

  /// The full text.
  final String text;

  /// Its style.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        bool fits(String candidate) {
          final painter = TextPainter(
            text: TextSpan(text: candidate, style: style),
            maxLines: 1,
            textDirection: direction,
            textScaler: scaler,
          )..layout();
          final ok = painter.width <= constraints.maxWidth;
          painter.dispose();
          return ok;
        }

        var shown = text;
        if (constraints.maxWidth.isFinite && !fits(text)) {
          final chars = text.characters.toList();
          // Longest tail that fits after the ellipsis.
          var lo = 0, hi = chars.length;
          while (lo < hi) {
            final mid = (lo + hi + 1) ~/ 2;
            if (fits('…${chars.sublist(chars.length - mid).join()}')) {
              lo = mid;
            } else {
              hi = mid - 1;
            }
          }
          shown = '…${chars.sublist(chars.length - lo).join()}';
        }
        return Text(
          shown,
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: style,
        );
      },
    );
  }
}
