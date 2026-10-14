import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';

typedef SessionControlChoice = ({SessionControl snapshot, String action});

/// Inspecting this dialog only reads ownership. Its result carries the exact
/// snapshot shown alongside the operation the user explicitly chose.
class SessionControlDialog extends StatefulWidget {
  const SessionControlDialog({super.key, required this.load});
  final Future<SessionControl> Function() load;

  @override
  State<SessionControlDialog> createState() => _SessionControlDialogState();
}

class _SessionControlDialogState extends State<SessionControlDialog> {
  SessionControl? _snapshot;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _snapshot = null;
      _error = null;
    });
    try {
      final snapshot = await widget.load();
      if (mounted) setState(() => _snapshot = snapshot);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _choose(String action) {
    final snapshot = _snapshot;
    if (!_loading && snapshot != null) {
      Navigator.of(
        context,
      ).pop<SessionControlChoice>((snapshot: snapshot, action: action));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final view = _snapshot;
    final scheme = Theme.of(context).colorScheme;
    final description = switch (view?.status) {
      'owned' || 'running' =>
        view?.provider == 'opencode'
            ? l10n.sessionControlSameEngine
            : l10n.sessionControlOwned,
      'released' => l10n.sessionControlReleased,
      'external_idle' => l10n.sessionControlExternalIdle,
      'external_running' => l10n.sessionControlExternalRunning,
      'releasing' => l10n.sessionControlReleasePending,
      'loading' => l10n.sessionControlLoading,
      'engine_required' => l10n.sessionControlEngineRequired,
      'stopped' => l10n.sessionControlStopped,
      _ => l10n.sessionControlUnknown,
    };
    return AlertDialog(
      key: const Key('session-control-dialog'),
      title: Text(l10n.sessionControlTitle),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Text(l10n.sessionControlChecking),
              ] else if (_error != null)
                Text(
                  friendlyError(_error!),
                  style: TextStyle(color: scheme.error),
                )
              else ...[
                Text(description),
                if (view?.canAcquire ?? false) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.sessionControlExclusiveNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (view?.canRelease ?? false) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.sessionControlReleaseNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton.icon(
          key: const Key('session-control-refresh'),
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(l10n.refreshStatus),
        ),
        if (!_loading && view != null) ...[
          if (view.canRelease)
            OutlinedButton.icon(
              key: const Key('session-control-release'),
              onPressed: () => _choose('release'),
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(l10n.sessionControlRelease),
            ),
          if (view.canContinue)
            FilledButton.icon(
              key: const Key('session-control-continue'),
              onPressed: () => _choose('continue'),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(l10n.sessionControlContinue),
            ),
          if (view.canAcquire)
            FilledButton.icon(
              key: const Key('session-control-acquire'),
              onPressed: () => _choose('acquire'),
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(l10n.sessionControlAcquire),
            ),
        ],
      ],
    );
  }
}
