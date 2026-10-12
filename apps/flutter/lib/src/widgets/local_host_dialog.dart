import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/acp_host_details.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/project_folders_editor.dart';

/// Horizontal padding of each Codex source segment.
const _sourceSegmentPadding = EdgeInsets.symmetric(horizontal: 12);

/// Manage one local host. With [existing] set it shows that host's listen
/// address + service key and a Stop button. Otherwise it's the "new host" form:
/// pick the agent from a grid of clickable tiles ([AgentChoiceGrid]: Codex,
/// ACP presets, saved agents, custom), then fill its form — essentials first,
/// rarely-changed fields behind "Advanced". Codex: instance name and proxy,
/// with port and codex path advanced; ACP agents: see
/// `hosting/acp_host_form.dart`. codex is auto-detected (with a "change
/// path" override) or picked when not on PATH.
///
/// Every new host gets a free instance name and, beside another Codex host,
/// an automatic port, so hosting a second or third instance never collides
/// with the first by default.
///
/// Shared by the manage page's hosting tab and the chat-first home screen's
/// "start hosting" hero action, so both entry points behave identically.
class LocalHostDialog extends ConsumerStatefulWidget {
  /// Creates the dialog; [existing] switches it to manage-a-running-host mode.
  const LocalHostDialog({super.key, this.existing});

  /// The running host this dialog manages, or null to host a new one.
  final AppServeStatus? existing;

  @override
  ConsumerState<LocalHostDialog> createState() => _LocalHostDialogState();
}

class _LocalHostDialogState extends ConsumerState<LocalHostDialog> {
  final _port = TextEditingController(text: '$defaultCodexPort');
  final _path = TextEditingController();
  final _name = TextEditingController(text: 'default');
  // Whether the user typed into the name / port fields; a suggestion only
  // replaces untouched values.
  bool _nameEdited = false;
  bool _portEdited = false;
  bool _advanced = false;
  // Codex needs a proxy to reach chatgpt.com on most networks, so hosting
  // defaults to a proxy (a local HTTP proxy on :11111) unless the user opts out.
  final _proxy = TextEditingController(text: 'http://127.0.0.1:11111');
  bool _useProxy = true;
  bool _overridePath = false; // user chose to customize the codex path
  String? _codexPath; // auto-detected codex (config → PATH), null = not found
  bool _codexChecked = false;
  int _detectSeq = 0;
  // Moves on every explicit codex-path decision (typing, picking a file,
  // "change path"), agent switch and start. A late detection or file pick
  // applies only while it is unchanged.
  int _pathIntent = 0;
  bool _busy = false;
  String? _error;
  // New-host agent, see [AgentChoice].
  AgentChoice _choice = codexChoice;
  AcpFormValue? _acp;
  bool get _isExisting => widget.existing != null;
  bool get _codexFound => _codexPath != null;

  /// The port the first Codex host listens on by default.
  static const defaultCodexPort = 18080;

  /// Instance names this device already hosts (any provider).
  Set<String> get _takenNames => {
    for (final host
        in ref.read(localServeListProvider).valueOrNull ??
            const <AppServeStatus>[])
      host.name,
  };

  Widget _agentGrid() {
    final api = ref.watch(bridgeApiProvider);
    final saved =
        ref.watch(uiPrefsProvider).valueOrNull?.acpAgents ??
        const <AcpAgentSpec>[];
    return AgentChoiceGrid(
      value: _choice,
      presets: api.acpPresets(),
      saved: saved,
      onChanged: _busy
          ? null
          : (choice) => setState(() {
              _choice = choice;
              _pathIntent++;
              _error = null;
            }),
    );
  }

  /// Fill untouched name and port fields with values free on this device:
  /// `default`, `default-2`, …, and an automatic port (0) once any Codex
  /// host already runs, since its fixed default would be taken.
  void _suggestDefaults() {
    final hosts =
        ref.read(localServeListProvider).valueOrNull ??
        const <AppServeStatus>[];
    if (!_nameEdited) _name.text = uniqueHostName('default', _takenNames);
    if (!_portEdited) {
      final codexRunning = hosts.any((h) => h.isCodex);
      _port.text = codexRunning ? '0' : '$defaultCodexPort';
    }
  }

  @override
  void initState() {
    super.initState();
    if (_isExisting) return;
    _suggestDefaults();
    // Hosts may still be loading; suggest again once they arrive.
    ref.listenManual(localServeListProvider, (_, _) {
      if (mounted && !_isExisting) setState(_suggestDefaults);
    });
    // Auto-detect codex: when found we just show "available" (with a "change
    // path" override); when not, the user picks a path (persisted on start) or
    // installs codex and taps "re-detect".
    Future.microtask(_detectCodex);
  }

  /// (Re-)resolve codex from PATH + persisted config. Safe to call again from a
  /// "re-detect" button: a user who hadn't installed codex yet can install it,
  /// tap re-detect, and have it picked up — no need to type a full path.
  Future<void> _detectCodex() async {
    if (!mounted) return;
    final seq = ++_detectSeq;
    final intent = _pathIntent;
    final typed = _path.text;
    setState(() => _codexChecked = false); // show the progress indicator
    String? found;
    try {
      found = await ref.read(bridgeApiProvider).codexLocate();
    } catch (_) {
      // Detection is best-effort: an error reads as "not found".
    }
    // Only the latest detection counts.
    if (!mounted || seq != _detectSeq) return;
    setState(() {
      _codexPath = found;
      _codexChecked = true;
      // Prefill the override field, unless the user typed or picked a path
      // or chose to change it while detection ran; a fresh detection then
      // supersedes the override only if the user did neither.
      if (found != null && intent == _pathIntent && _path.text == typed) {
        _path.text = found;
        _overridePath = false;
      }
    });
  }

  @override
  void dispose() {
    _port.dispose();
    _path.dispose();
    _name.dispose();
    _proxy.dispose();
    super.dispose();
  }

  /// Pick the codex binary. The pick applies only to the Codex form it was
  /// opened from: an agent switch, a newer path edit or a start since then
  /// drops it.
  Future<void> _browseCodex() async {
    final intent = _pathIntent;
    final file = await openFile();
    if (file == null || !mounted) return;
    if (intent != _pathIntent || _busy || isAcpChoice(_choice)) return;
    setState(() {
      _path.text = file.path;
      _overridePath = true;
      _pathIntent++;
    });
  }

  Future<void> _start() async {
    final l10n = AppLocalizations.of(context);
    _pathIntent++;
    final port = int.tryParse(_port.text.trim());
    // 0 is allowed (the engine picks an ephemeral port); reject out-of-range,
    // incl. negatives, which would otherwise wrap silently to a u16.
    if (port == null || port < 0 || port > 65535) {
      setState(() {
        _advanced = true;
        _error = l10n.localHostPortInvalid;
      });
      return;
    }
    final manual = !_codexFound || _overridePath;
    final path = manual ? _path.text.trim() : '';
    if (manual && path.isEmpty) {
      setState(() {
        _advanced = true;
        _error = l10n.codexPathRequired;
      });
      return;
    }
    final override = path.isEmpty ? null : path;
    // A proxy is mandatory unless the user explicitly turned it off.
    final proxy = _useProxy ? _proxy.text.trim() : null;
    if (_useProxy && (proxy == null || proxy.isEmpty)) {
      setState(() => _error = l10n.proxyRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // The restore verdict and completion bookkeeping can finish after the
    // dialog route closed. Capture durable dependencies before the await so
    // completions never touch a disposed WidgetRef.
    final toast = ToastMessenger.of(context);
    final container = ProviderScope.containerOf(context);
    final api = container.read(bridgeApiProvider);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      final name = _name.text.trim();
      await api.appServeStart(
        port: port,
        binaryOverride: override,
        name: name.isEmpty ? null : name,
        proxy: proxy,
        embedded: false,
      );
      if (!life.alive) return;
      // Remember the params so a desktop cold start can restore this hosting
      // without another trip through this dialog. The verdict is taken on
      // the loaded file: a full restore list keeps every other host's record
      // and says this one won't come back.
      final remembered = prefs.setAutoHost(
        AutoHostPrefs(
          port: port,
          name: name.isEmpty ? 'default' : name,
          proxy: proxy,
          embedded: false,
          binaryOverride: override,
        ),
      );
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (mounted) Navigator.of(context).pop();
      // A disposed store answers false without having judged anything.
      if (!await remembered && life.alive) {
        toast.notice(l10n.hostRestoreFull(UiPrefs.maxAutoHosts));
      }
    } catch (e) {
      if (mounted) {
        // A duplicate-name refusal (another live instance owns this name) gets
        // the localized guidance instead of the raw broker reason.
        setState(() => _error = _hostingError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startAcp() async {
    final value = _acp;
    if (value == null || !value.valid) {
      setState(() => _error = AppLocalizations.of(context).acpProgramNotFound);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    final container = ProviderScope.containerOf(context);
    final api = container.read(bridgeApiProvider);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      final result = await api.appServeStartAcp(
        name: value.name.isEmpty ? null : value.name,
        spec: value.spec,
      );
      if (!life.alive) return;
      // Both verdicts are taken on the loaded file (see [_start]).
      final remembered = prefs.setAutoHostAcp(
        AutoHostAcpPrefs(name: result.name, spec: value.spec),
      );
      final saved = value.save
          ? prefs.saveAcpAgent(value.spec)
          : Future.value(true);
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (mounted) Navigator.of(context).pop();
      final notices = [
        if (!await remembered) l10n.hostRestoreFull(UiPrefs.maxAutoHosts),
        if (!await saved) l10n.acpSavedAgentsFull(UiPrefs.maxSavedAgents),
      ];
      if (notices.isNotEmpty && life.alive) toast.notice(notices.join('\n'));
    } catch (e) {
      if (mounted) setState(() => _error = _hostingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A start failure in the user's words: a name or port another host owns
  /// gets localized guidance instead of the raw reason.
  String _hostingError(Object e) {
    final l10n = AppLocalizations.of(context);
    final raw = friendlyError(e);
    if (isHostNameConflict(raw) || isLocalNameTaken(raw)) {
      return l10n.hostNameConflict;
    }
    if (isLocalPortTaken(raw)) {
      _advanced = true;
      return l10n.hostPortConflict;
    }
    return raw;
  }

  Future<void> _stopAcp() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final host = widget.existing!;
    final container = ProviderScope.containerOf(context);
    final api = container.read(bridgeApiProvider);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      // Stops the agent and cleans up the processes it started.
      await api.appServeStop(host.name);
      if (!life.alive) return;
      prefs.clearAutoHostAcp(host.name);
      container
          .read(pendingRemovalProvider.notifier)
          .update((set) => {...set, host.appServiceKey});
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (widget.existing!.isAcp) return _stopAcp();
    setState(() {
      _busy = true;
      _error = null;
    });
    final host = widget.existing!;
    final container = ProviderScope.containerOf(context);
    final api = container.read(bridgeApiProvider);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      // Full stop: kills codex + the API proxy, aborts both tunnels, and
      // force-drops both relay keys.
      await api.appServeStop(host.name);
      if (!life.alive) return;
      // The user stopped this host on purpose — don't resurrect it at boot.
      // Other hosts keep their own restore records.
      prefs.clearAutoHost(host.name);
      // Optimistically hide both discovery entries so they leave at once.
      container
          .read(pendingRemovalProvider.notifier)
          .update((set) => {...set, host.appServiceKey, host.apiServiceKey});
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final existing = widget.existing;
    if (existing != null ? existing.isAcp : isAcpChoice(_choice)) {
      return _dialog(
        existing != null
            ? [AcpHostDetails(host: existing)]
            : [
                _agentGrid(),
                const SizedBox(height: 16),
                AcpHostForm(
                  choice: _choice,
                  enabled: !_busy,
                  takenNames: _takenNames,
                  onChanged: (value) => _acp = value,
                ),
              ],
        wide: true,
      );
    }
    final children = <Widget>[
      if (existing == null) ...[_agentGrid(), const SizedBox(height: 16)],
      Text(l10n.localHostHint, style: existing == null ? small : null),
    ];
    if (existing != null) {
      // Two tunnels under one name: show each kind's listen address + relay key.
      children
        ..add(const SizedBox(height: 12))
        ..add(Text(l10n.tunnelAppLabel, style: small))
        ..add(
          Text(l10n.localHostListening(existing.appListenAddr), style: small),
        )
        ..add(
          SelectableText(
            existing.appServiceKey,
            style: small?.copyWith(color: scheme.onSurfaceVariant),
          ),
        )
        ..add(const SizedBox(height: 8))
        ..add(Text(l10n.tunnelApiLabel, style: small))
        ..add(
          Text(l10n.localHostListening(existing.apiListenAddr), style: small),
        )
        ..add(
          SelectableText(
            existing.apiServiceKey,
            style: small?.copyWith(color: scheme.onSurfaceVariant),
          ),
        )
        // Runtime details for the external Codex process.
        ..add(const Divider(height: 24))
        ..add(
          Text(
            l10n.hostRuntimeInfo,
            style: small?.copyWith(fontWeight: FontWeight.w600),
          ),
        )
        ..add(const SizedBox(height: 4))
        ..add(
          Text(
            '${l10n.hostRuntimeMode}: '
            '${l10n.codexSourceExternal}',
            style: small,
          ),
        )
        ..add(
          SelectableText(
            '${l10n.hostCodexPath}: ${existing.codexBinary ?? '—'}',
            style: small?.copyWith(color: scheme.onSurfaceVariant),
          ),
        )
        ..add(
          Text(
            '${l10n.hostProxyLabel}: ${existing.proxy ?? l10n.hostProxyInherit}',
            style: small,
          ),
        )
        // Project folders: the roots a phone's folder browser is confined to,
        // and the default new conversations open in. Configured on the host.
        ..add(const Divider(height: 24))
        ..add(ProjectFoldersEditor(serviceKey: existing.appServiceKey));
    } else {
      children.add(const SizedBox(height: 16));
      children
        ..add(
          LayoutBuilder(
            builder: (context, constraints) => SegmentedButton<bool>(
              key: const Key('codex-source'),
              // Segments share the widest one's width: side by side only
              // while each label fits on one line, else stacked.
              direction: _sourceFitsAcross(context, constraints.maxWidth)
                  ? Axis.horizontal
                  : Axis.vertical,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(_sourceSegmentPadding),
              ),
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(l10n.codexSourceExternal),
                ),
                // The built-in engine is not implemented: shown, never
                // selectable.
                ButtonSegment(
                  value: true,
                  enabled: false,
                  label: Text(l10n.codexSourceBuiltin),
                ),
              ],
              selected: const {false},
              onSelectionChanged: _busy ? null : (_) {},
            ),
          ),
        )
        ..add(const SizedBox(height: 8))
        ..add(Text(l10n.codexBuiltinNote, style: small))
        ..add(const SizedBox(height: 12));
      if (!_codexChecked) {
        children.add(const LinearProgressIndicator());
      } else if (_codexFound && !_overridePath) {
        children.add(_codexAvailable());
      } else {
        if (!_codexFound) {
          children
            ..add(
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.codexNotFound,
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                  // Installed codex just now? Re-detect instead of typing a path.
                  TextButton.icon(
                    key: const Key('redetect-codex-btn'),
                    onPressed: _busy ? null : _detectCodex,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.codexRedetect),
                  ),
                ],
              ),
            )
            ..add(const SizedBox(height: 8));
        }
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('codex-path-field'),
                  controller: _path,
                  decoration: InputDecoration(labelText: l10n.codexBinaryPath),
                  onChanged: (_) {
                    _overridePath = true;
                    _pathIntent++;
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const Key('browse-codex-btn'),
                onPressed: _busy ? null : _browseCodex,
                child: Text(l10n.chooseCodexPath),
              ),
            ],
          ),
        );
      }
      // --- name (essential) ---
      children
        ..add(const SizedBox(height: 12))
        ..add(
          TextField(
            key: const Key('codex-name-field'),
            controller: _name,
            decoration: InputDecoration(
              labelText: l10n.localHostName,
              helperText: l10n.hostNameHelper,
            ),
            onChanged: (_) => _nameEdited = true,
          ),
        )
        // --- proxy (mandatory unless turned off) ---
        ..add(
          SwitchListTile(
            key: const Key('use-proxy-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.useProxy),
            value: _useProxy,
            onChanged: _busy ? null : (v) => setState(() => _useProxy = v),
          ),
        );
      if (_useProxy) {
        children.add(
          TextField(
            key: const Key('proxy-field'),
            controller: _proxy,
            decoration: InputDecoration(labelText: l10n.proxyLabel),
          ),
        );
      } else {
        children.add(
          Text(
            l10n.noProxyWarning,
            style: TextStyle(color: cautionColor(scheme)),
          ),
        );
      }
      // --- advanced: the listen port ---
      children.add(
        AdvancedToggle(
          key: const Key('codex-advanced-toggle'),
          open: _advanced,
          onChanged: (open) => setState(() => _advanced = open),
        ),
      );
      if (_advanced) {
        children.add(
          TextField(
            key: const Key('codex-port-field'),
            controller: _port,
            decoration: InputDecoration(
              labelText: l10n.localHostPort,
              helperText: l10n.localHostPortHelper,
            ),
            keyboardType: TextInputType.number,
            onChanged: (_) => _portEdited = true,
          ),
        );
      }
    }
    return _dialog(children);
  }

  Widget _codexAvailable() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = Row(
      children: [
        Icon(
          Icons.check_circle,
          size: 18,
          color: successColor(theme.colorScheme),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            l10n.codexFoundAt(_codexPath!),
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final customize = TextButton(
      key: const Key('customize-codex-btn'),
      onPressed: _busy
          ? null
          : () => setState(() {
              _overridePath = true;
              _pathIntent++;
            }),
      child: Text(l10n.customizeCodexPath),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 320) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [status, customize],
          );
        }
        return Row(
          children: [
            Expanded(child: status),
            customize,
          ],
        );
      },
    );
  }

  /// Whether the Codex source segments fit side by side in [width], each
  /// label on one line beside the selected segment's check mark.
  bool _sourceFitsAcross(BuildContext context, double width) {
    final l10n = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.labelLarge;
    double text(String label) => measureTextLine(context, label, style).width;

    // The selected segment carries the 18 px check mark; Material then uses
    // its own icon padding (12 + 16) and gap (8), both at most at 1× text.
    final segment = math.max(
      12 + 16 + 18 + 8 + text(l10n.codexSourceExternal),
      _sourceSegmentPadding.horizontal + text(l10n.codexSourceBuiltin),
    );
    // Two segments plus the outer and dividing borders.
    return 2 * segment + 3 <= width;
  }

  /// The dialog frame shared by every provider: [children], the error line,
  /// and Cancel plus Start / Stop. [wide] gives the argument editor room on
  /// desktop; phones clamp the width to the screen either way.
  Widget _dialog(List<Widget> children, {bool wide = false}) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final existing = widget.existing;
    if (_error != null) {
      children
        ..add(const SizedBox(height: 12))
        ..add(Text(_error!, style: TextStyle(color: scheme.error)));
    }
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.localHostDialogTitle),
        content: SizedBox(
          width: wide ? 460 : 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          if (existing != null)
            FilledButton(
              key: const Key('stop-hosting-btn'),
              onPressed: _busy ? null : _stop,
              child: Text(l10n.stopHosting),
            )
          else
            FilledButton(
              key: const Key('start-hosting-btn'),
              onPressed: _busy
                  ? null
                  : isAcpChoice(_choice)
                  ? _startAcp
                  : _start,
              child: Text(l10n.startHosting),
            ),
        ],
      ),
    );
  }
}
