import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/project_folders_editor.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';

/// A running ACP host: its agent's state (starting, running, not running and
/// why, sign-in needed), what the agent negotiated, the gateway and meta
/// service, a restart action and the project folders.
///
/// Feature rows are shown only from a live negotiation; before it they say
/// so instead of guessing.
class AcpHostDetails extends ConsumerStatefulWidget {
  /// Creates the details for [host].
  const AcpHostDetails({super.key, required this.host});

  /// The ACP host.
  final AppServeStatus host;

  @override
  ConsumerState<AcpHostDetails> createState() => _AcpHostDetailsState();
}

class _AcpHostDetailsState extends ConsumerState<AcpHostDetails> {
  bool _restarting = false;
  String? _error;

  Future<void> _restart() async {
    setState(() {
      _restarting = true;
      _error = null;
    });
    // The restart can finish after this view closed or its scope went away.
    final container = ProviderScope.containerOf(context);
    final api = container.read(bridgeApiProvider);
    final life = container.read(scopeLifeProvider);
    try {
      await api.appServeRestartAcp(widget.host.name);
      if (life.alive) container.invalidate(localServeListProvider);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  String _phaseLabel(AppLocalizations l10n, String? phase) => switch (phase) {
    'ready' => l10n.acpPhaseReady,
    'failed' => l10n.acpPhaseFailed,
    'stopped' => l10n.acpPhaseStopped,
    _ => l10n.acpPhaseStarting,
  };

  String _catalogReason(AppLocalizations l10n, String? reason) =>
      switch (reason) {
        'plugins-disabled' => l10n.acpCatalogReasonPluginsDisabled,
        'config-env-taken' => l10n.acpCatalogReasonConfigTaken,
        'install-failed' => l10n.acpCatalogReasonInstallFailed,
        _ => reason ?? '',
      };

  String _routeReason(AppLocalizations l10n, String reason) => switch (reason) {
    'model' => l10n.acpRouteReasonModel,
    'small-model' => l10n.acpRouteReasonSmallModel,
    'agent-model' => l10n.acpRouteReasonAgentModel,
    'provider' => l10n.acpRouteReasonProvider,
    'enabled-providers' => l10n.acpRouteReasonEnabled,
    'disabled-providers' => l10n.acpRouteReasonDisabled,
    'missing' => l10n.acpRouteReasonMissing,
    'key' => l10n.acpRouteReasonKey,
    _ => _catalogReason(l10n, reason),
  };

  /// The model catalog: one line per provider, so a full listing, a bounded
  /// one and a failed one read differently.
  Widget _catalog(
    AppLocalizations l10n,
    AcpCatalogStatus catalog,
    TextStyle? style,
    ColorScheme scheme,
  ) {
    final lines = <Widget>[
      Text(
        l10n.acpCatalog,
        style: style?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
    ];
    final route = catalog.routeState;
    if (route != null) {
      final reasons = catalog.routeReasons
          .map((r) => _routeReason(l10n, r))
          .join(', ');
      final (text, warn) = switch (route) {
        'selected' => (l10n.acpRouteSelected, false),
        'enforced' => (l10n.acpRouteEnforced(reasons), false),
        'overridden' => (l10n.acpRouteOverridden(reasons), true),
        'unverified' => (l10n.acpRouteUnverified(reasons), true),
        'refused' => (l10n.acpRouteRefused, true),
        _ => (l10n.acpRouteWaiting, false),
      };
      lines.add(
        Text(
          text,
          key: const Key('acp-catalog-route'),
          style: warn ? style?.copyWith(color: scheme.error) : style,
        ),
      );
      if (catalog.routeProjects.isNotEmpty) {
        lines.add(
          Text(
            l10n.acpRouteProjects(catalog.routeProjects.join(', ')),
            key: const Key('acp-catalog-route-projects'),
            style: style,
          ),
        );
      }
      // What the hook cannot reach, so "selected" is not read as more.
      if (route == 'selected' || route == 'enforced') {
        lines.add(
          Text(
            l10n.acpRouteScope,
            key: const Key('acp-catalog-route-scope'),
            style: style,
          ),
        );
      }
    }
    if (catalog.state == 'waiting') {
      lines.add(Text(l10n.acpCatalogWaiting, style: style));
    } else if (catalog.state != 'reported') {
      lines.add(
        Text(
          l10n.acpCatalogUnavailable(_catalogReason(l10n, catalog.reason)),
          style: style?.copyWith(color: scheme.error),
        ),
      );
    } else if (catalog.providers.isEmpty) {
      lines.add(
        Text(
          l10n.acpCatalogNoProviders,
          key: const Key('acp-catalog-none'),
          style: style,
        ),
      );
    }
    for (final provider in catalog.providers) {
      final reason = _catalogReason(l10n, provider.reason);
      final text = switch (provider.status) {
        'complete' => l10n.acpCatalogProviderComplete(
          provider.id,
          provider.listed,
          provider.added,
        ),
        'partial' => l10n.acpCatalogProviderPartial(
          provider.id,
          provider.listed,
          provider.added,
          reason,
        ),
        'skipped' => l10n.acpCatalogProviderSkipped(provider.id, reason),
        _ => l10n.acpCatalogProviderFailed(provider.id, reason),
      };
      lines.add(
        Text(text, key: Key('acp-catalog-${provider.id}'), style: style),
      );
      if (provider.excluded > 0) {
        lines.add(
          Text(l10n.acpCatalogExcluded(provider.excluded), style: style),
        );
      }
      if (provider.unsafeIds > 0) {
        lines.add(
          Text(l10n.acpCatalogUnsafe(provider.unsafeIds), style: style),
        );
      }
      if (provider.keySource == 'none' && provider.status == 'failed') {
        lines.add(
          Text(
            l10n.acpCatalogNoKey,
            style: style?.copyWith(color: scheme.error),
          ),
        );
      }
    }
    // The plugin location is only needed to add it by hand.
    if (catalog.state == 'unavailable' && catalog.plugin != null) {
      lines.add(
        SelectableText(
          '${l10n.acpCatalogPlugin}: ${catalog.plugin}',
          style: style,
        ),
      );
    }
    return Column(
      key: const Key('acp-catalog'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }

  Widget _feature(String label, String value, TextStyle? style) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: style)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(value, style: style, textAlign: TextAlign.end),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final host = widget.host;
    final phase = host.agentPhase;
    final ready = phase == 'ready';
    final caps = ref
        .read(bridgeApiProvider)
        .appCapabilities(host.appServiceKey);
    final negotiated = ready && caps.negotiated;
    final phaseColor = switch (phase) {
      'ready' => successColor(scheme),
      'failed' => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    String supported(bool value) =>
        value ? l10n.acpFeatureSupported : l10n.acpFeatureNotSupported;
    final reopen = switch (caps.sessionReopen) {
      'load' => l10n.acpFeatureReopenLoad,
      'resume' => l10n.acpFeatureReopenResume,
      _ => l10n.acpFeatureNotSupported,
    };
    return Column(
      key: const Key('acp-host-details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ProviderBadge(
              provider: 'acp',
              name: host.providerName,
              profileId: host.profileId,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 10, color: phaseColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _phaseLabel(l10n, phase),
                    key: const Key('acp-phase'),
                    style: small?.copyWith(color: phaseColor),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (host.agentError != null && !ready) ...[
          const SizedBox(height: 6),
          SelectableText(
            host.agentError!,
            key: const Key('acp-agent-error'),
            style: small?.copyWith(color: scheme.error),
          ),
        ],
        if (host.authRequired) ...[
          const SizedBox(height: 6),
          Text(
            l10n.acpAuthRequired,
            key: const Key('acp-auth-required'),
            style: small?.copyWith(color: cautionColor(scheme)),
          ),
        ],
        const SizedBox(height: 8),
        Text(l10n.acpStopNote, style: small),
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('acp-restart'),
            onPressed: _restarting ? null : _restart,
            icon: const Icon(Icons.restart_alt),
            label: Text(l10n.acpRestart),
          ),
        ),
        if (_error != null)
          Text(_error!, style: small?.copyWith(color: scheme.error)),
        const Divider(height: 24),
        Text(
          l10n.acpFeatures,
          style: small?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        if (!negotiated)
          Text(
            l10n.acpFeatureUnknown,
            key: const Key('acp-features-unknown'),
            style: muted,
          )
        else ...[
          _feature(l10n.acpFeatureReopen, reopen, small),
          _feature(
            l10n.acpFeatureList,
            supported(caps.sessionList == 'agent'),
            small,
          ),
          _feature(l10n.acpFeatureImages, supported(caps.imageInput), small),
        ],
        const Divider(height: 24),
        Text(l10n.acpGatewayLabel, style: small),
        Text(l10n.localHostListening(host.appListenAddr), style: small),
        SelectableText(host.appServiceKey, style: muted),
        const SizedBox(height: 8),
        Text(l10n.hostMetaLabel, style: small),
        Text(l10n.localHostListening(host.metaListenAddr), style: small),
        SelectableText(host.metaServiceKey, style: muted),
        if (host.codexBinary != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            '${l10n.acpProgram}: ${host.codexBinary}',
            style: muted,
          ),
        ],
        if (host.catalog != null) ...[
          const Divider(height: 24),
          _catalog(l10n, host.catalog!, small, scheme),
        ],
        const Divider(height: 24),
        ProjectFoldersEditor(serviceKey: host.appServiceKey),
      ],
    );
  }
}
