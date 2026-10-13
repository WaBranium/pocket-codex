part of '../acp_hosting_test.dart';

void _registerCatalogStatus() {
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

  testWidgets('the route status says what was reset, for which projects, '
      'and what it does not cover', (t) async {
    AppServeStatus host(String state, List<String> reasons) => AppServeStatus(
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
        routeState: state,
        routeReasons: reasons,
        routeProjects: const ['/work/a', '/work/b'],
      ),
    );
    String route() =>
        t.widget<Text>(find.byKey(const Key('acp-catalog-route'))).data!;

    final enforced = host('enforced', ['small-model', 'provider']);
    await _pumpDialog(
      t,
      FakeBridgeApi()..serveHosts.add(enforced),
      existing: enforced,
    );
    expect(route(), contains('was reset to this host\'s provider'));
    expect(route(), contains('small_model names another provider'));
    expect(route(), contains('changed the provider\'s definition'));
    expect(
      t.widget<Text>(find.byKey(const Key('acp-catalog-route-projects'))).data,
      'Projects checked, as the plugin input names them (not verified '
      'against OpenCode\'s source): /work/a, /work/b',
    );
    expect(
      t.widget<Text>(find.byKey(const Key('acp-catalog-route-scope'))).data,
      allOf(contains('pinned over a key saved'), contains('auth loader')),
    );
    await t.pumpWidget(const SizedBox());

    // A missing key leaves nothing usable: a warning, no coverage claim.
    final refused = host('refused', ['key', 'model']);
    await _pumpDialog(
      t,
      FakeBridgeApi()..serveHosts.add(refused),
      existing: refused,
    );
    expect(route(), contains('no usable provider'));
    expect(find.byKey(const Key('acp-catalog-route-scope')), findsNothing);
    await t.pumpWidget(const SizedBox());

    final selected = host('selected', const []);
    await _pumpDialog(
      t,
      FakeBridgeApi()..serveHosts.add(selected),
      existing: selected,
    );
    expect(route(), 'OpenCode uses this host\'s provider and model.');
    expect(find.byKey(const Key('acp-catalog-route-scope')), findsOneWidget);
    await t.pumpWidget(const SizedBox());

    // An older plugin's report is a warning, with no coverage claim.
    final older = host('overridden', ['model']);
    await _pumpDialog(
      t,
      FakeBridgeApi()..serveHosts.add(older),
      existing: older,
    );
    expect(route(), contains('Requests may go elsewhere'));
    expect(find.byKey(const Key('acp-catalog-route-scope')), findsNothing);
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
}
