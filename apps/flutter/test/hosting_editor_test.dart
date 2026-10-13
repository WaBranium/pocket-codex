// The hosting editor: one page for new and running hosts. A new host is
// saved and started as one operation; a running host's runtime and model
// service are read first, saved without touching what runs, and applied
// only by an explicit, confirmed restart of exactly the revision shown.
// Only the agent/provider mappings the bridge supports are offered, leaving
// with unsaved edits asks first, and the official sign-in owns its private
// session. Pending UI is driven with completers and finite pumps.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart';
import 'package:pocket_codex/src/hosting/official_login_panel.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/services_screen.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const _codexHost = AppServeStatus(
  name: 'alpha',
  device: 'local',
  pid: 4242,
  alive: true,
  appListenAddr: '127.0.0.1:18080',
  appServiceKey: 'pcx:local:app:alpha',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18090',
  metaServiceKey: 'pcx:local:meta:alpha',
  metaRegistered: true,
  codexBinary: '/usr/local/bin/codex',
  proxy: 'http://127.0.0.1:11111',
  provider: 'codex',
  configSource: 'inherited',
  configRevision: 0,
  incarnation: 'inc-alpha',
);

/// A generic ACP agent with no preset and no restore record.
const _genericAgent = AcpAgentSpec(
  profileId: 'custom-tool-1a2b3c4d',
  displayName: 'Tool',
  program: '/opt/tool/bin/tool-acp',
  args: ['--stdio', '--quiet'],
);

const _acpHost = AppServeStatus(
  name: 'tool',
  device: 'local',
  alive: true,
  appListenAddr: '127.0.0.1:18200',
  appServiceKey: 'pcx:local:acp:tool',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18201',
  metaServiceKey: 'pcx:local:meta:tool',
  metaRegistered: true,
  codexBinary: '/opt/tool/bin/tool-acp',
  provider: 'acp',
  protocol: 'acp',
  providerName: 'Tool',
  profileId: 'custom-tool-1a2b3c4d',
  agentPhase: 'ready',
  configSource: 'inherited',
  configRevision: 0,
  incarnation: 'inc-tool',
);

/// A fake offering the bridge's two built-in ACP presets (OpenCode and the
/// Claude adapter, as `PRESETS` in host-svc's `acp/spec.rs` defines them),
/// with the adapter found where the fake's Claude status reports it. The
/// default fake offers OpenCode only.
FakeBridgeApi _withClaude() => FakeBridgeApi()
  ..presets = const [
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
  ]
  ..acpPrograms['claude-agent-acp'] =
      '/Users/me/.npm-global/bin/claude-agent-acp';

Future<ProviderContainer> _pumpEditor(
  WidgetTester t,
  FakeBridgeApi api, {
  AppServeStatus? existing,
}) async {
  t.view.physicalSize = const Size(1280, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final container = ProviderContainer(
    overrides: [bridgeApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showHostingEditor(context, existing: existing),
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

AppLocalizations _l10n(WidgetTester t) =>
    AppLocalizations.of(t.element(find.byType(HostingEditor)));

AppLocalizations _l10nOf(WidgetTester t) =>
    AppLocalizations.of(t.element(find.byType(Scaffold).first));

Future<void> _tapKey(WidgetTester t, String key) async {
  final target = find.byKey(Key(key));
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

/// Tap without settling: for a sign-in whose spinner keeps animating.
Future<void> _tapKeyPumped(WidgetTester t, String key) async {
  final target = find.byKey(Key(key));
  await t.ensureVisible(target);
  await t.pump();
  await t.tap(target);
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Open an Advanced disclosure through its button: the toggle spans the
/// form's width with the button at its start, so its centre is no target.
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
}

Future<void> _enter(WidgetTester t, String key, String text) async {
  final field = find.byKey(Key(key));
  await t.ensureVisible(field);
  await t.enterText(field, text);
  await t.pumpAndSettle();
}

Future<void> _choosePreset(WidgetTester t, String id) async {
  await _tapKey(t, 'agent-choice-preset:$id');
  // Let the debounced program lookup settle.
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
}

VoidCallback? _onPressed(WidgetTester t, String key) {
  final widget = t.widget(find.byKey(Key(key)));
  return switch (widget) {
    final ButtonStyleButton b => b.onPressed,
    _ => throw StateError('$key is not a button'),
  };
}

/// Answer url_launcher's platform channel so a sign-in can open its page.
void _mockLauncher(WidgetTester t) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => true,
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}

void main() {
  _newHostTests();
  _runningHostTests();
  _navigationTests();
  _entryTests();
  _signInTests();
}

void _newHostTests() {
  testWidgets('a new Codex host is saved and started as one operation', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);

    // Codex offers all three sources and only the Responses API.
    for (final source in ['inherited', 'official', 'custom']) {
      expect(find.byKey(Key('host-source-$source')), findsOneWidget);
    }
    await _tapKey(t, 'host-source-custom');
    expect(find.byKey(const Key('host-protocol-responses')), findsOneWidget);
    expect(
      find.byKey(const Key('host-protocol-anthropic-messages')),
      findsNothing,
    );
    await _enter(t, 'host-base-url', ' https://models.example/v1 ');
    await _enter(t, 'host-api-key', 'sk-test');
    await _enter(t, 'host-model', 'gpt-test');
    await _tapKey(t, 'start-hosting-btn');

    expect(api.hostConfigSaves, isEmpty, reason: 'no separate pre-save');
    final (name, runtime, input, action, key) = api.startConfiguredCalls.single;
    expect(name, 'default');
    expect(runtime.isCodex, isTrue);
    expect(runtime.port, 18080);
    expect(runtime.proxy, 'http://127.0.0.1:11111');
    // A detected codex is left to the bridge to resolve.
    expect(runtime.binary, isNull);
    expect(input.source, 'custom');
    expect(input.protocol, 'responses');
    expect(input.baseUrl, 'https://models.example/v1');
    expect(input.model, 'gpt-test');
    expect(action, HostKeyAction.replace);
    expect(key, 'sk-test');
    expect(api.serveHosts, hasLength(1));
    expect(find.byType(HostingEditor), findsNothing);
  });

  testWidgets('a failed start keeps the page and no new configuration', (
    t,
  ) async {
    final api = FakeBridgeApi()
      ..hostConfigs['default'] = const HostConfig(source: 'official');
    api.serveHosts.add(_codexHost.copyName('default'));
    await _pumpEditor(t, api);
    // The suggested name avoids the running host, so force the clash.
    await _enter(t, 'codex-name-field', 'default');
    await _tapKey(t, 'start-hosting-btn');

    expect(find.text(_l10n(t).hostNameConflict), findsOneWidget);
    expect(find.byType(HostingEditor), findsOneWidget);
    expect(api.hostConfigs['default']!.source, 'official', reason: 'kept');
  });

  testWidgets('a new host with the existing configuration drops a stale key', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    expect(find.byKey(const Key('host-inherited-status')), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');

    final (_, _, input, action, key) = api.startConfiguredCalls.single;
    expect(input.source, 'inherited');
    expect(input.baseUrl, isNull);
    // A key left by an earlier host of the same name is never inherited.
    expect(action, HostKeyAction.remove);
    expect(key, isNull);
  });

  testWidgets('a typed key is not sent once the source leaves custom', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    await _enter(t, 'host-api-key', 'sk-test');
    await _tapKey(t, 'host-source-inherited');
    await _tapKey(t, 'start-hosting-btn');

    final (_, _, input, action, key) = api.startConfiguredCalls.single;
    expect(input.source, 'inherited');
    expect(action, HostKeyAction.remove);
    expect(key, isNull);
  });

  testWidgets('required provider fields are named before anything starts', (
    t,
  ) async {
    final api = _withClaude();
    await _pumpEditor(t, api);
    final l10n = _l10n(t);
    await _tapKey(t, 'host-source-custom');
    expect(find.text(l10n.hostBaseUrlRequired), findsOneWidget);

    // OpenCode needs a default model, or the user's own one stays active.
    await _choosePreset(t, 'opencode');
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    expect(find.text(l10n.hostModelRequired), findsOneWidget);

    // Claude needs a key, or its own sign-in would reach the gateway.
    await _choosePreset(t, 'claude');
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example');
    expect(find.text(l10n.hostKeyRequired), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');
    expect(api.startConfiguredCalls, isEmpty);
  });

  testWidgets('each agent offers only its real provider APIs', (t) async {
    final api = _withClaude();
    await _pumpEditor(t, api);

    await _choosePreset(t, 'claude');
    expect(find.byKey(const Key('host-source-official')), findsNothing);
    await _tapKey(t, 'host-source-custom');
    expect(
      find.byKey(const Key('host-protocol-anthropic-messages')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('host-protocol-responses')), findsNothing);

    await _choosePreset(t, 'opencode');
    await _tapKey(t, 'host-source-custom');
    for (final protocol in [
      'responses',
      'anthropic-messages',
      'chat-completions',
    ]) {
      expect(find.byKey(Key('host-protocol-$protocol')), findsOneWidget);
    }

    await _tapKey(t, 'agent-choice-custom');
    expect(find.byKey(const Key('host-source-inherited')), findsOneWidget);
    expect(find.byKey(const Key('host-source-custom')), findsNothing);
    expect(find.text(_l10n(t).hostInheritedOnly), findsOneWidget);
  });

  testWidgets('each agent choice keeps its own model-service draft', (t) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://codex.example/v1');
    await _enter(t, 'host-api-key', 'sk-codex');

    // Another agent starts from its own (inherited) draft: nothing carries.
    await _choosePreset(t, 'opencode');
    expect(find.byKey(const Key('host-base-url')), findsNothing);
    expect(find.byKey(const Key('host-inherited-status')), findsNothing);

    // Back to Codex: its draft is still there.
    await _tapKey(t, 'agent-choice-codex');
    expect(find.text('https://codex.example/v1'), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');
    final (_, _, input, _, key) = api.startConfiguredCalls.single;
    expect(input.baseUrl, 'https://codex.example/v1');
    expect(key, 'sk-codex');
  });

  testWidgets('switching agents and back keeps each agent form', (t) async {
    final api = _withClaude();
    await _pumpEditor(t, api);
    await _choosePreset(t, 'opencode');
    await _openAdvanced(t, 'acp-advanced-toggle');
    await _enter(t, 'acp-program-field', '/opt/opencode/custom');

    await _choosePreset(t, 'claude');
    expect(find.text('/opt/opencode/custom'), findsNothing);
    await _tapKey(t, 'agent-choice-preset:opencode');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();

    // A preset reopens with Advanced closed; the restored program (not the
    // preset's `opencode` default) is what its field holds once shown.
    await _openAdvanced(t, 'acp-advanced-toggle');
    expect(
      t
          .widget<TextField>(find.byKey(const Key('acp-program-field')))
          .controller!
          .text,
      '/opt/opencode/custom',
    );
    await _tapKey(t, 'start-hosting-btn');
    expect(
      api.startConfiguredCalls.single.$2.agent!.program,
      '/opt/opencode/custom',
    );
  });

  testWidgets('a typed instance name or the save toggle alone is an edit, '
      'kept on a choice switched away from', (t) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _choosePreset(t, 'opencode');
    await _enter(t, 'acp-instance-name-field', 'my-opencode');
    // Another agent is shown; the edited one is not.
    await _tapKey(t, 'agent-choice-codex');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-stay');
    expect(find.byType(HostingEditor), findsOneWidget);
    // Switching back restores the typed name.
    await _choosePreset(t, 'opencode');
    expect(find.text('my-opencode'), findsOneWidget);
    // Leave this editor (discarding its edits), then take the whole tree
    // down: the next mount gets a new navigator, not this one's routes.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await _tapKey(t, 'host-leave-discard');
    expect(find.byType(HostingEditor), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();

    // The save toggle of a custom agent, on its own, asks too.
    final fresh = FakeBridgeApi();
    await _pumpEditor(t, fresh);
    await _tapKey(t, 'agent-choice-custom');
    await _openAdvanced(t, 'acp-advanced-toggle');
    await _tapKey(t, 'acp-save-agent');
    await _tapKey(t, 'agent-choice-codex');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-discard');
    expect(find.byType(HostingEditor), findsNothing);
  });

  testWidgets('the api:<name> service is explained as official-only', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    expect(find.text(_l10n(t).hostApiProxyNote), findsOneWidget);
    await _choosePreset(t, 'opencode');
    expect(find.text(_l10n(t).hostApiProxyNote), findsNothing);
  });
}

void _runningHostTests() {
  testWidgets('nothing is editable until the saved configuration is read', (
    t,
  ) async {
    final gate = Completer<void>();
    final api = FakeBridgeApi()..hostConfigGetGate = gate;
    api.serveHosts.add(_codexHost);
    // The read is held, so the page cannot settle on it: pump instead.
    t.view.physicalSize = const Size(1280, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HostingEditor(existing: _codexHost),
        ),
      ),
    );
    await t.pump();
    expect(find.byKey(const Key('host-config-loading')), findsOneWidget);
    expect(find.byKey(const Key('host-config-save')), findsNothing);
    expect(find.byKey(const Key('host-base-url')), findsNothing);

    gate.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-config-loading')), findsNothing);
    expect(find.byKey(const Key('host-config-save')), findsOneWidget);
    expect(find.byKey(const Key('codex-runtime-section')), findsOneWidget);
  });

  testWidgets('a failed read offers a retry and blocks saving', (t) async {
    final api = FakeBridgeApi()
      ..hostConfigGetError = StateError('profiles unreadable');
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);

    expect(find.byKey(const Key('host-config-load-failed')), findsOneWidget);
    expect(find.textContaining('profiles unreadable'), findsOneWidget);
    expect(find.byKey(const Key('host-config-save')), findsNothing);

    await _tapKey(t, 'host-config-retry');
    expect(find.byKey(const Key('host-config-load-failed')), findsNothing);
    expect(find.byKey(const Key('host-config-save')), findsOneWidget);
    expect(api.hostConfigGets, 2);
  });

  testWidgets('a running Codex runtime is saved without a restart, then '
      'applied after confirmation', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    final l10n = _l10n(t);

    // Filled from what the host runs; its name is fixed.
    expect(
      find.text(l10n.codexFoundAt('/usr/local/bin/codex')),
      findsOneWidget,
    );
    final name = t.widget<TextField>(find.byKey(const Key('codex-name-field')));
    expect(name.enabled, isFalse);
    expect(_onPressed(t, 'host-config-save'), isNull, reason: 'unchanged');

    await _openAdvanced(t, 'codex-advanced-toggle');
    await _enter(t, 'codex-port-field', '18081');
    await _enter(t, 'proxy-field', 'http://127.0.0.1:22222');
    await _tapKey(t, 'host-config-save');

    final runtime = api.hostConfigSaveRuntimes.single!;
    expect(runtime.isCodex, isTrue);
    expect(runtime.binary, '/usr/local/bin/codex');
    expect(runtime.port, 18081);
    expect(runtime.proxy, 'http://127.0.0.1:22222');
    expect(api.applyCalls, isEmpty, reason: 'save never restarts');
    expect(api.serveHosts.single.appListenAddr, '127.0.0.1:18080');
    expect(find.text(l10n.hostConfigSaved), findsOneWidget);
    expect(find.byKey(const Key('host-config-pending')), findsOneWidget);

    // Applying explains the interruption first; cancelling changes nothing.
    await _tapKey(t, 'host-config-apply');
    expect(find.byKey(const Key('host-apply-dialog')), findsOneWidget);
    expect(find.text(l10n.hostApplyConfirmBody), findsOneWidget);
    await _tapKey(t, 'host-apply-cancel');
    expect(api.applyCalls, isEmpty);

    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    expect(api.applyCalls.single, ('alpha', 'inc-alpha', 1));
    expect(api.serveHosts.single.appListenAddr, '127.0.0.1:18081');
    expect(find.text(l10n.hostApplied), findsOneWidget);
    expect(find.byKey(const Key('host-config-pending')), findsNothing);
  });

  testWidgets('a detection begun before a refill never reaches the running '
      'host', (t) async {
    // A host whose executable is unknown: its first fill looks one up.
    const unknown = AppServeStatus(
      name: 'alpha',
      device: 'local',
      pid: 4242,
      alive: true,
      appListenAddr: '127.0.0.1:18080',
      appServiceKey: 'pcx:local:app:alpha',
      appRegistered: true,
      metaListenAddr: '127.0.0.1:18090',
      metaServiceKey: 'pcx:local:meta:alpha',
      metaRegistered: true,
      provider: 'codex',
      configSource: 'inherited',
      configRevision: 0,
      incarnation: 'inc-alpha',
    );
    final api = FakeBridgeApi()..codexPath = '/usr/local/bin/other-codex';
    final detecting = Completer<void>();
    api.codexLocateGate = detecting;
    api.serveHosts.add(unknown);
    t.view.physicalSize = const Size(1280, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final container = ProviderContainer(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HostingEditor(existing: unknown),
        ),
      ),
    );
    // Detection keeps a progress bar animating: pump bounded frames.
    Future<void> frames() async {
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    await frames();
    expect(api.codexLocateCalls, 1, reason: 'the first fill is looking one up');

    // The host is started again elsewhere with a saved executable; the page
    // says so, and its Reload fills the fields again (a second prefill)
    // while the first lookup is still pending.
    api.serveHosts[0] = const AppServeStatus(
      name: 'alpha',
      device: 'local',
      pid: 4343,
      alive: true,
      appListenAddr: '127.0.0.1:18080',
      appServiceKey: 'pcx:local:app:alpha',
      appRegistered: true,
      metaListenAddr: '127.0.0.1:18090',
      metaServiceKey: 'pcx:local:meta:alpha',
      metaRegistered: true,
      codexBinary: '/opt/saved/codex',
      provider: 'codex',
      configSource: 'inherited',
      configRevision: 1,
      incarnation: 'inc-beta',
    );
    api.hostConfigs['alpha'] = const HostConfig(
      revision: 1,
      runtime: HostRuntime.codex(binary: '/opt/saved/codex', port: 18080),
    );
    container.invalidate(localServeListProvider);
    await frames();
    final reload = find.descendant(
      of: find.byKey(const Key('host-replaced')),
      matching: find.byType(TextButton),
    );
    expect(reload, findsOneWidget);
    await t.tap(reload);
    await frames();
    expect(find.byKey(const Key('host-replaced')), findsNothing);

    // The old lookup answers last; it never replaces the explicit path.
    detecting.complete();
    await frames();
    await t.pumpAndSettle();
    expect(find.textContaining('/opt/saved/codex'), findsWidgets);
    expect(find.textContaining('/usr/local/bin/other-codex'), findsNothing);
    expect(_onPressed(t, 'host-config-save'), isNull, reason: 'not an edit');
  });

  testWidgets('a running generic ACP agent is edited from what it runs', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_acpHost);
    api.activeRuntimes['tool'] = const HostRuntime.acp(_genericAgent);
    await _pumpEditor(t, api, existing: _acpHost);

    expect(find.byKey(const Key('host-agent-edit')), findsOneWidget);
    expect(find.text('Tool'), findsWidgets);
    await _enter(t, 'acp-display-name-field', 'Tool (edited)');
    await _tapKey(t, 'host-config-save');

    final runtime = api.hostConfigSaveRuntimes.single!;
    expect(runtime.agent!.displayName, 'Tool (edited)');
    expect(runtime.agent!.program, _genericAgent.program);
    expect(runtime.agent!.args, _genericAgent.args, reason: 'args kept');
    expect(runtime.agent!.profileId, _genericAgent.profileId);
    expect(api.applyCalls, isEmpty);
  });

  testWidgets('a saved provider API this agent cannot use is kept and blocks '
      'saving', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_acpHost);
    // The Claude preset takes a custom provider over Anthropic Messages only.
    api.activeRuntimes['tool'] = const HostRuntime.acp(
      AcpAgentSpec(
        profileId: 'claude',
        displayName: 'Claude',
        program: 'claude-agent-acp',
      ),
    );
    // Saved with the Responses API, which this agent cannot use.
    api.hostConfigs['tool'] = const HostConfig(
      source: 'custom',
      protocol: 'responses',
      baseUrl: 'https://models.example/v1',
      keySet: true,
      revision: 2,
    );
    await _pumpEditor(t, api, existing: _acpHost);
    final l10n = _l10n(t);

    expect(find.byKey(const Key('host-source-incompatible')), findsOneWidget);
    expect(find.text(l10n.hostSourceUnsupported), findsOneWidget);
    expect(find.text('https://models.example/v1'), findsOneWidget);
    // Not quietly replaced by the API it does support.
    final anthropic = t.widget<ServiceChoice>(
      find.byKey(const Key('host-protocol-anthropic-messages')),
    );
    expect(anthropic.selected, isFalse);
    await _tapKey(t, 'host-config-save');
    expect(
      api.hostConfigSaves,
      isEmpty,
      reason: 'the saved API was not swapped',
    );

    // Choosing the supported API clears it.
    await _tapKey(t, 'host-protocol-anthropic-messages');
    expect(find.byKey(const Key('host-source-incompatible')), findsNothing);
  });

  testWidgets('a stored key is kept unless replaced or removed', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'custom',
      protocol: 'responses',
      baseUrl: 'https://models.example/v1',
      keySet: true,
      revision: 3,
    );
    await _pumpEditor(t, api, existing: _codexHost);

    await _enter(t, 'host-model', 'gpt-next');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.keep);
    expect(api.hostConfigSaves.last.$4, isNull);
    expect(api.hostConfigSaveRuntimes.last, isNull, reason: 'runtime kept');

    await _tapKey(t, 'host-api-key-remove');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.remove);
    expect(api.hostConfigs['alpha']!.keySet, isFalse);
  });

  testWidgets('a save made elsewhere meanwhile is refused, not overwritten', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 4,
    );

    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    await _tapKey(t, 'host-config-save');
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    expect(api.hostConfigs['alpha']!.source, 'official');
  });

  testWidgets('a host restarted elsewhere is not applied by name', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 1,
    );
    final container = await _pumpEditor(t, api, existing: _codexHost);
    api.serveHosts[0] = api.relaunched(api.serveHosts[0]);
    container.invalidate(localServeListProvider);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('host-replaced')), findsOneWidget);
    await _tapKey(t, 'host-config-apply');
    expect(api.applyCalls, isEmpty);
    expect(find.text(_l10n(t).hostReplaced), findsWidgets);
  });

  testWidgets('a host replaced while the save is in flight is not applied', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    final l10n = _l10n(t);

    // The save the apply triggers pauses; meanwhile the host is replaced.
    final gate = Completer<void>();
    api.hostConfigSaveGate = gate;
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    await _tapKeyPumped(t, 'host-config-apply');
    await t.tap(find.byKey(const Key('host-apply-confirm')));
    await t.pump();
    expect(api.hostConfigSaves, hasLength(1), reason: 'the save started');

    api.serveHosts[0] = api.relaunched(api.serveHosts[0]);
    gate.complete();
    await t.pumpAndSettle();

    expect(api.applyCalls, isEmpty, reason: 'the reviewed incarnation is gone');
    expect(find.text(l10n.hostReplaced), findsWidgets);
  });

  testWidgets('a stopped host is not operated on', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    final container = await _pumpEditor(t, api, existing: _codexHost);
    api.serveHosts.clear();
    container.invalidate(localServeListProvider);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('host-gone')), findsOneWidget);
    expect(_onPressed(t, 'stop-hosting-btn'), isNull);
    expect(_onPressed(t, 'host-config-apply'), isNull);
  });

  testWidgets('failed restarts report what runs afterwards', (t) async {
    final api = FakeBridgeApi()
      ..applyResult = const HostApplyResult(
        name: 'alpha',
        applied: false,
        restoredPrevious: true,
        error: 'provider refused',
      );
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 1,
    );
    await _pumpEditor(t, api, existing: _codexHost);
    final l10n = _l10n(t);

    // Saved but not running yet: restarting applies it.
    expect(find.text(l10n.hostConfigPending), findsOneWidget);
    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    expect(
      find.text(l10n.hostApplyRestored('provider refused')),
      findsOneWidget,
    );
    expect(api.hostConfigSaves, isEmpty, reason: 'nothing was edited');

    api.applyResult = const HostApplyResult(
      name: 'alpha',
      applied: false,
      error: 'provider refused',
      restoreError: 'port taken',
    );
    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    expect(
      find.text(l10n.hostApplyStopped('provider refused', 'port taken')),
      findsOneWidget,
    );
  });

  testWidgets('a later read never overwrites pending edits', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 1,
    );
    await _pumpEditor(t, api, existing: _codexHost);

    // The apply re-reads the configuration; hold that read.
    final gate = Completer<void>();
    api.hostConfigGetGate = gate;
    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://mine.example/v1');

    gate.complete();
    await t.pumpAndSettle();
    expect(find.text('https://mine.example/v1'), findsOneWidget);
    expect(find.byKey(const Key('host-config-newer')), findsOneWidget);
  });
}

void _navigationTests() {
  testWidgets('back with unsaved edits asks before discarding them', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-stay');
    expect(find.byType(HostingEditor), findsOneWidget);
    expect(find.text('https://models.example/v1'), findsOneWidget);

    // The page's own Close button asks the same way.
    await _tapKey(t, 'host-editor-close');
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-discard');
    expect(find.byType(HostingEditor), findsNothing);
    expect(api.hostConfigSaves, isEmpty);
  });

  testWidgets('an unedited page closes without asking', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsNothing);
    expect(find.byType(HostingEditor), findsNothing);
  });
}

void _entryTests() {
  testWidgets('the Manage page opens the editor, and its back asks first', (
    t,
  ) async {
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // Hosting is desktop-only.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final api = FakeBridgeApi();
      await t.pumpWidget(
        ProviderScope(
          overrides: [bridgeApiProvider.overrideWithValue(api)],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ServicesScreen(),
          ),
        ),
      );
      await t.pumpAndSettle();
      await _tapKey(t, 'host-this-device-btn');
      expect(find.byType(HostingEditor), findsOneWidget);

      await _tapKey(t, 'host-source-custom');
      await _enter(t, 'host-base-url', 'https://models.example/v1');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      // Keyboard: Escape dismisses the question, which means staying.
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(HostingEditor), findsOneWidget);
      expect(find.text('https://models.example/v1'), findsOneWidget);

      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.byType(ServicesScreen), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the page menu, origin and parent of the real router ask '
      'before leaving edits, then navigate', (t) async {
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final api = FakeBridgeApi();
      await t.pumpWidget(
        routerHost(
          api,
          initial: '/manage',
          routes: [
            stub('/', 'conversation-page'),
            GoRoute(path: '/manage', builder: (_, _) => const ServicesScreen()),
            stub('/settings', 'settings-page'),
          ],
        ),
      );
      await t.pumpAndSettle();

      Future<void> openEdited() async {
        await _tapKey(t, 'host-this-device-btn');
        expect(find.byType(HostingEditor), findsOneWidget);
        await _tapKey(t, 'host-source-custom');
        await _enter(t, 'host-base-url', 'https://models.example/v1');
      }

      Future<void> menuTo(String label) async {
        await _tapKey(t, 'utility-page-menu');
        await t.tap(find.text(label).last);
        await t.pumpAndSettle();
      }

      await openEdited();
      final l10n = _l10n(t);
      // The menu marks Manage (the parent) as current and asks first.
      await menuTo(l10n.settingsTitle);
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      // Keyboard: Escape means stay.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(HostingEditor), findsOneWidget);
      expect(find.text('https://models.example/v1'), findsOneWidget);

      // Discarding replaces the page with the sibling, editor and all.
      await menuTo(l10n.settingsTitle);
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.text('settings-page'), findsOneWidget);

      // The parent breadcrumb leads back to Manage, after asking.
      GoRouter.of(t.element(find.text('settings-page'))).go('/manage');
      await t.pumpAndSettle();
      await openEdited();
      await _tapKey(t, 'utility-parent-origin');
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.byType(ServicesScreen), findsOneWidget);

      // The conversation origin asks too, then goes home.
      await openEdited();
      await _tapKey(t, 'utility-chat-origin');
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.text('conversation-page'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shared navigation waits for the page to agree', (t) async {
    final answer = <Completer<bool>>[];
    var navigated = 0;
    late BuildContext inside;
    await t.pumpWidget(
      MaterialApp(
        home: UtilityLeaveGuard(
          confirm: () {
            final c = Completer<bool>();
            answer.add(c);
            return c.future;
          },
          child: Builder(
            builder: (context) {
              inside = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    UtilityLeaveGuard.leave(inside, () => navigated++);
    await t.pump();
    expect(navigated, 0, reason: 'asked, not answered');
    answer.single.complete(false);
    await t.pump();
    expect(navigated, 0, reason: 'the page said stay');

    UtilityLeaveGuard.leave(inside, () => navigated++);
    answer.last.complete(true);
    await t.pump();
    expect(navigated, 1);

    // Without a guard, navigation is immediate (existing pages unchanged).
    late BuildContext bare;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            bare = context;
            return const SizedBox();
          },
        ),
      ),
    );
    UtilityLeaveGuard.leave(bare, () => navigated++);
    expect(navigated, 2);
  });
}

void _signInTests() {
  testWidgets('official sign-in runs the editor codex on its own session', (
    t,
  ) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');
    expect(find.byKey(const Key('official-login-panel')), findsOneWidget);

    await _tapKeyPumped(t, 'codex-login-chatgpt');
    expect(api.signInSessions, hasLength(1));
    // The editor's codex and its default proxy, not the app's environment.
    expect(api.localSessionBinaries.single, '/usr/local/bin/codex');
    expect(api.localSessionProxies.single, 'http://127.0.0.1:11111');
    expect(find.byKey(const Key('codex-login-cancel')), findsOneWidget);

    // Cancel ends only this attempt's session.
    await _tapKeyPumped(t, 'codex-login-cancel');
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions, ['local-0']);
    // Let the abandoned poll's timer run out; it touches nothing.
    await t.pump(const Duration(seconds: 3));
    expect(api.localCancels, isEmpty);
  });

  testWidgets('an existing credential is not this sign-in succeeding', (
    t,
  ) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');
    await _tapKeyPumped(t, 'codex-login-chatgpt');
    final session = api.signInSessions.single;

    // A stale auth.json or an API key: configured, but no completion.
    api.localAuth[session] = const CodexAuthStatus(
      authenticated: true,
      method: 'apikey',
    );
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(api.signInSessions, [session], reason: 'still waiting');
    expect(find.byKey(const Key('codex-login-cancel')), findsOneWidget);

    // A failed refresh is shown and the next poll retries.
    api.localAuthError = StateError('rpc lagging');
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.textContaining('rpc lagging'), findsOneWidget);

    // The server completes this login with a ChatGPT account.
    api.localAuth[session] = const CodexAuthStatus(
      authenticated: true,
      method: 'chatgpt',
      completed: true,
    );
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions, [session]);
    expect(
      find.text(_l10n(t).codexSetupLoginSuccess('chatgpt')),
      findsOneWidget,
    );
  });

  testWidgets('two attempts own their sessions: a late open, status or '
      'logout of a closed one never touches the other', (t) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    final showA = ValueNotifier(true);
    final signedIn = ValueNotifier<CodexSetupStatus?>(null);
    addTearDown(showA.dispose);
    addTearDown(signedIn.dispose);
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: Listenable.merge([showA, signedIn]),
              builder: (_, _) => Column(
                children: [
                  if (showA.value)
                    OfficialLoginPanel(
                      key: const Key('panel-a'),
                      status: signedIn.value,
                    ),
                  const OfficialLoginPanel(key: Key('panel-b'), status: null),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    Finder within(String panel, String key) => find.descendant(
      of: find.byKey(Key(panel)),
      matching: find.byKey(Key(key)),
    );
    Future<void> frames() async {
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    // A's open is held; B opens and is waiting while A is still pending.
    final lateOpen = Completer<void>();
    api.localSessionGate = lateOpen;
    await t.tap(within('panel-a', 'codex-login-chatgpt'));
    await frames();
    expect(api.signInSessions, isEmpty, reason: 'A is still opening');
    await t.tap(within('panel-b', 'codex-login-chatgpt'));
    await frames();
    expect(api.localSessionBinaries, hasLength(2), reason: 'both asked');
    final b = api.signInSessions.single;
    expect(within('panel-b', 'codex-login-cancel'), findsOneWidget);

    // A goes away, then its open answers late: only that session closes.
    showA.value = false;
    await frames();
    lateOpen.complete();
    await frames();
    expect(api.signInSessions, [b], reason: 'B keeps its own');
    expect(api.closedSignInSessions, hasLength(1));
    expect(api.closedSignInSessions.single, isNot(b));

    // A again, with its status poll held; it goes away and the held status
    // (a completed sign-in) answers late: B is not signed in by it.
    showA.value = true;
    await frames();
    await t.tap(within('panel-a', 'codex-login-chatgpt'));
    await frames();
    final a2 = api.signInSessions.last;
    expect(a2, isNot(b));
    final lateStatus = Completer<void>();
    api.localAuthGates[a2] = lateStatus;
    api.localAuth[a2] = const CodexAuthStatus(
      authenticated: true,
      method: 'chatgpt',
      completed: true,
    );
    await t.pump(const Duration(seconds: 2));
    await frames();
    showA.value = false;
    await frames();
    lateStatus.complete();
    await frames();
    expect(api.signInSessions, [b]);
    expect(api.closedSignInSessions, contains(a2));
    expect(within('panel-b', 'codex-login-cancel'), findsOneWidget);
    expect(within('panel-b', 'codex-login-info'), findsOneWidget);
    expect(
      find.text(_l10nOf(t).codexSetupLoginSuccess('chatgpt')),
      findsNothing,
      reason: 'no panel took the late completion as its own',
    );

    // A signed in on disk: its sign-out is held, A goes away, the logout
    // answers late. B's session is untouched and never signed out.
    signedIn.value = const CodexSetupStatus(
      codexHome: '/Users/me/.codex',
      hasConfig: true,
      hasAuth: true,
      hasCustomProvider: false,
      authMode: 'chatgpt',
      needsSetup: false,
      promptVariant: 'default',
    );
    showA.value = true;
    await frames();
    final lateLogout = Completer<void>();
    api.localLogoutGate = lateLogout;
    await t.tap(within('panel-a', 'codex-logout-btn'));
    await frames();
    final a3 = api.signInSessions.last;
    expect(a3, isNot(b));
    showA.value = false;
    await frames();
    lateLogout.complete();
    await frames();
    expect(api.localLogoutSessions, isNot(contains(b)));
    expect(api.signInSessions, [b]);
    expect(api.closedSignInSessions, contains(a3));

    // Closing B ends only its own session.
    await t.tap(within('panel-b', 'codex-login-cancel'));
    await frames();
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions.last, b);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a login completed without a ChatGPT account is not success', (
    t,
  ) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');
    await _tapKeyPumped(t, 'codex-login-chatgpt');
    final session = api.signInSessions.single;
    api.localAuth[session] = const CodexAuthStatus(
      authenticated: true,
      method: 'apikey',
      completed: true,
    );
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.text(_l10n(t).hostLoginNotOfficial), findsOneWidget);
    expect(find.text(_l10n(t).codexSetupLoginSuccess('chatgpt')), findsNothing);
  });

  testWidgets('a late session open after a new attempt is closed, and the '
      'new attempt keeps its own', (t) async {
    _mockLauncher(t);
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-official');

    final late = Completer<void>();
    api.localSessionGate = late;
    await _tapKeyPumped(t, 'codex-login-chatgpt');
    // Leaving closes the page; the late open must not survive it. The
    // spinner keeps animating until the page is gone, so pump finitely.
    await t.binding.handlePopRoute();
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await t.tap(find.byKey(const Key('host-leave-discard')));
    await t.pump();
    late.complete();
    await t.pumpAndSettle();
    expect(find.byType(HostingEditor), findsNothing);
    expect(api.signInSessions, isEmpty);
    expect(api.closedSignInSessions, hasLength(1));
    expect(api.localLogouts, 0);
  });
}

extension on AppServeStatus {
  /// This host under another [name].
  AppServeStatus copyName(String name) => AppServeStatus(
    name: name,
    device: device,
    pid: pid,
    alive: alive,
    appListenAddr: appListenAddr,
    appServiceKey: 'pcx:local:app:$name',
    appRegistered: appRegistered,
    metaListenAddr: metaListenAddr,
    metaServiceKey: 'pcx:local:meta:$name',
    metaRegistered: metaRegistered,
    codexBinary: codexBinary,
    proxy: proxy,
    provider: provider,
    configSource: configSource,
    configRevision: configRevision,
    incarnation: 'inc-$name',
  );
}
