// ACP hosting: the agent grid, the OpenCode preset and custom agents,
// verbatim argument vectors, saved agents, host details, restore planning,
// preference compatibility, and phone/tablet/desktop layouts in both themes.

import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/host_restore.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/local_host_dialog.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';

import 'fake_bridge_api.dart';

/// A file picker whose single-file pick waits for [gate].
class _GatedPicker extends fsel.FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _GatedPicker(this.path);

  final String path;
  final Completer<void> gate = Completer<void>();
  bool opened = false;

  @override
  Future<fsel.XFile?> openFile({
    List<fsel.XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    opened = true;
    await gate.future;
    return fsel.XFile(path);
  }
}

/// A preference store over [saved] in memory, whose initial load waits for
/// [gate] when given. Records what it writes.
class _HeldPrefs extends UiPrefsStore {
  _HeldPrefs(this.saved, [this.gate]);

  final UiPrefs saved;
  final Completer<void>? gate;
  final List<UiPrefs> written = [];

  @override
  Future<UiPrefs> load() async {
    await gate?.future;
    return saved;
  }

  @override
  Future<void> save(UiPrefs prefs) async => written.add(prefs);
}

Future<ProviderContainer> _pumpDialog(
  WidgetTester t,
  FakeBridgeApi api, {
  AppServeStatus? existing,
  Size size = const Size(1280, 900),
  Brightness brightness = Brightness.light,
  _HeldPrefs? prefs,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final container = ProviderContainer(
    overrides: [
      bridgeApiProvider.overrideWithValue(api),
      if (prefs != null) uiPrefsProvider.overrideWith(() => prefs),
    ],
  );
  addTearDown(container.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        theme: ThemeData(brightness: brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => LocalHostDialog(existing: existing),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return container;
}

/// Unfold the "Advanced" disclosure [key]. The toggle spans the form's
/// width with its button at the start, so the button itself is revealed and
/// tapped (the toggle's centre is empty space), and the unfolded state is
/// asserted.
Future<void> _openAdvanced(WidgetTester t, String key) async {
  final button = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(TextButton),
  );
  expect(button, findsOneWidget);
  await t.ensureVisible(button);
  await t.pumpAndSettle();
  await t.tap(button);
  await t.pumpAndSettle();
  expect(
    find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byIcon(Icons.expand_less_rounded),
    ),
    findsOneWidget,
    reason: 'the advanced fields are unfolded',
  );
}

/// Pick the preset tile [id] (OpenCode by default) and unfold its program
/// and arguments.
Future<void> _chooseAcp(WidgetTester t, [String id = 'opencode']) async {
  final tile = find.byKey(Key('agent-choice-preset:$id'));
  await t.ensureVisible(tile);
  await t.tap(tile);
  await t.pumpAndSettle();
  // Let the debounced program lookup settle.
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
  // A platform without ACP hosting shows no form, hence no toggle.
  if (find.byKey(const Key('acp-advanced-toggle')).evaluate().isNotEmpty) {
    await _openAdvanced(t, 'acp-advanced-toggle');
  }
}

/// Pick the "custom agent" tile (its program fields start unfolded).
Future<void> _chooseCustom(WidgetTester t) async {
  final tile = find.byKey(const Key('agent-choice-custom'));
  await t.ensureVisible(tile);
  await t.tap(tile);
  await t.pumpAndSettle();
}

/// Pick the Codex tile.
Future<void> _chooseCodex(WidgetTester t) async {
  final tile = find.byKey(const Key('agent-choice-codex'));
  await t.ensureVisible(tile);
  await t.tap(tile);
  await t.pumpAndSettle();
}

Future<void> _start(WidgetTester t) async {
  await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
  await t.tap(find.byKey(const Key('start-hosting-btn')));
  await t.pumpAndSettle();
}

const _acpHost = AppServeStatus(
  name: 'beta',
  device: 'local',
  alive: true,
  appListenAddr: '127.0.0.1:18200',
  appServiceKey: 'pcx:local:acp:beta',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18201',
  metaServiceKey: 'pcx:local:meta:beta',
  metaRegistered: true,
  codexBinary: '/opt/agents/beta agent',
  provider: 'acp',
  protocol: 'acp',
  providerName: 'Beta agent',
  profileId: 'custom-beta',
  agentPhase: 'failed',
  agentError: 'the agent exited',
  authRequired: true,
);

void main() {
  testWidgets('the OpenCode preset hosts `opencode` with argv [acp]', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final c = await _pumpDialog(t, api);
    // One tile per agent, each with its own mark; Codex is preselected.
    expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-choice-preset:opencode')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-choice-custom')), findsOneWidget);
    expect(find.byKey(const Key('agent-icon-opencode')), findsOneWidget);
    await _chooseAcp(t);
    expect(find.byKey(const Key('acp-host-form')), findsOneWidget);
    final program = t.widget<TextField>(
      find.byKey(const Key('acp-program-field')),
    );
    expect(program.controller!.text, 'opencode');
    expect(find.byKey(const Key('acp-program-found')), findsOneWidget);
    final arg = t.widget<TextField>(find.byKey(const Key('acp-arg-field-0')));
    expect(arg.controller!.text, 'acp');
    // Codex-only fields are not part of an ACP host.
    expect(find.byKey(const Key('use-proxy-switch')), findsNothing);
    expect(find.byKey(const Key('codex-path-field')), findsNothing);
    await _start(t);
    expect(api.acpServeCalls, hasLength(1));
    final (name, spec) = api.acpServeCalls.single;
    expect(name, 'opencode');
    expect(spec.profileId, 'opencode');
    expect(spec.program, 'opencode');
    expect(spec.args, ['acp']);
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.autoHostAcp.single.name, 'opencode');
    expect(prefs.acpAgents, isEmpty, reason: 'presets are not saved');
  });

  testWidgets('agent chooser shows OpenCode, Claude adapter, saved long names '
      'and Custom, wrapping safely at 320px with reachable Start', (t) async {
    final api = FakeBridgeApi();
    api.presets = const [
      AcpPreset(
        id: 'opencode',
        displayName: 'OpenCode',
        program: 'opencode',
        args: ['acp'],
      ),
      AcpPreset(
        id: 'claude',
        displayName: 'Claude',
        program: 'claude-agent-acp',
        args: [],
      ),
    ];
    api.acpPrograms['claude-agent-acp'] = '/usr/local/bin/claude-agent-acp';
    const longAgent = AcpAgentSpec(
      profileId: 'custom-enterprise-agent',
      displayName: 'Internal Enterprise Security & Code Audit Agent',
      program: '/opt/agents/audit-runner',
      args: ['--audit'],
    );
    final c = await _pumpDialog(
      t,
      api,
      size: const Size(320, 640),
      prefs: _HeldPrefs(const UiPrefs(acpAgents: [longAgent])),
    );
    expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-choice-preset:opencode')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-choice-preset:claude')), findsOneWidget);
    expect(find.byKey(const Key('agent-icon-claude')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-choice-saved:custom-enterprise-agent')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-choice-custom')), findsOneWidget);

    // The program and arguments sit behind Advanced, as for OpenCode.
    await _chooseAcp(t, 'claude');
    expect(find.byKey(const Key('acp-host-form')), findsOneWidget);
    final program = t.widget<TextField>(
      find.byKey(const Key('acp-program-field')),
    );
    expect(program.controller!.text, 'claude-agent-acp');
    expect(find.byKey(const Key('acp-program-found')), findsOneWidget);
    expect(find.byKey(const Key('acp-arg-field-0')), findsNothing);

    await _start(t);

    expect(api.acpServeCalls, hasLength(1));
    final (name, spec) = api.acpServeCalls.single;
    expect(name, 'claude');
    expect(spec.profileId, 'claude');
    expect(spec.program, 'claude-agent-acp');
    expect(spec.args, isEmpty);
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.autoHostAcp.single.name, 'claude');
  });

  testWidgets('custom agents keep every argument verbatim and are saved', (
    t,
  ) async {
    final api = FakeBridgeApi()..acpPrograms['my-agent'] = '/usr/bin/my-agent';
    final c = await _pumpDialog(t, api);
    await _chooseCustom(t);
    await t.enterText(
      find.byKey(const Key('acp-display-name-field')),
      'My Agent',
    );
    await t.enterText(
      find.byKey(const Key('acp-program-field')),
      '/Applications/My Agent.app/bin/agent',
    );
    for (final value in ['--flag=a b', r'$HOME;*', '']) {
      await t.ensureVisible(find.byKey(const Key('acp-arg-add')));
      await t.tap(find.byKey(const Key('acp-arg-add')));
      await t.pumpAndSettle();
      final index = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('acp-arg-field-'),
          )
          .evaluate()
          .length;
      await t.enterText(find.byKey(Key('acp-arg-field-${index - 1}')), value);
      await t.pump();
    }
    // Reorder: move the last (empty) argument above the second.
    await t.ensureVisible(find.byKey(const Key('acp-arg-up-2')));
    await t.tap(find.byKey(const Key('acp-arg-up-2')));
    await t.pumpAndSettle();
    await _start(t);
    final (_, spec) = api.acpServeCalls.single;
    expect(spec.program, '/Applications/My Agent.app/bin/agent');
    expect(spec.args, ['--flag=a b', '', r'$HOME;*']);
    expect(spec.profileId, matches(RegExp(r'^custom-my-agent-[0-9a-f]{8}$')));
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.acpAgents.single, spec);
    expect(prefs.autoHostAcp.single.spec, spec);
  });

  testWidgets('a platform without ACP hosting says so', (t) async {
    final api = FakeBridgeApi()..acpHosting = false;
    await _pumpDialog(t, api);
    await _chooseAcp(t);
    expect(find.byKey(const Key('acp-hosting-unsupported')), findsOneWidget);
    expect(find.byKey(const Key('acp-program-field')), findsNothing);
  });

  testWidgets(
    'host details show failure, sign-in and restart; stop forgets it',
    (t) async {
      final api = FakeBridgeApi()..serveHosts.add(_acpHost);
      final c = await _pumpDialog(t, api, existing: _acpHost);
      c
          .read(uiPrefsProvider.notifier)
          .setAutoHostAcp(
            const AutoHostAcpPrefs(
              name: 'beta',
              spec: AcpAgentSpec(
                profileId: 'custom-beta',
                displayName: 'Beta agent',
                program: '/opt/agents/beta agent',
              ),
            ),
          );
      expect(find.text('Not running'), findsOneWidget);
      expect(find.text('the agent exited'), findsOneWidget);
      expect(find.byKey(const Key('acp-auth-required')), findsOneWidget);
      expect(find.byKey(const Key('acp-features-unknown')), findsOneWidget);
      expect(find.byKey(const Key('provider-badge-acp-tag')), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('acp-restart')));
      await t.tap(find.byKey(const Key('acp-restart')));
      await t.pumpAndSettle();
      expect(api.acpRestartCalls, ['beta']);
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
      final prefs = await c.read(uiPrefsProvider.future);
      expect(prefs.autoHostAcp, isEmpty);
      expect(api.serveHosts, isEmpty);
    },
  );

  testWidgets('host details tell a full, a bounded and a failed model '
      'listing apart, and say when the catalog is unavailable', (t) async {
    const listed = AppServeStatus(
      name: 'opencode',
      device: 'local',
      alive: true,
      appServiceKey: 'pcx:local:acp:opencode',
      provider: 'acp',
      protocol: 'acp',
      providerName: 'OpenCode',
      profileId: 'opencode',
      agentPhase: 'ready',
      catalog: AcpCatalogStatus(
        state: 'reported',
        plugin: 'file:///state/opencode/model-catalog-v1.mjs',
        providers: [
          AcpCatalogProvider(
            id: 'gw',
            status: 'complete',
            listed: 83,
            added: 81,
            excluded: 0,
            unsafeIds: 0,
            keySource: 'config',
          ),
          AcpCatalogProvider(
            id: 'big',
            status: 'partial',
            reason: 'model-limit',
            listed: 2000,
            added: 2000,
            excluded: 3,
            unsafeIds: 1,
            keySource: 'env',
          ),
          AcpCatalogProvider(
            id: 'declared',
            status: 'partial',
            reason: 'unsafe-id',
            listed: 5,
            added: 4,
            excluded: 0,
            unsafeIds: 2,
            keySource: 'config',
          ),
          AcpCatalogProvider(
            id: 'locked',
            status: 'failed',
            reason: 'http-401',
            listed: 0,
            added: 0,
            excluded: 0,
            unsafeIds: 0,
            keySource: 'none',
          ),
          AcpCatalogProvider(
            id: 'headed',
            status: 'failed',
            reason: 'http-403',
            listed: 0,
            added: 0,
            excluded: 0,
            unsafeIds: 0,
            keySource: 'headers',
          ),
        ],
      ),
    );
    final api = FakeBridgeApi()..serveHosts.add(listed);
    await _pumpDialog(t, api, existing: listed);
    String line(String id) =>
        t.widget<Text>(find.byKey(Key('acp-catalog-$id'))).data!;
    expect(line('gw'), 'gw: 83 models listed, 81 added');
    expect(
      line('big'),
      'big: 2000 models listed, 2000 added; '
      'the listing is incomplete (model-limit)',
    );
    // A declared model counts as listed but not added.
    expect(
      line('declared'),
      'declared: 5 models listed, 4 added; '
      'the listing is incomplete (unsafe-id)',
    );
    expect(line('locked'), contains('could not be read (http-401)'));
    expect(line('headed'), contains('could not be read (http-403)'));
    expect(find.text('3 non-chat entries left out'), findsOneWidget);
    expect(find.textContaining('cannot hold their ids'), findsNWidgets(2));
    // Only the provider with no credential at all gets the no-key hint;
    // configured headers are a credential source.
    expect(find.textContaining('agent\'s own sign-in'), findsOneWidget);
    // The plugin location is only for adding it by hand.
    expect(find.textContaining('model-catalog-v1.mjs'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a report with no listable provider says so', (t) async {
    const none = AppServeStatus(
      name: 'opencode',
      device: 'local',
      alive: true,
      appServiceKey: 'pcx:local:acp:opencode',
      provider: 'acp',
      protocol: 'acp',
      providerName: 'OpenCode',
      profileId: 'opencode',
      agentPhase: 'ready',
      catalog: AcpCatalogStatus(
        state: 'reported',
        plugin: 'file:///state/opencode/model-catalog-v1.mjs',
      ),
    );
    final api = FakeBridgeApi()..serveHosts.add(none);
    await _pumpDialog(t, api, existing: none);
    expect(
      t.widget<Text>(find.byKey(const Key('acp-catalog-none'))).data,
      contains('No enabled provider with an explicit baseURL'),
    );
    expect(find.textContaining('model-catalog-v1.mjs'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('an unavailable catalog says why and offers the plugin', (
    t,
  ) async {
    const taken = AppServeStatus(
      name: 'opencode',
      device: 'local',
      alive: true,
      appServiceKey: 'pcx:local:acp:opencode',
      provider: 'acp',
      protocol: 'acp',
      providerName: 'OpenCode',
      profileId: 'opencode',
      agentPhase: 'ready',
      catalog: AcpCatalogStatus(
        state: 'unavailable',
        reason: 'config-env-taken',
        plugin: 'file:///state/opencode/model-catalog-v1.mjs',
      ),
    );
    final api = FakeBridgeApi()..serveHosts.add(taken);
    await _pumpDialog(t, api, existing: taken);
    expect(
      find.textContaining('OPENCODE_CONFIG and OPENCODE_CONFIG_CONTENT'),
      findsOneWidget,
    );
    expect(find.textContaining('model-catalog-v1.mjs'), findsOneWidget);
    // Codex and other agents have no catalog section.
    await t.pumpWidget(const SizedBox());
    final other = FakeBridgeApi()..serveHosts.add(_acpHost);
    await _pumpDialog(t, other, existing: _acpHost);
    expect(find.byKey(const Key('acp-catalog')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  for (final (device, size) in [
    ('phone', const Size(320, 640)),
    ('tablet', const Size(800, 1100)),
    ('desktop', const Size(1440, 900)),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('ACP form lays out on $device (${brightness.name})', (
        t,
      ) async {
        final api = FakeBridgeApi();
        await _pumpDialog(t, api, size: size, brightness: brightness);
        await _chooseAcp(t);
        expect(t.takeException(), isNull);
        expect(find.byKey(const Key('acp-arg-field-0')), findsOneWidget);
        // Reordering buttons only where the row stays wide enough to read.
        expect(
          find.byKey(const Key('acp-arg-up-0')),
          device == 'phone' ? findsNothing : findsOneWidget,
        );
        // The argument's label is whole at every width; where the row's
        // buttons would cut it they move under the field and stay usable.
        final arg = find.byKey(const Key('acp-arg-field-0'));
        final argLabel = AppLocalizations.of(
          t.element(arg),
        ).acpArgumentLabel(1);
        final paragraph = t.renderObject<RenderParagraph>(
          find.descendant(of: arg, matching: find.text(argLabel)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'label is cut');
        await t.ensureVisible(find.byKey(const Key('acp-arg-remove-0')));
        await t.pumpAndSettle();
        expect(
          find.byKey(const Key('acp-arg-remove-0')).hitTestable(),
          findsOneWidget,
        );
        // Touch targets stay at least 48 dp tall.
        final remove = t.getSize(find.byKey(const Key('acp-arg-remove-0')));
        expect(remove.height, greaterThanOrEqualTo(48));
        final tile = t.getSize(
          find.byKey(const Key('agent-choice-preset:opencode')),
        );
        expect(tile.height, greaterThanOrEqualTo(48));
      });
    }
  }

  test('restore plans by what hosts are, never by what they are not', () {
    const acpSpec = AcpAgentSpec(
      profileId: 'opencode',
      displayName: 'OpenCode',
      program: 'opencode',
      args: ['acp'],
    );
    const prefs = UiPrefs(
      autoHostCodex: [AutoHostPrefs(port: 0, name: 'default')],
      autoHostAcp: [
        AutoHostAcpPrefs(name: 'agent', spec: acpSpec),
        AutoHostAcpPrefs(name: 'other', spec: acpSpec),
      ],
    );
    // A running ACP host is not "a Codex host": Codex must still restore.
    final plan = planHostRestore(
      prefs,
      [_acpHost.copyForTest(name: 'agent')],
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(plan.codex.map((h) => h.name), ['default']);
    expect(plan.acp.map((a) => a.name), ['other']);
    final attempted = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {'default'},
      acpAttempted: const {'agent', 'other'},
      acpSupported: true,
    );
    expect(attempted.isEmpty, isTrue);
    final unsupported = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {'default'},
      acpAttempted: const {},
      acpSupported: false,
    );
    expect(unsupported.acp, isEmpty);
  });

  test('restore runs every planned ACP host with its saved argv', () async {
    final api = FakeBridgeApi();
    const spec = AcpAgentSpec(
      profileId: 'custom-x',
      displayName: 'X',
      program: '/bin/x',
      args: ['a b', ''],
    );
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        acp: [AutoHostAcpPrefs(name: 'x', spec: spec)],
      ),
    );
    expect(restored, isTrue);
    expect(api.acpServeCalls.single.$2.args, ['a b', '']);
  });

  test('preferences grow compatibly and drop malformed ACP records', () {
    final old = UiPrefs.fromJson({
      'autoHost': {'name': 'default', 'port': 0},
    });
    expect(old.acpAgents, isEmpty);
    expect(old.autoHostAcp, isEmpty);
    expect(old.toJson().containsKey('acpAgents'), isFalse);
    final parsed = UiPrefs.fromJson({
      'acpAgents': [
        {
          'profileId': 'custom-a',
          'displayName': 'A',
          'program': '/bin/a',
          'args': ['x', ''],
        },
        {'profileId': 'broken'},
        'garbage',
      ],
      'autoHostAcp': [
        {
          'name': 'a',
          'spec': {
            'profileId': 'custom-a',
            'displayName': 'A',
            'program': '/bin/a',
            'args': <String>[],
          },
        },
        {'name': '', 'spec': null},
      ],
    });
    expect(parsed.acpAgents.single.args, ['x', '']);
    expect(parsed.autoHostAcp.single.name, 'a');
    final again = UiPrefs.fromJson(parsed.toJson());
    expect(again.acpAgents.single, parsed.acpAgents.single);
  });

  test('a single legacy Codex record migrates to the per-instance list', () {
    final legacy = UiPrefs.fromJson({
      'autoHost': {'name': 'work', 'port': 18081, 'proxy': 'http://p:1'},
    });
    expect(legacy.autoHostCodex.single.name, 'work');
    expect(legacy.autoHost?.port, 18081);
    // Written back, the first record stays under the legacy key too, so an
    // older build still restores one host.
    final json = legacy.toJson();
    expect((json['autoHost'] as Map)['name'], 'work');
    expect((json['autoHostCodex'] as List).single['name'], 'work');
    // The list wins over the legacy key; duplicate names keep the first.
    final both = UiPrefs.fromJson({
      'autoHost': {'name': 'stale', 'port': 1},
      'autoHostCodex': [
        {'name': 'a', 'port': 0},
        {'name': 'b', 'port': 18081},
        {'name': 'a', 'port': 9},
        'garbage',
      ],
    });
    expect(both.autoHostCodex.map((h) => (h.name, h.port)), [
      ('a', 0),
      ('b', 18081),
    ]);
    expect(UiPrefs.fromJson(const {}).autoHostCodex, isEmpty);
  });

  test('every saved Codex host restores once, skipping names in use', () {
    const prefs = UiPrefs(
      autoHostCodex: [
        AutoHostPrefs(port: 0, name: 'default'),
        AutoHostPrefs(port: 0, name: 'work'),
        AutoHostPrefs(port: 0, name: 'beta'),
      ],
    );
    final plan = planHostRestore(
      prefs,
      // `default` already runs; `beta` is held by an ACP host.
      [const AppServeStatus(name: 'default', device: 'local'), _acpHost],
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(plan.codex.map((h) => h.name), ['work']);
    final again = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {'default', 'work', 'beta'},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(again.codex, isEmpty);
  });

  test('restore runs every planned Codex host under its own name', () async {
    final api = FakeBridgeApi();
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        codex: [
          AutoHostPrefs(port: 0, name: 'a'),
          AutoHostPrefs(port: 18081, name: 'b'),
        ],
      ),
    );
    expect(restored, isTrue);
    expect(api.serveHosts.map((h) => h.name), ['a', 'b']);
  });

  testWidgets('agent marks follow the profile, never the host name', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            AgentIcon.of(
              key: const Key('named-opencode'),
              provider: 'acp',
              profileId: 'custom-x',
              name: 'opencode',
            ),
            AgentIcon.of(
              key: const Key('preset'),
              provider: 'acp',
              profileId: 'opencode',
            ),
            AgentIcon.of(key: const Key('codex'), provider: 'codex'),
          ],
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('named-opencode')),
        matching: find.byKey(const Key('agent-icon-letter')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('preset')),
        matching: find.byKey(const Key('agent-icon-opencode')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('codex')),
        matching: find.byKey(const Key('agent-icon-codex')),
      ),
      findsOneWidget,
    );
    expect(agentKindOf(provider: 'acp', profileId: 'claude'), AgentKind.claude);
    expect(agentKindOf(provider: 'acp'), AgentKind.other);
  });

  test('suggested instance names avoid every running host', () {
    expect(uniqueHostName('default', const []), 'default');
    expect(uniqueHostName('default', const ['default']), 'default-2');
    expect(
      uniqueHostName('default', const ['default', 'default-2']),
      'default-3',
    );
  });

  testWidgets('a name another host owns gets localized guidance', (t) async {
    final api = FakeBridgeApi()
      ..acpServeError = StateError(
        '`opencode` is already hosting Codex on this device; choose another name',
      );
    await _pumpDialog(t, api);
    await _chooseAcp(t);
    await _start(t);
    expect(find.textContaining('already online from another'), findsOneWidget);
  });

  test('protocols come from the key kind', () {
    expect(sessionProtocolOf('pcx:mac:acp:agent'), SessionProtocol.acp);
    expect(sessionProtocolOf('pcxu:u:mac:acp:agent'), SessionProtocol.acp);
    expect(
      sessionProtocolOf('pcx:mac:app:acp'),
      SessionProtocol.codexAppServer,
    );
    expect(isSessionKind('acp'), isTrue);
    expect(
      customProfileId('My Agent!', '0a1b2c3d'),
      'custom-my-agent-0a1b2c3d',
    );
    expect(customProfileId('***', '0a1b2c3d'), 'custom-agent-0a1b2c3d');
    // Names in other scripts share a slug; the salt keeps them apart.
    final first = customProfileId('我的智能体', newProfileSalt());
    final second = customProfileId('另一个智能体', newProfileSalt());
    expect(first, startsWith('custom-agent-'));
    expect(first, isNot(second));
    expect(newProfileSalt(), matches(RegExp(r'^[0-9a-f]{8}$')));
  });

  testWidgets('two custom agents with non-Latin names are saved separately', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final c = await _pumpDialog(t, api);
    for (final (index, name) in ['我的智能体', '另一个智能体'].indexed) {
      if (index > 0) {
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
      }
      await _chooseCustom(t);
      await t.enterText(find.byKey(const Key('acp-display-name-field')), name);
      await t.enterText(
        find.byKey(const Key('acp-instance-name-field')),
        'agent-$index',
      );
      await t.enterText(
        find.byKey(const Key('acp-program-field')),
        '/opt/agents/agent-$index',
      );
      await _start(t);
    }
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.acpAgents.map((a) => a.displayName), ['我的智能体', '另一个智能体']);
    expect(prefs.acpAgents.map((a) => a.profileId).toSet(), hasLength(2));
  });

  test('native Codex capability values are unchanged and ACP starts empty', () {
    expect(AppCapabilities.codex.voice, isTrue);
    expect(AppCapabilities.codex.nativeMetadata, isTrue);
    const acp = AppCapabilities.acp;
    expect(acp.negotiated, isFalse);
    expect([
      acp.voice,
      acp.dictation,
      acp.imageInput,
      acp.steer,
      acp.modelCatalog,
    ], everyElement(isFalse));
    expect(acp.permissionOptions, isTrue);
  });

  testWidgets('the ACP badge names the agent and tags the protocol', (t) async {
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(
          body: Row(
            children: [
              ProviderBadge(provider: 'acp', name: 'Beta agent'),
              ProviderBadge(provider: 'codex'),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Beta agent'), findsOneWidget);
    expect(find.text('ACP'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
  });

  group('async lookups and names', () {
    testWidgets('an old lookup finishing late does not mark the new agent '
        'found', (t) async {
      final api = FakeBridgeApi();
      // OpenCode's lookup hangs; the user switches to a custom agent.
      final slow = Completer<void>();
      api.acpLocateGates['opencode'] = slow;
      await _pumpDialog(t, api);
      await t.tap(find.byKey(const Key('agent-choice-preset:opencode')));
      await t.pump(const Duration(milliseconds: 400));
      await _chooseCustom(t);
      await t.enterText(
        find.byKey(const Key('acp-program-field')),
        'missing-agent',
      );
      // The new lookup has not fired yet (debounce) when the old one ends.
      await t.pump(const Duration(milliseconds: 100));
      slow.complete();
      await t.pump();
      expect(find.byKey(const Key('acp-program-found')), findsNothing);
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('acp-program-missing')), findsOneWidget);
    });

    testWidgets('a failed lookup is shown with a retry that settles', (
      t,
    ) async {
      final api = FakeBridgeApi()..acpLocateFailures.add('opencode');
      await _pumpDialog(t, api);
      await _chooseAcp(t);
      expect(
        find.byKey(const Key('acp-program-locate-failed')),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await t.tap(find.byKey(const Key('acp-program-locate-retry')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('acp-program-locate-failed')), findsNothing);
      expect(find.byKey(const Key('acp-program-found')), findsOneWidget);
    });

    testWidgets('a file picked after switching agent is dropped', (t) async {
      final picker = _GatedPicker('/opt/agents/picked');
      final previous = fsel.FileSelectorPlatform.instance;
      fsel.FileSelectorPlatform.instance = picker;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      final api = FakeBridgeApi();
      await _pumpDialog(t, api);
      await _chooseCustom(t);
      await t.tap(find.byKey(const Key('acp-program-browse')));
      await t.pump();
      expect(picker.opened, isTrue);
      await _chooseAcp(t);
      picker.gate.complete();
      await t.pumpAndSettle();
      final program = t.widget<TextField>(
        find.byKey(const Key('acp-program-field')),
      );
      expect(program.controller!.text, 'opencode');
    });

    testWidgets('a suggested name moves off hosts that load later; a typed '
        'one stays', (t) async {
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api);
      await _chooseAcp(t);
      TextField name() =>
          t.widget(find.byKey(const Key('acp-instance-name-field')));
      expect(name().controller!.text, 'opencode');
      // A host named `opencode` turns up (status loaded late).
      await api.appServeStartAcp(
        name: 'opencode',
        spec: const AcpAgentSpec(
          profileId: 'opencode',
          displayName: 'OpenCode',
          program: 'opencode',
          args: ['acp'],
        ),
      );
      c.invalidate(localServeListProvider);
      await t.pumpAndSettle();
      expect(name().controller!.text, 'opencode-2');
      await t.enterText(
        find.byKey(const Key('acp-instance-name-field')),
        'mine',
      );
      await api.appServeStartAcp(
        name: 'other',
        spec: const AcpAgentSpec(
          profileId: 'x',
          displayName: 'X',
          program: 'x',
        ),
      );
      c.invalidate(localServeListProvider);
      await t.pumpAndSettle();
      expect(name().controller!.text, 'mine');
    });
  });

  group('restore records decided on the loaded file', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final full = [
      for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
        AutoHostPrefs(port: 0, name: 'h$i'),
    ];

    testWidgets('a Codex host started while a full file is still loading '
        'says it will not be restored, and keeps every record', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(UiPrefs(autoHostCodex: full), gate);
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _start(t);
      expect(api.lastServeName, 'default', reason: 'hosting started');
      expect(find.byType(LocalHostDialog), findsNothing);
      // The interim snapshot looks empty; no verdict yet, so no notice.
      expect(find.text(en.hostRestoreFull(UiPrefs.maxAutoHosts)), findsNothing);
      gate.complete();
      await t.pumpAndSettle();
      expect(
        find.text(en.hostRestoreFull(UiPrefs.maxAutoHosts)),
        findsOneWidget,
      );
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(settled.autoHostCodex.map((h) => h.name), [
        for (final h in full) h.name,
      ]);
      await c.read(uiPrefsProvider.notifier).debugWritesDone;
      expect(prefs.written.last.autoHostCodex.map((h) => h.name), [
        for (final h in full) h.name,
      ]);
    });

    testWidgets('with room in the loading file the record is stored without '
        'a notice', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(UiPrefs(autoHostCodex: full.sublist(1)), gate);
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _start(t);
      gate.complete();
      await t.pumpAndSettle();
      expect(find.text(en.hostRestoreFull(UiPrefs.maxAutoHosts)), findsNothing);
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(settled.autoHostCodex.map((h) => h.name), [
        for (final h in full.sublist(1)) h.name,
        'default',
      ]);
    });

    testWidgets('an ACP host and a custom agent refused by a full file are '
        'reported and not shown as saved', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(
        UiPrefs(
          autoHostAcp: [
            for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
              AutoHostAcpPrefs(
                name: 'x$i',
                spec: AcpAgentSpec(
                  profileId: 'custom-x$i',
                  displayName: 'X$i',
                  program: '/opt/agents/x$i',
                ),
              ),
          ],
          acpAgents: [
            for (var i = 0; i < UiPrefs.maxSavedAgents; i++)
              AcpAgentSpec(
                profileId: 'custom-s$i',
                displayName: 'S$i',
                program: '/opt/agents/s$i',
              ),
          ],
        ),
        gate,
      );
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _chooseCustom(t);
      await t.enterText(
        find.byKey(const Key('acp-display-name-field')),
        'Fresh',
      );
      await t.enterText(
        find.byKey(const Key('acp-program-field')),
        '/opt/agents/fresh',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await _start(t);
      expect(api.acpServeCalls, hasLength(1), reason: 'hosting started');
      gate.complete();
      await t.pumpAndSettle();
      final notice = find.textContaining(
        en.hostRestoreFull(UiPrefs.maxAutoHosts),
      );
      expect(notice, findsOneWidget);
      expect(
        find.textContaining(en.acpSavedAgentsFull(UiPrefs.maxSavedAgents)),
        findsOneWidget,
      );
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(
        settled.acpAgents.map((a) => a.displayName),
        isNot(contains('Fresh')),
      );
      expect(settled.acpAgents, hasLength(UiPrefs.maxSavedAgents));
      expect(settled.autoHostAcp.map((h) => h.name), isNot(contains('agent')));
      // Reopened, the agent grid offers no saved tile for it.
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'agent-choice-saved:custom-fresh',
              ),
        ),
        findsNothing,
      );
    });
  });

  group('Codex path', () {
    Future<_GatedPicker> picker(String path) async {
      final picker = _GatedPicker(path);
      final previous = fsel.FileSelectorPlatform.instance;
      fsel.FileSelectorPlatform.instance = picker;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
      return picker;
    }

    Future<void> browse(WidgetTester t, _GatedPicker picker) async {
      final button = find.byKey(const Key('browse-codex-btn'));
      await t.ensureVisible(button);
      await t.pumpAndSettle();
      await t.tap(button);
      await t.pump();
      expect(picker.opened, isTrue);
    }

    String path(WidgetTester t) => t
        .widget<TextField>(find.byKey(const Key('codex-path-field')))
        .controller!
        .text;

    testWidgets('a file picked after switching agent is dropped', (t) async {
      final pick = await picker('/opt/picked/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await browse(t, pick);
      await _chooseAcp(t);
      pick.gate.complete();
      await t.pumpAndSettle();
      await _chooseCodex(t);
      expect(path(t), isEmpty);
    });

    testWidgets('a path typed after opening the picker wins', (t) async {
      final pick = await picker('/opt/picked/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await browse(t, pick);
      await t.enterText(
        find.byKey(const Key('codex-path-field')),
        '/opt/typed/codex',
      );
      pick.gate.complete();
      await t.pumpAndSettle();
      expect(path(t), '/opt/typed/codex');
      await _start(t);
      expect(api.lastServeBinary, '/opt/typed/codex');
    });

    testWidgets('a file picked once starting began does not change the '
        'start', (t) async {
      final pick = await picker('/opt/picked/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await t.enterText(
        find.byKey(const Key('codex-path-field')),
        '/opt/typed/codex',
      );
      await browse(t, pick);
      final serving = Completer<void>();
      api.serveStartGate = serving;
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pump();
      pick.gate.complete();
      await t.pump();
      expect(path(t), '/opt/typed/codex');
      serving.complete();
      await t.pumpAndSettle();
      expect(api.lastServeBinary, '/opt/typed/codex');
    });

    testWidgets('a path chosen while detection runs survives it, even when '
        'its text is unchanged', (t) async {
      final pick = await picker('/opt/mine/codex');
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      await t.enterText(
        find.byKey(const Key('codex-path-field')),
        '/opt/mine/codex',
      );
      await browse(t, pick);
      // Re-detect finds a codex on PATH, slowly.
      api.codexPath = '/usr/local/bin/codex';
      final detecting = Completer<void>();
      api.codexLocateGate = detecting;
      await t.tap(find.byKey(const Key('redetect-codex-btn')));
      // Detection shows an indeterminate progress bar: pump bounded frames.
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // The user's pick (the same text) lands during detection.
      pick.gate.complete();
      await t.pump();
      detecting.complete();
      await t.pump();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('customize-codex-btn')), findsNothing);
      expect(path(t), '/opt/mine/codex');
      await _start(t);
      expect(api.lastServeBinary, '/opt/mine/codex');
    });

    testWidgets('an untouched path follows detection', (t) async {
      final api = FakeBridgeApi()..codexPath = null;
      await _pumpDialog(t, api);
      api.codexPath = '/usr/local/bin/codex';
      final detecting = Completer<void>();
      api.codexLocateGate = detecting;
      await t.tap(find.byKey(const Key('redetect-codex-btn')));
      await t.pump();
      detecting.complete();
      await t.pump();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('customize-codex-btn')), findsOneWidget);
      await _start(t);
      expect(api.lastServeBinary, isNull, reason: 'the detected codex');
    });
  });

  group('start follows the chosen tile', () {
    testWidgets('Codex starts the native app-server', (t) async {
      final api = FakeBridgeApi();
      await _pumpDialog(t, api);
      await _start(t);
      expect(api.lastServeName, 'default');
      expect(api.acpServeCalls, isEmpty);
    });

    testWidgets('a preset, a saved agent and a custom agent start ACP', (
      t,
    ) async {
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api);
      c
          .read(uiPrefsProvider.notifier)
          .saveAcpAgent(
            const AcpAgentSpec(
              profileId: 'custom-saved-1',
              displayName: 'Saved',
              program: '/opt/agents/saved',
            ),
          );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('agent-choice-saved:custom-saved-1')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await _start(t);
      expect(api.lastServeName, isNull, reason: 'no Codex start');
      expect(api.acpServeCalls.single.$2.profileId, 'custom-saved-1');
    });
  });

  _lifetimeTests();
  _restartLifetimeTests();
}

extension on AppServeStatus {
  AppServeStatus copyForTest({required String name}) => AppServeStatus(
    name: name,
    device: device,
    alive: alive,
    appServiceKey: 'pcx:local:acp:$name',
    provider: provider,
    protocol: protocol,
    providerName: providerName,
    agentPhase: 'ready',
  );
}

const _openCodeSpec = AcpAgentSpec(
  profileId: 'opencode',
  displayName: 'OpenCode',
  program: 'opencode',
  args: ['acp'],
);

/// The four host operations whose completion can outlive the dialog.
enum _Op { codexStart, acpStart, codexStop, acpStop }

/// The instance each operation acts on.
String _opName(_Op op) => switch (op) {
  _Op.codexStart => 'default',
  _Op.acpStart => 'opencode',
  _Op.codexStop => 'alpha',
  _Op.acpStop => 'beta',
};

bool _isStop(_Op op) => op == _Op.codexStop || op == _Op.acpStop;

/// One operation held at its bridge call: the dialog is open on a live
/// scope that also restores other hosts, and [release] lets the call finish.
class _Held {
  _Held(this.api, this.prefs, this.container, this.gate);

  final FakeBridgeApi api;
  final _HeldPrefs prefs;
  final ProviderContainer container;
  final Completer<void> gate;
  String? stoppedKey;
}

const _otherCodex = AutoHostPrefs(
  port: 18990,
  name: 'other-codex',
  embedded: false,
);
const _otherAcp = AutoHostAcpPrefs(name: 'other-acp', spec: _openCodeSpec);

Future<_Held> _hold(WidgetTester t, _Op op) async {
  final api = FakeBridgeApi();
  if (op == _Op.codexStop) {
    await api.appServeStart(port: 18080, name: 'alpha', embedded: false);
  } else if (op == _Op.acpStop) {
    await api.appServeStartAcp(name: 'beta', spec: _openCodeSpec);
  }
  final prefs = _HeldPrefs(
    UiPrefs(
      autoHostCodex: [
        _otherCodex,
        if (op == _Op.codexStop)
          const AutoHostPrefs(port: 18080, name: 'alpha', embedded: false),
      ],
      autoHostAcp: [
        _otherAcp,
        if (op == _Op.acpStop)
          const AutoHostAcpPrefs(name: 'beta', spec: _openCodeSpec),
      ],
    ),
  );
  final existing = _isStop(op)
      ? api.serveHosts.singleWhere((h) => h.name == _opName(op))
      : null;
  final container = await _pumpDialog(t, api, existing: existing, prefs: prefs);
  await container.read(uiPrefsProvider.future);
  // Keep discovery and the host list observed, so an invalidation refetches.
  container.listen(servicesProvider, (_, _) {});
  container.listen(localServeListProvider, (_, _) {});
  await t.pumpAndSettle();
  final gate = Completer<void>();
  final held = _Held(api, prefs, container, gate)
    ..stoppedKey = existing?.appServiceKey;
  switch (op) {
    case _Op.codexStart:
      api.serveStartGate = gate;
      await _start(t);
    case _Op.acpStart:
      await _chooseAcp(t);
      api.serveStartAcpGate = gate;
      await _start(t);
    case _Op.codexStop || _Op.acpStop:
      api.serveStopGate = gate;
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
  }
  expect(find.byType(LocalHostDialog), findsOneWidget);
  return held;
}

/// The completed bookkeeping in a live scope: this host's record restored
/// or forgotten by name, every other record kept, the host list and
/// discovery refreshed (and, for a stop, its entry hidden at once).
Future<void> _expectRecorded(_Held held, _Op op, int discoveriesBefore) async {
  final c = held.container;
  final name = _opName(op);
  final prefs = c.read(uiPrefsProvider).requireValue;
  final codex = prefs.autoHostCodex.map((h) => h.name).toSet();
  final acp = prefs.autoHostAcp.map((h) => h.name).toSet();
  switch (op) {
    case _Op.codexStart:
      expect(codex, {'other-codex', name});
      expect(acp, {'other-acp'});
    case _Op.acpStart:
      expect(codex, {'other-codex'});
      expect(acp, {'other-acp', name});
    case _Op.codexStop:
      expect(codex, {'other-codex'});
      expect(acp, {'other-acp'});
    case _Op.acpStop:
      expect(codex, {'other-codex'});
      expect(acp, {'other-acp'});
  }
  expect(held.prefs.written, isNotEmpty, reason: 'the change was saved');
  final hosts = (await c.read(
    localServeListProvider.future,
  )).map((h) => h.name).toSet();
  expect(hosts.contains(name), !_isStop(op), reason: 'host list refreshed');
  expect(
    held.api.discoverCalls,
    greaterThan(discoveriesBefore),
    reason: 'discovery refetched',
  );
  if (_isStop(op)) {
    expect(c.read(pendingRemovalProvider), contains(held.stoppedKey));
  }
}

void _lifetimeTests() {
  group('LocalHostDialog operation lifetime', () {
    for (final op in _Op.values) {
      testWidgets('${op.name}: barrier, Escape and system back are refused '
          'while pending; completion records it', (t) async {
        final held = await _hold(t, op);
        await t.tapAt(const Offset(10, 10));
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsOneWidget, reason: 'barrier');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsOneWidget, reason: 'Escape');
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsOneWidget, reason: 'back');

        final discoveries = held.api.discoverCalls;
        held.gate.complete();
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsNothing);
        await _expectRecorded(held, op, discoveries);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('${op.name}: a route removed while pending still records '
          'it in the live scope', (t) async {
        final held = await _hold(t, op);
        // Removal by the app (not a user dismissal) bypasses PopScope.
        Navigator.of(t.element(find.byType(LocalHostDialog))).pop();
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsNothing);

        final discoveries = held.api.discoverCalls;
        held.gate.complete();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await _expectRecorded(held, op, discoveries);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('${op.name}: a scope disposed while pending is never '
          'touched again', (t) async {
        final held = await _hold(t, op);
        // Descendants unmount before their container is disposed.
        await t.pumpWidget(const SizedBox());
        held.container.dispose();
        final writes = held.prefs.written.length;
        final discoveries = held.api.discoverCalls;

        held.gate.complete();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(held.prefs.written.length, writes, reason: 'nothing saved');
        expect(held.api.discoverCalls, discoveries, reason: 'nothing read');
      });
    }
  });
}

/// The ACP details dialog with a restart held at its bridge call.
Future<(FakeBridgeApi, ProviderContainer, Completer<void>)> _holdRestart(
  WidgetTester t,
) async {
  final api = FakeBridgeApi();
  await api.appServeStartAcp(name: 'beta', spec: _openCodeSpec);
  final host = api.serveHosts.single;
  final container = await _pumpDialog(t, api, existing: host);
  container.listen(localServeListProvider, (_, _) {});
  await t.pumpAndSettle();
  final gate = Completer<void>();
  api.acpRestartGate = gate;
  await t.ensureVisible(find.byKey(const Key('acp-restart')));
  await t.tap(find.byKey(const Key('acp-restart')));
  await t.pump();
  expect(api.acpRestartCalls, ['beta']);
  return (api, container, gate);
}

void _restartLifetimeTests() {
  group('AcpHostDetails restart lifetime', () {
    testWidgets('a route closed while a restart is pending still refreshes '
        'the host list', (t) async {
      final (api, _, gate) = await _holdRestart(t);
      Navigator.of(t.element(find.byType(LocalHostDialog))).pop();
      await t.pumpAndSettle();
      expect(find.byType(LocalHostDialog), findsNothing);
      final reads = api.serveStatusCalls;

      gate.complete();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.serveStatusCalls, greaterThan(reads), reason: 'refetched');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a scope disposed while a restart is pending is never '
        'touched again', (t) async {
      final (api, container, gate) = await _holdRestart(t);
      await t.pumpWidget(const SizedBox());
      container.dispose();
      final reads = api.serveStatusCalls;

      gate.complete();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.serveStatusCalls, reads, reason: 'nothing read');
    });

    testWidgets('a refused restart is shown on the open view', (t) async {
      final (api, _, gate) = await _holdRestart(t);
      api.acpRestartError = StateError('agent would not restart');
      gate.complete();
      await t.pumpAndSettle();
      expect(find.textContaining('agent would not restart'), findsOneWidget);
      expect(find.byType(LocalHostDialog), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
