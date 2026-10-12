import 'dart:async';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/argv_editor.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';

/// What the ACP form currently describes.
class AcpFormValue {
  /// Creates a form value.
  const AcpFormValue({
    required this.name,
    required this.spec,
    required this.save,
  });

  /// Instance name (defaults to the profile id when empty).
  final String name;

  /// The agent to host.
  final AcpAgentSpec spec;

  /// Whether to save a custom agent to "my agents".
  final bool save;

  /// Whether the value can be submitted.
  bool get valid =>
      spec.program.trim().isNotEmpty && spec.displayName.trim().isNotEmpty;
}

/// The profile id of a new custom agent named [name]. The readable part is
/// a lossy slug (names in other scripts all become `agent`), so [salt] —
/// random per new agent, see [newProfileSalt] — keeps two custom agents
/// from ever sharing a saved entry. The id only names the saved entry: the
/// host binds sessions to the program and arguments actually run.
String customProfileId(String name, String salt) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = slug.length > 40 ? slug.substring(0, 40) : slug;
  return 'custom-${cut.isEmpty ? 'agent' : cut}-$salt';
}

/// Eight random hex digits for [customProfileId].
String newProfileSalt([Random? random]) {
  final source = random ?? Random.secure();
  return [
    for (var i = 0; i < 8; i++) source.nextInt(16).toRadixString(16),
  ].join();
}

/// The new-ACP-host form for the agent picked in the dialog's agent grid
/// ([choice]: `preset:<id>`, `saved:<profileId>` or `custom`).
///
/// Essentials first — the instance name and whether the program was found.
/// The program and argument vector of a preset or saved agent sit behind
/// "Advanced"; a custom agent shows them open, since they are what it is.
class AcpHostForm extends ConsumerStatefulWidget {
  /// Creates the form; [onChanged] receives every edit.
  const AcpHostForm({
    super.key,
    required this.choice,
    required this.onChanged,
    this.enabled = true,
    this.takenNames = const {},
  });

  /// The agent picked in the grid.
  final String choice;

  /// Called with the current value.
  final ValueChanged<AcpFormValue> onChanged;

  /// Whether the fields can be edited.
  final bool enabled;

  /// Instance names running hosts already use on this device; the suggested
  /// name avoids them.
  final Set<String> takenNames;

  @override
  ConsumerState<AcpHostForm> createState() => _AcpHostFormState();
}

class _AcpHostFormState extends ConsumerState<AcpHostForm> {
  static const _custom = customAgentChoice;
  // One per new custom agent this form describes.
  final String _salt = newProfileSalt();
  final _name = TextEditingController();
  final _displayName = TextEditingController();
  final _program = TextEditingController();
  List<String> _args = const [];
  List<String> _argsSeed = const [];
  String _choice = _custom;
  String _profileId = '';
  bool _save = true;
  bool _advanced = false;
  // Whether the user typed an instance name; a suggested one follows the
  // agent choice, a typed one stays.
  bool _nameEdited = false;
  String? _located;
  bool _locating = false;
  // The last lookup failed (shown with a retry), as opposed to not found.
  String? _locateError;
  Timer? _locateDebounce;
  // Moves on every change of the program or agent, so a lookup or a file
  // pick started before it can never publish its result.
  int _locateSeq = 0;
  int _choiceSeq = 0;

  @override
  void initState() {
    super.initState();
    _select(widget.choice, emit: false);
    Future.microtask(() {
      if (!mounted) return;
      _emit();
      _locate();
    });
  }

  @override
  void didUpdateWidget(AcpHostForm old) {
    super.didUpdateWidget(old);
    if (old.choice != widget.choice) {
      _select(widget.choice);
    } else if (!_nameEdited && !_sameNames(old.takenNames, widget.takenNames)) {
      // Running hosts arrived (or changed): an untouched suggestion moves
      // off any name they now use; a typed name stays.
      _name.text = uniqueHostName(_nameBase, widget.takenNames);
      _emit();
    }
  }

  static bool _sameNames(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  String get _nameBase => _choice == _custom ? 'agent' : _profileId;

  /// Load [choice] into the fields: a preset, a saved agent, or empty
  /// fields for a new custom agent.
  void _select(String choice, {bool emit = true}) {
    final presets = ref.read(bridgeApiProvider).acpPresets();
    final saved =
        ref.read(uiPrefsProvider).valueOrNull?.acpAgents ??
        const <AcpAgentSpec>[];
    AcpAgentSpec? spec;
    if (choice.startsWith('preset:')) {
      final id = choice.substring(7);
      spec = presets.where((p) => p.id == id).firstOrNull?.spec;
    } else if (choice.startsWith('saved:')) {
      final id = choice.substring(6);
      spec = saved.where((a) => a.profileId == id).firstOrNull;
    }
    _apply(
      spec == null ? _custom : choice,
      spec ?? const AcpAgentSpec(profileId: '', displayName: '', program: ''),
      emit: emit,
    );
  }

  @override
  void dispose() {
    _locateDebounce?.cancel();
    _name.dispose();
    _displayName.dispose();
    _program.dispose();
    super.dispose();
  }

  bool get _isCustom => !_choice.startsWith('preset:');

  void _apply(String choice, AcpAgentSpec spec, {bool emit = true}) {
    _choiceSeq++;
    _choice = choice;
    _profileId = spec.profileId;
    _displayName.text = spec.displayName;
    _program.text = spec.program;
    _args = List.of(spec.args);
    _argsSeed = _args;
    // A custom agent is defined by its program and arguments: show them.
    _advanced = choice == _custom;
    if (!_nameEdited || _name.text.trim().isEmpty) {
      _nameEdited = false;
      _name.text = uniqueHostName(_nameBase, widget.takenNames);
    }
    if (emit) {
      _emit();
      _locate();
    }
  }

  AcpAgentSpec get _spec {
    final display = _displayName.text.trim();
    final id = _choice == _custom
        ? customProfileId(display, _salt)
        : _profileId;
    return AcpAgentSpec(
      profileId: id,
      displayName: display,
      // Paths may legitimately contain spaces; only surrounding whitespace,
      // which is never part of a typed path, is dropped.
      program: _program.text.trim(),
      args: List.unmodifiable(_args),
    );
  }

  void _emit() => widget.onChanged(
    AcpFormValue(
      name: _name.text.trim(),
      spec: _spec,
      save: _save && _isCustom,
    ),
  );

  void _locate() {
    _locateDebounce?.cancel();
    // Invalidate any lookup in flight at once, not when the debounce fires.
    final seq = ++_locateSeq;
    final program = _program.text.trim();
    final profileId = _profileId;
    if (program.isEmpty) {
      if (mounted) {
        setState(() {
          _located = null;
          _locating = false;
          _locateError = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _locating = true;
        _locateError = null;
      });
    }
    _locateDebounce = Timer(const Duration(milliseconds: 300), () async {
      String? found;
      String? error;
      try {
        found = await ref
            .read(bridgeApiProvider)
            .acpLocate(program, profileId: profileId);
      } catch (e) {
        error = friendlyError(e);
      }
      if (!mounted || seq != _locateSeq) return;
      setState(() {
        _located = found;
        _locateError = error;
        _locating = false;
      });
    });
  }

  Future<void> _browse() async {
    final choice = _choiceSeq;
    final file = await openFile();
    // A pick finishing after the agent changed belongs to the old one.
    if (file == null || !mounted || choice != _choiceSeq || !widget.enabled) {
      return;
    }
    setState(() => _program.text = file.path);
    _emit();
    _locate();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final api = ref.watch(bridgeApiProvider);
    final enabled = widget.enabled;
    if (!api.acpHostingSupported()) {
      return Text(
        l10n.acpHostingUnsupported,
        key: const Key('acp-hosting-unsupported'),
        style: TextStyle(color: cautionColor(scheme)),
      );
    }
    final program = _program.text.trim();
    final status = program.isEmpty || _locating
        ? null
        : _locateError != null
        ? Row(
            key: const Key('acp-program-locate-failed'),
            children: [
              Expanded(
                child: Text(
                  _locateError!,
                  style: small?.copyWith(color: scheme.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                key: const Key('acp-program-locate-retry'),
                onPressed: enabled ? _locate : null,
                child: Text(l10n.retry),
              ),
            ],
          )
        : _located == null
        ? Text(
            l10n.acpProgramNotFound,
            key: const Key('acp-program-missing'),
            style: small?.copyWith(color: scheme.error),
          )
        : Text(
            l10n.acpProgramFound(_located!),
            key: const Key('acp-program-found'),
            style: small?.copyWith(color: successColor(scheme)),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          );
    final programField = TextField(
      key: const Key('acp-program-field'),
      controller: _program,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: l10n.acpProgram),
      onChanged: (_) {
        _emit();
        _locate();
      },
    );
    final browse = OutlinedButton(
      key: const Key('acp-program-browse'),
      onPressed: enabled ? _browse : null,
      style: OutlinedButton.styleFrom(padding: _browsePadding),
      child: Text(l10n.acpProgramBrowse, maxLines: 1, softWrap: false),
    );
    final programFields = <Widget>[
      LayoutBuilder(
        builder: (context, constraints) {
          // Side by side only while the field keeps room for a short program
          // name and its label beside the button; otherwise the button goes
          // under the field, which then has the whole width.
          final scaler = MediaQuery.textScalerOf(context);
          final browseWidth =
              _browsePadding.horizontal +
              _textWidth(
                context,
                l10n.acpProgramBrowse,
                OutlinedButtonTheme.of(
                      context,
                    ).style?.textStyle?.resolve(const {}) ??
                    Theme.of(context).textTheme.labelLarge,
              );
          final fieldMinimum = scaler.scale(16) * _programFieldGlyphs;
          if (constraints.maxWidth - 8 - browseWidth >= fieldMinimum) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: programField),
                const SizedBox(width: 8),
                browse,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              programField,
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerEnd, child: browse),
            ],
          );
        },
      ),
      const SizedBox(height: 4),
      Text(l10n.acpProgramHint, style: small),
      const SizedBox(height: 12),
      ArgvEditor(
        key: const Key('acp-argv-editor'),
        initial: _argsSeed,
        enabled: enabled,
        onChanged: (args) {
          _args = args;
          _emit();
        },
      ),
    ];
    return Column(
      key: const Key('acp-host-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.acpHostHint, style: small),
        const SizedBox(height: 12),
        if (_isCustom) ...[
          TextField(
            key: const Key('acp-display-name-field'),
            controller: _displayName,
            enabled: enabled,
            decoration: InputDecoration(labelText: l10n.acpAgentName),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const Key('acp-instance-name-field'),
          controller: _name,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: l10n.localHostName,
            helperText: l10n.hostNameHelper,
          ),
          onChanged: (_) {
            _nameEdited = true;
            _emit();
          },
        ),
        if (status != null) ...[const SizedBox(height: 8), status],
        const SizedBox(height: 4),
        AdvancedToggle(
          key: const Key('acp-advanced-toggle'),
          open: _advanced,
          // Reseed the argument editor from the current vector, so folding
          // and unfolding keeps edits.
          onChanged: (open) => setState(() {
            _advanced = open;
            _argsSeed = List.of(_args);
          }),
        ),
        if (_advanced) ...programFields,
        if (_isCustom) ...[
          CheckboxListTile(
            key: const Key('acp-save-agent'),
            contentPadding: EdgeInsets.zero,
            value: _save,
            title: Text(l10n.acpSaveAgent),
            onChanged: !enabled
                ? null
                : (value) {
                    setState(() => _save = value ?? false);
                    _emit();
                  },
          ),
          Text(l10n.acpSecretsNote, style: small),
        ],
      ],
    );
  }
}

/// A compact "Advanced" disclosure, shared by the Codex and ACP forms: a text button with a chevron that
/// reveals rarely-changed fields below it.
class AdvancedToggle extends StatelessWidget {
  /// Creates the toggle, [open] or folded.
  const AdvancedToggle({
    super.key,
    required this.open,
    required this.onChanged,
  });

  /// Whether the advanced fields are shown.
  final bool open;

  /// Called with the new state.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: () => onChanged(!open),
        icon: Icon(
          open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          size: 18,
        ),
        label: Text(l10n.hostAdvanced),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 40),
        ),
      ),
    );
  }
}

/// The Browse button's own padding, so its width is known before layout.
const _browsePadding = EdgeInsets.symmetric(horizontal: 16);

/// How many 16 px glyphs the program field keeps beside the Browse button.
const _programFieldGlyphs = 12;

/// The width of [text] in [style] at the current text scale.
double _textWidth(BuildContext context, String text, TextStyle? style) =>
    measureTextLine(context, text, style).width;
