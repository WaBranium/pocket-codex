import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/hosting/host_picker.dart';
import 'package:pocket_codex/src/hosting/official_login_panel.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/code_row.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/icon_badge.dart';
import 'package:pocket_codex/src/widgets/links.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

/// Which access method a row represents. Both write to the same `CODEX_HOME`,
/// and codex honours whichever was configured last — so exactly one is ever
/// "in use", which is what makes them rows of one list rather than two
/// side-by-side sections.
enum _Method {
  /// ChatGPT OAuth, driven on the local app-server; codex writes `auth.json`.
  chatgpt,

  /// A custom provider. Set per host in the hosting editor; this page only
  /// reports one that codex's own `config.toml` already selects.
  provider,
}

/// First-run configuration for external Codex.
///
/// Scope: this page sets up Codex itself (its `CODEX_HOME`), which hosts on
/// "Existing configuration" use. A host's own custom provider or official
/// account is chosen in the hosting editor ([configureHosting]); this page
/// writes no provider.
///
/// With neither a credential (`auth.json`) nor a selected custom provider,
/// codex cannot call a model. The page shows two rows in one card:
///
/// 1. ChatGPT sign-in, driven by `account/login/start` on a local app-server;
///    codex writes `auth.json` itself.
/// 2. A custom provider: reported when codex's own `config.toml` selects one,
///    otherwise a pointer to the hosting editor.
///
/// Whichever is live sorts first and carries an "in use" pill; the other
/// collapses to a title and a way to switch. The Advanced card holds the
/// system prompt switch (openai/codex#30364): how codex prompts the model,
/// not how it gets access.
class CodexSetupScreen extends ConsumerStatefulWidget {
  /// Default constructor.
  const CodexSetupScreen({super.key});

  @override
  ConsumerState<CodexSetupScreen> createState() => _CodexSetupScreenState();
}

class _CodexSetupScreenState extends ConsumerState<CodexSetupScreen> {
  CodexSetupStatus? _status;
  bool _busy = false;
  String? _error;
  String? _info;

  /// The method the user opened for editing, or null for "just show me where I
  /// stand". The live one is expanded on arrival so its state and controls are
  /// visible without a click; picking the other one swaps the expansion.
  _Method? _expanded;

  /// Whether the user has chosen an expansion themselves. Until they do, the
  /// expansion follows [_liveMethod], so a login completing mid-visit moves the
  /// disclosure with it instead of leaving a stale panel open.
  bool _expandedByUser = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  /// The method codex is actually set up with, or null when neither is.
  _Method? get _liveMethod {
    final status = _status;
    if (status == null) return null;
    // The bridge reports what codex will actually use: a selected custom
    // provider wins over a stored credential. An older bridge leaves it
    // empty, and the credential is taken first as before.
    switch (status.effectiveSource) {
      case 'custom':
        return _Method.provider;
      case 'account':
        return _Method.chatgpt;
      case 'none' || 'invalid':
        return null;
    }
    if (status.hasAuth) return _Method.chatgpt;
    if (status.hasCustomProvider) return _Method.provider;
    return null;
  }

  /// Which method's panel is open. Defaults to the live one; with neither
  /// configured, the provider row leads, pointing to the hosting editor.
  _Method get _openMethod => _expanded ?? _liveMethod ?? _Method.provider;

  /// The rows, live-first. With neither configured the provider row comes first,
  /// as it is the default expansion.
  List<_Method> get _orderedMethods {
    final live = _liveMethod;
    return switch (live) {
      _Method.chatgpt => const [_Method.chatgpt, _Method.provider],
      _Method.provider => const [_Method.provider, _Method.chatgpt],
      null => const [_Method.provider, _Method.chatgpt],
    };
  }

  BridgeApi get _api => ref.read(bridgeApiProvider);

  Future<void> _loadStatus() async {
    try {
      final s = await _api.codexSetupStatus();
      if (mounted) {
        setState(() {
          _status = s;
          // Follow the live method until the user takes over the disclosure, so
          // a login that completes while this page is open moves the open panel
          // with it rather than leaving the old panel expanded.
          if (!_expandedByUser) _expanded = null;
        });
        // Keep the chat's "codex needs setup" banner/send-guard in sync with
        // what changed here or in the hosting editor (signed in, …).
        ref.invalidate(codexSetupStatusProvider);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _run(Future<void> Function() op, {String? okMessage}) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await op();
      await _loadStatus();
      if (mounted && okMessage != null) setState(() => _info = okMessage);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Open the hosting editor for a host the user picks, then re-read what
  /// codex's own setup says (the editor may have signed it in).
  Future<void> _configureHost() async {
    await configureHosting(context, ref);
    if (mounted) await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = _status;
    final nonDegraded = status?.promptVariant == 'non_degraded';
    return UtilityPage(
      route: '/settings',
      title: l10n.codexSetup,
      parent: UtilityParent(title: l10n.settingsTitle, route: '/settings'),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            // Matches the settings page this is pushed from, so the two read as
            // one column rather than two different page widths.
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              children: [
                if (status != null) _statusCard(l10n, theme, status),
                const SizedBox(height: 10),
                GroupCard(
                  title: l10n.codexSetupMethodsTitle,
                  hint: l10n.codexSetupMethodsHint,
                  children: [
                    for (final method in _orderedMethods)
                      _methodRow(l10n, theme, method),
                  ],
                ),
                const SizedBox(height: 10),
                GroupCard(
                  title: l10n.codexSetupAdvanced,
                  children: [_nonDegradedRow(l10n, theme, nonDegraded)],
                ),
                if (_info != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _Notice(
                      noticeKey: const Key('codex-setup-info'),
                      icon: Icons.check_circle_outline,
                      message: _info!,
                      color: successColor(scheme),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _Notice(
                      noticeKey: const Key('codex-setup-error'),
                      icon: Icons.error_outline,
                      message: _error!,
                      color: scheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One access method as a row of the methods card: always its title, status
  /// and the way in; its controls only when it is the open one.
  Widget _methodRow(AppLocalizations l10n, ThemeData theme, _Method method) {
    final scheme = theme.colorScheme;
    final live = _liveMethod == method;
    final open = _openMethod == method;
    final chatgpt = method == _Method.chatgpt;
    return _MethodRow(
      rowKey: Key('codex-method-${chatgpt ? 'chatgpt' : 'provider'}'),
      icon: chatgpt ? Icons.chat_bubble_outline : Icons.bolt_outlined,
      title: chatgpt
          ? l10n.codexSetupLoginSection
          : l10n.codexSetupProviderSection,
      subtitle: chatgpt
          ? l10n.codexSetupLoginDesc
          : l10n.codexSetupProviderPerHost,
      status: live
          ? StatusChip(
              color: successColor(scheme),
              label: l10n.codexSetupInUse,
              filled: true,
            )
          : null,
      open: open,
      // Only the closed row offers a way in. Collapsing the open one too would
      // allow a card with two shut rows and no controls at all — a state with
      // nothing to do in it, reachable by clicking the only visible button.
      actionLabel: open ? null : l10n.codexSetupSwitchTo,
      onToggle: open
          ? null
          : () => setState(() {
              _expandedByUser = true;
              _expanded = method;
            }),
      detail: open
          ? (chatgpt ? _chatgptDetail(l10n, theme) : _providerDetail(l10n))
          : null,
    );
  }

  /// Where a custom provider is set now: per host, in the hosting editor.
  /// A provider codex's own configuration already selects is reported, not
  /// edited here; hosts on "Existing configuration" keep using it.
  Widget _providerDetail(AppLocalizations l10n) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_status?.hasCustomProvider ?? false) ...[
        _InlineHint(
          key: const Key('codex-global-provider'),
          text: l10n.codexSetupGlobalProvider,
        ),
        const SizedBox(height: 8),
      ],
      _InlineHint(text: l10n.codexSetupProviderScope),
      const SizedBox(height: 12),
      if (isDesktop)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('codex-provider-hosts'),
            onPressed: _busy ? null : _configureHost,
            child: Text(l10n.codexSetupConfigureHost),
          ),
        )
      else
        _InlineHint(
          key: const Key('codex-provider-desktop-only'),
          text: l10n.codexSetupHostingDesktopOnly,
        ),
    ],
  );

  /// The ChatGPT login body. Sign-in runs on a private local app-server, so it
  /// no longer needs a hosted instance to be running first.
  Widget _chatgptDetail(AppLocalizations l10n, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OfficialLoginPanel(
          status: _status,
          enabled: !_busy,
          onChanged: _loadStatus,
        ),
        const SizedBox(height: 10),
        _InlineHint(text: l10n.codexSetupProxyNote),
      ],
    );
  }

  /// The prompt-variant switch, as an Advanced row. Its "what" and its "when"
  /// used to run together in one paragraph; the scope and the upstream issue are
  /// their own line now, the issue as a link rather than bare text.
  Widget _nonDegradedRow(
    AppLocalizations l10n,
    ThemeData theme,
    bool nonDegraded,
  ) {
    final scheme = theme.colorScheme;
    final status = _status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 11, 11, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            // Nudged down so the badge aligns with the title's cap height rather
            // than the block of wrapped text beneath it.
            padding: EdgeInsets.only(top: 2),
            child: IconBadge(icon: Icons.psychology_outlined),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.codexSetupNonDegradedTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  l10n.codexSetupNonDegradedDesc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 5),
                // Scope and provenance on one quiet line: when it takes effect,
                // then the upstream issue as a real link.
                Row(
                  children: [
                    Text(
                      l10n.codexSetupNonDegradedScope,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurfaceMuted(scheme),
                      ),
                    ),
                    Text(
                      '  ·  ',
                      style: TextStyle(color: onSurfaceMuted(scheme)),
                    ),
                    Flexible(
                      child: linkifyText(
                        context,
                        'https://github.com/${l10n.codexSetupNonDegradedIssue.replaceFirst('#', '/issues/')}',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            key: const Key('codex-nondegraded-toggle'),
            value: nonDegraded,
            onChanged: (status == null || _busy)
                ? null
                : (on) => _run(
                    () => _api.codexSetPromptVariant(
                      on ? 'non_degraded' : 'default',
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Where the user stands, in one card: whether codex can call a model at all,
  /// which method got it there, and where its config lives.
  ///
  /// The path used to lead with the raw `CODEX_HOME:` env-var name under a
  /// status line. It is now labelled in words and demoted to the footer — it is
  /// reference material, not the answer to "is this working".
  Widget _statusCard(
    AppLocalizations l10n,
    ThemeData theme,
    CodexSetupStatus s,
  ) {
    final scheme = theme.colorScheme;
    final ready = !s.needsSetup;
    final color = ready ? successColor(scheme) : scheme.error;
    final label = ready
        ? (s.hasAuth
              ? l10n.codexSetupStatusAuth(
                  s.authMode ?? l10n.codexSetupCredentialExists,
                )
              : l10n.codexSetupStatusProvider)
        : l10n.codexSetupStatusNeedSetup;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(kControlRadius),
                  ),
                  child: Icon(
                    ready ? Icons.check_circle_outline : Icons.error_outline,
                    size: 20,
                    color: color,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        key: const Key('codex-setup-state'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ready
                            ? l10n.codexSetupStatusReadyHint
                            : l10n.codexSetupStatusNeedSetupHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 12, 7),
            // Unfilled: the card is already the ground, so a tinted row inside
            // it would read as a box in a box.
            child: CodeRow(
              value: s.codexHome,
              label: l10n.codexSetupCodexHomeLabel,
              filled: false,
              copyKey: const Key('codex-home-copy'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One access-method row: identity and status always, controls when [open].
///
/// The closed form is deliberately a header only, so the open row is the one
/// whose controls are shown.
class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.rowKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.open,
    this.status,
    this.actionLabel,
    this.onToggle,
    this.detail,
  });

  /// Identifies this row (not the widget's own `key`, so the animated container
  /// below can keep its identity across an expansion change).
  final Key rowKey;
  final IconData icon;
  final String title;
  final String subtitle;

  /// Whether this row's controls are shown.
  final bool open;

  /// The "in use" pill, on the method codex actually runs on.
  final Widget? status;

  /// Label for the way in. Null on the open row, which has nowhere to go.
  final String? actionLabel;
  final VoidCallback? onToggle;

  /// This method's controls, built only when [open].
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final header = Row(
      children: [
        // Accented while open: the method being configured is the subject of the
        // card, the collapsed one is a label on a row.
        IconBadge(icon: icon, accent: open),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (status != null) ...[const SizedBox(width: 8), status!],
        if (actionLabel != null) ...[
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onToggle, child: Text(actionLabel!)),
        ],
      ],
    );
    final content = Padding(
      key: rowKey,
      padding: const EdgeInsets.fromLTRB(13, 11, 11, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (detail != null) ...[
            const SizedBox(height: 14),
            // Indented to the text column so the controls read as belonging to
            // the title above them rather than to the card.
            Padding(padding: const EdgeInsets.only(left: 43), child: detail!),
          ],
        ],
      ),
    );
    // A closed row is a target; an open one is where you already are.
    if (open || onToggle == null) return content;
    return InkWell(mouseCursor: clickable, onTap: onToggle, child: content);
  }
}

/// A quiet caveat under the control it constrains.
class _InlineHint extends StatelessWidget {
  const _InlineHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.5),
          child: Icon(
            Icons.info_outline,
            size: 14,
            color: onSurfaceMuted(scheme),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: onSurfaceMuted(scheme),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// The page's outcome line — a tinted panel rather than bare coloured text, so a
/// result under a card stack reads as a result.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.noticeKey,
    required this.icon,
    required this.message,
    required this.color,
  });

  final Key noticeKey;
  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    key: noticeKey,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(kPanelRadius),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 9),
        // Linkified: a provider URL or an upstream error often carries one, and
        // it was previously plain text the user had to retype.
        Expanded(
          child: linkifyText(
            context,
            message,
            style: TextStyle(color: color, height: 1.4),
          ),
        ),
      ],
    ),
  );
}
