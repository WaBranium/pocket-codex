/// The services screen: what a device exposes, its reachability, and managing a
/// local host from it.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsAction;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/screens/services_screen.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/api_service_panel.dart';
import 'package:pocket_codex/src/widgets/loading.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';

void main() {
  // AppSessionScreen keeps per-thread plan/effort memory in process-wide static
  // maps (so a reopened thread restores its mode before the persisted config
  // lands). Reset it between tests so memory from one test can't leak into
  // another that reuses a thread id.
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a device lists every kind it exposes, plus the relay', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    expect(find.text('lb7666.top:7666'), findsOneWidget);
    await openDevice(t);
    // Both kinds sit under the one device — no tab to switch between them.
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:app:default')),
      findsOneWidget,
    );
  });

  testWidgets('Opening a chat capability returns to the chat on that service', (
    t,
  ) async {
    // "Open" used to push a project picker at /app/:key — a third level whose
    // project tree and conversation list the chat sidebar already shows. It now
    // hands the key to the home and goes back to it.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    late final ProviderContainer container;
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: Consumer(
          builder: (c, ref, _) {
            container = ProviderScope.containerOf(c);
            return MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: GoRouter(
                initialLocation: '/manage',
                routes: [
                  stub('/', 'chat-home'),
                  GoRoute(path: '/manage', builder: (_, _) => ServicesScreen()),
                ],
              ),
            );
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await openDevice(t);

    await t.tap(find.text('打开')); // servicesOpen (zh)
    await t.pumpAndSettle();

    // Back on the chat route, with the service handed over for it to switch to.
    expect(find.text('chat-home'), findsOneWidget);
    expect(container.read(requestedServiceProvider), 'pcx:lb7666:app:default');
  });

  testWidgets('Managing an API capability opens a panel, not a page', (
    t,
  ) async {
    // The /api/:key route was a whole page for one port field and one button.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    await t.tap(find.text('管理')); // servicesManage (zh)
    await t.pumpAndSettle();

    // The panel is up with its subscribe form, and the capability row it acts
    // on is still mounted behind it — the point of a panel over a route.
    expect(find.byKey(const Key('subscribe-btn')), findsOneWidget);
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );
  });

  testWidgets('Services shows error state with retry', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'r:1', hasKey: true),
    )..discoverError = Exception('relay down');
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('services-error')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('Services explains an expired session and offers sign-in', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'octocat',
      ),
    )..discoverError = StateError('session expired; sign in again');
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/manage',
        routes: [
          GoRoute(path: '/manage', builder: (_, _) => const ServicesScreen()),
          GoRoute(
            path: '/onboarding',
            builder: (_, state) => Scaffold(
              body: Text('login:${state.uri.queryParameters['reason']}'),
            ),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('登录已过期'), findsOneWidget);
    expect(find.textContaining('请重新登录以恢复服务连接'), findsOneWidget);
    expect(find.text('无法连接到 relay'), findsNothing);
    expect(find.text('重试'), findsNothing);

    await t.tap(find.byKey(const Key('services-sign-in-again')));
    await t.pumpAndSettle();
    expect(find.text('login:session-expired'), findsOneWidget);
  });

  testWidgets('a registered-but-dead app-server reads "unreachable", not '
      '"online"', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    )..reachable['pcx:lb7666:app:default'] = false; // backend probe fails
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 900); // narrow: single-pane list
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    // The probe says the backend is dead → honest "不可达" on the app-server.
    expect(find.text('不可达'), findsOneWidget); // statusUnreachable (zh)
    // The old bug showed a false green "online" here, off a cached flag.
    expect(find.text('在线'), findsNothing);
    // …and it spells out *why*: relay registration up, remote backend down.
    expect(find.textContaining('远端 app-server 没有响应'), findsOneWidget);
  });

  testWidgets('account mode shows the GitHub identity, not "(no relay)"', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'acking-you',
      ),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcxu:u:lb7666:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    // The header shows the signed-in GitHub identity…
    expect(find.text('@acking-you'), findsOneWidget);
    // …and never the confusing "(no relay configured)" placeholder.
    expect(find.text('(未配置 relay)'), findsNothing);
  });

  FakeBridgeApi accountFake() => FakeBridgeApi(
    config: const ConfigInfo(
      relay: '',
      hasKey: false,
      mode: 'account',
      accountLogin: 'acking-you',
    ),
    services: const [],
  );

  testWidgets('desktop account mode: add a host, then stop it', (t) async {
    // The block is desktop-only; force a desktop target. Reset inside the body
    // (not addTearDown) so the framework's debug-var invariant check passes.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);

      // No hosts yet → only the "host another" entry (desktop + account mode).
      expect(find.byKey(const Key('add-local-host-card')), findsOneWidget);

      // Add a host → start on the default port with the default proxy.
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('start-hosting-btn')), findsOneWidget);
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServePort, 18080);
      expect(api.lastServeProxy, 'http://127.0.0.1:11111');
      expect(api.serveHosts, hasLength(1));

      // The running host's card appears; open it → Stop tears it down.
      expect(find.byKey(const Key('local-host-default')), findsOneWidget);
      await t.tap(find.byKey(const Key('local-host-default')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('stop-hosting-btn')), findsOneWidget);
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a host whose codex did not exit stays listed and stoppable '
      'until a stop succeeds', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake()
        ..serveStopFailures = 1
        ..serveHosts.add(
          const AppServeStatus(
            name: 'stuck',
            device: 'local',
            provider: 'codex',
            protocol: 'codex-app-server',
            providerName: 'Codex',
            agentError: 'its codex did not exit; stop the host again',
          ),
        );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      expect(find.byKey(const Key('local-host-stuck')), findsOneWidget);
      expect(find.byKey(const Key('local-host-stop-failed')), findsOneWidget);

      await t.tap(find.byKey(const Key('local-host-stuck')));
      await t.pumpAndSettle();
      final stop = find.byKey(const Key('stop-hosting-btn'));
      await t.ensureVisible(stop);
      await t.tap(stop);
      await t.pumpAndSettle();
      expect(api.serveHosts, hasLength(1), reason: 'the failed stop keeps it');
      expect(find.textContaining('did not exit'), findsWidgets);
      expect(
        t.widget<ButtonStyleButton>(stop).onPressed,
        isNotNull,
        reason: 'the retry stays reachable',
      );

      await t.tap(stop);
      await t.pumpAndSettle();
      expect(api.serveHosts, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The agent chooser sits above the Codex form, so its controls may start
  // below the dialog's fold: scroll them in and require a real hit first.
  Future<void> tapRevealed(WidgetTester t, Finder control) async {
    await t.ensureVisible(control);
    await t.pumpAndSettle();
    expect(control.hitTestable(), findsOneWidget, reason: '$control');
    await t.tap(control);
    await t.pumpAndSettle();
  }

  testWidgets('local-host: turning off the proxy passes no proxy', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      // The proxy field shows by default (proxy is mandatory); toggle it off.
      expect(find.byKey(const Key('proxy-field')), findsOneWidget);
      await tapRevealed(t, find.byKey(const Key('use-proxy-switch')));
      expect(find.byKey(const Key('proxy-field')), findsNothing);
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServeProxy, isNull);
      expect(api.serveHosts, hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: "change path" reveals the codex path field', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake(); // codexLocate returns a path → "found"
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      // Found → no path field, but a "change path" override is offered.
      expect(find.byKey(const Key('codex-path-field')), findsNothing);
      expect(find.byKey(const Key('customize-codex-btn')), findsOneWidget);
      await tapRevealed(t, find.byKey(const Key('customize-codex-btn')));
      expect(find.byKey(const Key('codex-path-field')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: a second host coexists with the first', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    // Tall enough that both host cards and the add button build: the detail is
    // a lazy ListView, so anything below the fold is absent rather than merely
    // scrolled away, and `ensureVisible` has nothing to scroll to.
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);

      // First host "default".
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      // A second host defaults to a free name and an automatic port, so it
      // never collides with the first.
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      final name = t.widget<TextField>(
        find.byKey(const Key('codex-name-field')),
      );
      expect(name.controller!.text, 'default-2');
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServeName, 'default-2');
      expect(api.lastServePort, 0);

      // A third, named by hand, with an explicit port behind "Advanced".
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('codex-name-field')), 'work');
      // The toggle spans the dialog's width with its button at the start;
      // reveal and tap the button itself, inside the dialog's scroll view.
      final advanced = find.descendant(
        of: find.byKey(const Key('codex-advanced-toggle')),
        matching: find.byType(TextButton),
      );
      await t.ensureVisible(advanced);
      await t.pumpAndSettle();
      await t.tap(advanced);
      await t.pumpAndSettle();
      final port = find.byKey(const Key('codex-port-field'));
      expect(port, findsOneWidget, reason: 'Advanced unfolded the port');
      await t.ensureVisible(port);
      await t.pumpAndSettle();
      await t.enterText(port, '18081');
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServeName, 'work');
      expect(api.lastServePort, 18081);

      expect(api.serveHosts, hasLength(3));
      expect(find.byKey(const Key('local-host-default')), findsOneWidget);
      expect(find.byKey(const Key('local-host-default-2')), findsOneWidget);
      expect(find.byKey(const Key('local-host-work')), findsOneWidget);
      // The add entry stays available however many hosts run.
      expect(find.byKey(const Key('add-local-host-card')), findsOneWidget);

      // Stopping one Codex host forgets only its own restore record.
      final container = ProviderScope.containerOf(
        t.element(find.byType(ServicesScreen)),
      );
      final before = await container.read(uiPrefsProvider.future);
      expect(before.autoHostCodex.map((h) => h.name), [
        'default',
        'default-2',
        'work',
      ]);
      await t.tap(find.byKey(const Key('local-host-default-2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
      final after = await container.read(uiPrefsProvider.future);
      expect(after.autoHostCodex.map((h) => h.name), ['default', 'work']);
      expect(api.serveHosts.map((h) => h.name), ['default', 'work']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: a hosted server is labeled local in the App-server '
      'list', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(
          relay: '',
          hasKey: false,
          mode: 'account',
          accountLogin: 'acking-you',
        ),
        // A discovered app-server whose key matches the host we'll start.
        services: const [
          ServiceEntry(
            device: 'local',
            kind: 'app',
            name: 'default',
            key: 'pcx:local:app:default',
          ),
        ],
      );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      // Before hosting, the device is just a discovered remote one — and the
      // hosting card belongs to THIS machine, so it isn't shown under a peer.
      expect(find.text('本机'), findsNothing);
      expect(find.byKey(const Key('add-local-host-card')), findsNothing);

      // Host "default" locally → its key matches the discovered service. The
      // title bar's button is the route in when no local device is selected.
      await t.tap(find.byKey(const Key('host-this-device-btn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      // The device now reads as this machine rather than a remote peer, and the
      // host it published is listed under it by name — the state change, not
      // just the presence of the word somewhere on the page.
      expect(find.text('本机'), findsWidgets);
      expect(find.byKey(const Key('local-host-default')), findsOneWidget);
      // Its app-server capability is the same discovered service as before.
      expect(
        find.byKey(const Key('device-capability-pcx:local:app:default')),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: a tunnel can be deregistered, then re-registered', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      // Host one server → it publishes both an app and an api tunnel.
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.single.apiRegistered, isTrue);
      expect(api.serveHosts.single.appRegistered, isTrue);

      // Deregister just the API tunnel. Its capability row owns both actions now
      // — the separate tunnel list described the same three things twice.
      const apiMenu = Key('capability-menu-pcx:local:api:default');
      await t.tap(find.byKey(apiMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('注销')); // deregister (zh)
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('deregister-confirm-btn')));
      await t.pumpAndSettle();
      // Only the api tunnel is unpublished; the app tunnel + host stay up.
      expect(api.serveHosts.single.apiRegistered, isFalse);
      expect(api.serveHosts.single.appRegistered, isTrue);

      // The row stays — listed as offline — so re-registering is still reachable.
      // Hiding it would strand the tunnel with no route back.
      expect(find.text('已下架'), findsOneWidget); // tunnelOffline (zh)
      await t.tap(find.byKey(apiMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('重新注册')); // reregister (zh)
      await t.pumpAndSettle();
      expect(api.serveHosts.single.apiRegistered, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: the session tunnel can be taken down and put back', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.single.metaRegistered, isTrue);

      // Session sharing rides its own tunnel, so it unpublishes like the other
      // two — the row it replaced offered exactly this.
      const metaMenu = Key('capability-menu-meta-pcx:local:app:default');
      await t.tap(find.byKey(metaMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('注销')); // deregister (zh)
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('deregister-confirm-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.single.metaRegistered, isFalse);
      // The app tunnel it shares a row-key with is untouched.
      expect(api.serveHosts.single.appRegistered, isTrue);

      await t.tap(find.byKey(metaMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('重新注册')); // reregister (zh)
      await t.pumpAndSettle();
      expect(api.serveHosts.single.metaRegistered, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: each tunnel is described once, address and all', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      // The capability row IS the tunnel row now: each protocol is named once,
      // on the same line as the listen address that only the tunnel row used to
      // carry. A second mention would mean the duplicate list is back.
      expect(find.textContaining('App-server'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'App-server\s+·\s+127\.0\.0\.1:18080')),
        findsOneWidget,
      );
      expect(
        find.textContaining(RegExp(r'^API\s+·\s+127\.0\.0\.1:')),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the identity row is the way into settings', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await t.pumpWidget(
        routerHost(
          accountFake(),
          initial: '/manage',
          routes: [
            GoRoute(path: '/manage', builder: (_, _) => const ServicesScreen()),
            stub('/settings', 'settings-page'),
          ],
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('identity-open-settings')));
      await t.pumpAndSettle();
      expect(find.text('settings-page'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('self-host desktop can host too, from the card and the title '
      'bar', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      // Self-host: a relay and key, no account. Publishing works the same, so
      // hosting must not hide behind an account sign-in.
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        services: const [
          ServiceEntry(
            device: 'peer',
            kind: 'app',
            name: 'default',
            key: 'pcx:peer:app:default',
          ),
        ],
      );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      // A remote peer is listed and nothing is hosted: the title bar is the
      // way in.
      expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
      await t.tap(find.byKey(const Key('host-this-device-btn')));
      await t.pumpAndSettle();
      // The agent grid offers Codex and the OpenCode preset, each by mark.
      expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
      expect(
        find.byKey(const Key('agent-choice-preset:opencode')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('agent-icon-codex')), findsWidgets);
      expect(find.byKey(const Key('agent-icon-opencode')), findsOneWidget);
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts, hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the hosting action stays reachable in a narrow or '
      'text-scaled title bar', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
      );
      const text = 'Host this device';
      final action = find.byKey(const Key('host-this-device-btn'));
      final labelled = find.descendant(of: action, matching: find.text(text));
      final back = find.byKey(const Key('utility-chat-origin'));
      Future<void> show(
        Size size,
        double scale, {
        Brightness brightness = Brightness.light,
        Locale locale = const Locale('en'),
      }) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = scale;
        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(
          host(
            const ServicesScreen(),
            api,
            locale: locale,
            // The app's own themes: their title-bar and icon-button colours
            // are what the icon form is drawn with.
            theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: 'no overflow: $size ×$scale');
        // Every bar control stays on the bar and receives taps.
        for (final control in [
          back,
          find.byKey(const Key('refresh-btn')),
          action,
          find.byKey(const Key('utility-page-menu')),
        ]) {
          expect(control.hitTestable(), findsOneWidget, reason: '$control');
          final rect = t.getRect(control);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
        }
      }

      final grid = find.byKey(const Key('agent-choice-grid'));
      Future<void> opensDialog() async {
        await t.pumpAndSettle();
        expect(grid, findsOneWidget);
        Navigator.of(t.element(grid)).pop();
        await t.pumpAndSettle();
      }

      // The icon form is announced as an enabled, focusable button named
      // by its tooltip, and assistive technology can activate it.
      Future<void> expectAccessibleAction() async {
        final handle = t.ensureSemantics();
        try {
          final node = t.getSemantics(action);
          expect(
            node,
            isSemantics(
              tooltip: text,
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              isFocusable: true,
              hasTapAction: true,
              hasFocusAction: true,
            ),
          );
          // A real target, not a zero-size node; its on-screen placement
          // is checked by show().
          expect(node.rect.isEmpty, isFalse);
          node.owner!.performAction(node.id, SemanticsAction.tap);
          await opensDialog();
        } finally {
          handle.dispose();
        }
      }

      // The icon form's plus is drawn in a colour that stands out from its
      // filled disc (WCAG's 3:1 for graphics), in light and dark.
      void expectVisibleGlyph(String why) {
        final glyph = t.widget<RichText>(
          find.descendant(of: action, matching: find.byType(RichText)),
        );
        expect(glyph.text.toPlainText(), isNotEmpty, reason: why);
        final ink = glyph.text.style!.color!;
        final disc = t
            .widget<Material>(
              find
                  .descendant(of: action, matching: find.byType(Material))
                  .first,
            )
            .color!;
        final (hi, lo) = (
          math.max(ink.computeLuminance(), disc.computeLuminance()),
          math.min(ink.computeLuminance(), disc.computeLuminance()),
        );
        expect(
          (hi + 0.05) / (lo + 0.05),
          greaterThanOrEqualTo(3),
          reason: '$why: plus $ink on disc $disc',
        );
        expect(ink.a, greaterThan(0.5), reason: '$why: opaque plus');
        expect(disc.a, greaterThan(0.5), reason: '$why: filled disc');
      }

      // Tab to the action, then Enter.
      Future<void> activateByKeyboard() async {
        final target = t.element(action);
        bool focused() {
          final node = FocusManager.instance.primaryFocus?.context;
          if (node == null) return false;
          var inside = identical(node, target);
          node.visitAncestorElements((e) {
            if (identical(e, target)) inside = true;
            return !inside;
          });
          return inside;
        }

        for (var i = 0; i < 30 && !focused(); i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
        }
        expect(focused(), isTrue, reason: 'reachable by Tab');
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await opensDialog();
      }

      await show(const Size(1440, 900), 1);
      expect(labelled, findsOneWidget, reason: 'room for the label');
      await activateByKeyboard();

      // A phone-width bar: the same action, named by tooltip and semantics.
      await show(const Size(320, 640), 1);
      expect(labelled, findsNothing);
      expect(find.byTooltip(text), findsOneWidget);
      expectVisibleGlyph('320 light');
      await expectAccessibleAction();
      await t.tap(action);
      await opensDialog();
      await activateByKeyboard();

      // Large text on a bar too narrow for the scaled label.
      await show(const Size(800, 900), 3);
      expect(labelled, findsNothing);
      expect(find.byTooltip(text), findsOneWidget);
      expectVisibleGlyph('800 ×3 light');
      await expectAccessibleAction();
      await activateByKeyboard();

      // Chinese: the short label is narrow enough for the 3× bar, but a
      // line of 3× text is taller than the bar's button, so the icon form
      // is chosen rather than a label cut off at the bottom.
      const zhText = '托管本机';
      final zhLabelled = find.descendant(
        of: action,
        matching: find.text(zhText),
      );
      await show(const Size(1440, 900), 1, locale: const Locale('zh'));
      expect(zhLabelled, findsOneWidget, reason: 'regular text: labelled');
      await show(const Size(800, 900), 3, locale: const Locale('zh'));
      expect(zhLabelled, findsNothing, reason: 'the label would be cut');
      expect(find.byTooltip(zhText), findsOneWidget);
      expectVisibleGlyph('800 ×3 zh');
      await t.tap(action);
      await opensDialog();
      await activateByKeyboard();

      // The same in the dark theme.
      await show(const Size(1440, 900), 1, brightness: Brightness.dark);
      expect(labelled, findsOneWidget, reason: 'room for the label (dark)');
      for (final (size, scale) in [
        (const Size(320, 640), 1.0),
        (const Size(800, 900), 3.0),
      ]) {
        await show(size, scale, brightness: Brightness.dark);
        expect(labelled, findsNothing);
        expectVisibleGlyph('${size.width.toInt()} ×$scale dark');
        await t.tap(action);
        await opensDialog();
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('large text keeps the identity, status and capability count '
      'whole', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        services: const [
          ServiceEntry(
            device: 'peer',
            kind: 'app',
            name: 'default',
            key: 'pcx:peer:app:default',
          ),
        ],
      );
      const relay = 'relay.example:7666';
      const online = 'Online';
      const title = 'Available capabilities';
      const count = '1 capabilities';
      final identity = find.byKey(const Key('identity-open-settings'));
      final narrowList = find.byKey(const ValueKey('svc-narrow-devices'));
      Rect rectOf(Finder f) => t.getRect(f);
      bool within(Rect inner, Rect outer) =>
          inner.left >= outer.left - 0.5 &&
          inner.top >= outer.top - 0.5 &&
          inner.right <= outer.right + 0.5 &&
          inner.bottom <= outer.bottom + 0.5;
      Finder inIdentity(String text) =>
          find.descendant(of: identity, matching: find.text(text));

      Future<void> show(Size size, double scale, Brightness brightness) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = scale;
        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(
          host(
            const ServicesScreen(),
            api,
            locale: const Locale('en'),
            theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: 'no overflow: $size ×$scale');
      }

      // The identity text and the whole status lie inside the row, which
      // stays on screen and opens settings when tapped.
      void identityWhole(Size size) {
        expect(identity.hitTestable(), findsOneWidget);
        final row = rectOf(identity);
        expect(within(row, Offset.zero & size), isTrue, reason: 'row $row');
        for (final text in [relay, online]) {
          expect(inIdentity(text), findsOneWidget, reason: text);
          expect(within(rectOf(inIdentity(text)), row), isTrue, reason: text);
        }
        final status = t.renderObject<RenderParagraph>(inIdentity(online));
        expect(status.didExceedMaxLines, isFalse);
      }

      // The capabilities title and its count inside their card.
      final card = find
          .ancestor(of: find.text(title), matching: find.byType(Card))
          .first;
      Finder inCard(String text) =>
          find.descendant(of: card, matching: find.text(text));
      void countWhole(Size size) {
        final bounds = rectOf(card);
        for (final text in [title, count]) {
          expect(inCard(text), findsOneWidget, reason: text);
          final rect = rectOf(inCard(text));
          expect(within(rect, bounds), isTrue, reason: text);
          expect(within(rect, Offset.zero & size), isTrue, reason: text);
        }
      }

      for (final brightness in Brightness.values) {
        // Regular text on a desktop: the column beside the detail, the
        // status beside the identity, the count at the end of the title's
        // line.
        await show(const Size(1440, 900), 1, brightness);
        expect(narrowList, findsNothing, reason: 'side by side');
        identityWhole(const Size(1440, 900));
        expect(
          (rectOf(inIdentity(online)).center.dy -
                  rectOf(inIdentity(relay)).center.dy)
              .abs(),
          lessThan(4),
          reason: 'status on the identity line',
        );
        countWhole(const Size(1440, 900));
        expect(
          rectOf(inCard(count)).left,
          greaterThan(rectOf(inCard(title)).right),
          reason: 'count beside the title',
        );

        // 3× text on a tablet: one level at a time, everything whole.
        await show(const Size(800, 900), 3, brightness);
        expect(narrowList, findsOneWidget, reason: 'one level at a time');
        identityWhole(const Size(800, 900));
        await t.tap(find.byKey(const Key('device-peer')));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        countWhole(const Size(800, 900));
        await t.tap(find.byKey(const Key('device-back')));
        await t.pumpAndSettle();
        expect(narrowList, findsOneWidget);

        // 2× text on a phone: the status moves under the identity.
        await show(const Size(320, 640), 2, brightness);
        identityWhole(const Size(320, 640));
        expect(
          rectOf(inIdentity(online)).top,
          greaterThanOrEqualTo(rectOf(inIdentity(relay)).bottom - 0.5),
          reason: 'status under the identity',
        );
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Codex and an ACP agent are hosted side by side', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        services: const [],
      );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('agent-choice-preset:opencode')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      expect(api.serveHosts.map((h) => (h.name, h.provider)), [
        ('default', 'codex'),
        ('opencode', 'acp'),
      ]);
      // Each card leads with its own agent's mark, from its profile.
      expect(
        find.descendant(
          of: find.byKey(const Key('local-host-icon-default')),
          matching: find.byKey(const Key('agent-icon-codex')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('local-host-icon-opencode')),
          matching: find.byKey(const Key('agent-icon-opencode')),
        ),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('with a remote device selected, an existing local host still '
      'leaves hosting one tap away', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        services: const [
          ServiceEntry(
            device: 'peer',
            kind: 'app',
            name: 'default',
            key: 'pcx:peer:app:default',
          ),
        ],
      );
      await api.appServeStart(port: 18080, name: 'default', embedded: false);
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('device-peer')));
      await t.pumpAndSettle();
      // The local hosting card belongs to this machine and is not shown
      // under the peer, but the title bar still offers hosting.
      expect(find.byKey(const Key('add-local-host-card')), findsNothing);
      expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
      await t.tap(find.byKey(const Key('host-this-device-btn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.map((h) => h.name), ['default', 'default-2']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('hosting stays reachable while discovery fails or loads', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
      )..discoverError = StateError('relay unreachable');
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
      // And during the initial load, held pending on purpose.
      await t.pumpWidget(const SizedBox());
      api.discoverError = null;
      final discovery = Completer<void>();
      api.discoverGate = discovery;
      final callsBefore = api.discoverCalls;
      await t.pumpWidget(host(const ServicesScreen(), api));
      // The skeleton animates while loading: bounded frames only.
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(api.discoverCalls, greaterThan(callsBefore));
      expect(discovery.isCompleted, isFalse);
      expect(find.byType(ListLoadingSkeleton), findsOneWidget);
      expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
      // The action works mid-load.
      await t.tap(find.byKey(const Key('host-this-device-btn')));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('start-hosting-btn')), findsOneWidget);
      discovery.complete();
      api.discoverGate = null;
      await t.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the title-bar hosting action is desktop only', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        services: const [
          ServiceEntry(
            device: 'peer',
            kind: 'app',
            name: 'default',
            key: 'pcx:peer:app:default',
          ),
        ],
      );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('host-this-device-btn')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host card is hidden on mobile', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('add-local-host-card')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('注销: cancel keeps the service, confirm removes it', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'acking-you',
      ),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    // The list card (the wide layout ALSO shows the name in the detail pane,
    // so presence is asserted on the card key, absence on the text).
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );

    // Open the card overflow menu → 注销 → cancel: nothing happens.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:lb7666:api:default')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('deregister-dialog')), findsOneWidget);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(api.lastDeregistered, isNull);
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );

    // Re-open → confirm: the service is deregistered + leaves the list.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:lb7666:api:default')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('deregister-confirm-btn')));
    await t.pumpAndSettle();
    expect(api.lastDeregistered, 'pcx:lb7666:api:default');
    expect(find.text('API'), findsNothing);
  });

  testWidgets('注销 on an unreachable remote entry dismisses it, staying '
      'hidden even while the relay still lists it', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(
              relay: '',
              hasKey: false,
              mode: 'account',
              accountLogin: 'acking-you',
            ),
            services: const [
              ServiceEntry(
                device: 'otherdev',
                kind: 'api',
                name: 'orphan',
                key: 'pcx:otherdev:api:orphan',
              ),
            ],
          )
          // Unreachable => the honest "remove" path; and the backend can't drop it
          // (the key lingers on the relay even after the DELETE).
          ..reachable['pcx:otherdev:api:orphan'] = false
          ..keepOnDeregister = true;
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    expect(
      find.byKey(const Key('device-capability-pcx:otherdev:api:orphan')),
      findsOneWidget,
    );

    // Overflow → 注销 → the honest "remove unreachable" dialog → confirm.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:otherdev:api:orphan')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    expect(find.text('移除该不可达服务？'), findsOneWidget);
    await t.tap(find.byKey(const Key('deregister-confirm-btn')));
    await t.pumpAndSettle();

    // Best-effort backend drop still attempted; and even though discovery STILL
    // lists the key, the durable dismiss keeps it hidden from the list.
    expect(api.lastDeregistered, 'pcx:otherdev:api:orphan');
    expect(find.text('orphan'), findsNothing);
  });

  testWidgets('a dismissed entry re-appears once it is reachable again '
      '(recovered in place)', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(
              relay: '',
              hasKey: false,
              mode: 'account',
              accountLogin: 'acking-you',
            ),
            services: const [
              ServiceEntry(
                device: 'otherdev',
                kind: 'api',
                name: 'orphan',
                key: 'pcx:otherdev:api:orphan',
              ),
            ],
          )
          ..reachable['pcx:otherdev:api:orphan'] = false
          ..keepOnDeregister = true;
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    // Dismiss the unreachable orphan.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:otherdev:api:orphan')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('deregister-confirm-btn')));
    await t.pumpAndSettle();
    expect(find.text('orphan'), findsNothing);

    // The backend recovers behind the still-registered key. A re-probe lifts the
    // durable dismissal — reachability, not discovery-absence, is the un-hide
    // signal, so a recovered-in-place service is never stranded.
    api.reachable['pcx:otherdev:api:orphan'] = true;
    await t.tap(find.byKey(const Key('refresh-btn')));
    await t.pumpAndSettle();
    expect(
      find.byKey(const Key('device-capability-pcx:otherdev:api:orphan')),
      findsOneWidget,
    );
  });

  testWidgets('a registered-but-dead API proxy reads "unreachable", not '
      '"online"', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    )..reachable['pcx:lb7666:api:default'] = false; // proxy probe fails
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 900); // narrow: single-pane list
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle(); // let the API probe resolve
    await openDevice(t);

    // The probe says the proxy is dead → honest "不可达" on the API service…
    expect(find.text('不可达'), findsOneWidget);
    // …and spells out that the dead link is the remote API service.
    expect(find.textContaining('远端 API 服务没有响应'), findsOneWidget);
  });

  testWidgets('app-server auto-re-probes: a recovered server flips to online '
      'without a manual refresh', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
            services: const [
              ServiceEntry(
                device: 'lb7666',
                kind: 'app',
                name: 'default',
                key: 'pcx:lb7666:app:default',
              ),
            ],
          )
          ..reachable['pcx:lb7666:app:default'] =
              false; // starts registered-but-dead
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 900); // narrow: single-pane list
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    expect(find.text('不可达'), findsOneWidget); // honest dead status

    // The remote app-server comes back up out from under us...
    api.reachable['pcx:lb7666:app:default'] = true;
    // ...and the periodic re-probe picks it up with NO manual refresh tap.
    await t.pump(const Duration(seconds: 16)); // fire the 15s re-probe timer
    await t.pumpAndSettle(); // let the fresh probe resolve

    expect(find.text('不可达'), findsNothing); // recovered on its own
    expect(find.text('在线'), findsOneWidget); // the app-server reads online
  });

  testWidgets('Manage services agrees with a conversation that lost its link', (
    t,
  ) async {
    // The bug: the services list read `appIsConnected`, a CACHED health flag on
    // the session object, and short-circuited to a green "connected" on it. A
    // link that had actually dropped still satisfied that flag, so this row
    // stayed green while the conversation on top of it showed "reconnecting" —
    // two screens reporting opposite states for one service.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    // Connected as far as the session object is concerned.
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    final container = ProviderScope.containerOf(
      t.element(find.byType(ServicesScreen)),
    );
    // Every kind is listed under the device at once, so the app-server
    // capability a conversation runs on is on screen already.
    // Baseline: the stale flag alone reads as connected.
    expect(find.text('已连接'), findsOneWidget); // statusConnected

    // A conversation observes the link go down — what the session screen
    // publishes when it enters reconnect or gives up.
    container.read(observedDisconnectedProvider.notifier).state = {
      'pcx:lb7666:app:default',
    };
    await t.pumpAndSettle();

    // The list now agrees instead of contradicting the transcript.
    expect(find.text('已连接'), findsNothing);
    expect(find.text('不可达'), findsOneWidget); // statusUnreachable
  });

  testWidgets('Manage services keeps theme switching in the page menu', (
    t,
  ) async {
    // Secondary desktop pages keep cross-page + appearance controls in one
    // quiet menu instead of repeating a row of unrelated icon buttons.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(1200, 900);
      addTearDown(t.view.reset);
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('theme-toggle-btn')), findsNothing);
      expect(find.byKey(const Key('utility-page-menu')), findsOneWidget);
      await t.tap(find.byKey(const Key('utility-page-menu')));
      await t.pumpAndSettle();
      expect(find.text('页面'), findsOneWidget);
      expect(find.text('暗黑'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('ApiService rejects an out-of-range port before subscribing', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await t.pumpWidget(
      host(
        const Scaffold(
          body: ApiServicePanel(serviceKey: 'pcx:lb7666:api:default'),
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // 70000 parses as an int but exceeds u16; must be rejected client-side.
    await t.enterText(find.byType(TextField), '70000');
    await t.tap(find.byKey(const Key('subscribe-btn')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('api-error')), findsOneWidget);
    // Still on the subscribe form (no base-url shown) — nothing was subscribed.
    expect(find.byKey(const Key('base-url')), findsNothing);
  });

  testWidgets('App-server tile is tappable (not disabled)', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    // carries an onTap (a disabled row would have a null callback). The card's
    // own InkWell is the first descendant (the deregister overflow menu adds its
    // own InkWell deeper in the tree).
    final ink = t
        .widgetList<InkWell>(
          find.descendant(
            of: find.byKey(
              const Key('device-capability-pcx:lb7666:app:default'),
            ),
            matching: find.byType(InkWell),
          ),
        )
        .first;
    expect(ink.onTap, isNotNull);
  });

  testWidgets('Services renders English strings under Locale(en)', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    );
    await t.pumpWidget(
      host(const ServicesScreen(), api, locale: const Locale('en')),
    );
    await t.pumpAndSettle();
    // English ARB values, proving the locale switch changes strings. The relay
    // banner's status pill reads "Online" (en) rather than "在线" (zh).
    expect(find.text('Online'), findsWidgets);
    expect(find.text('在线'), findsNothing);
  });

  testWidgets('Services list shows availability + subscription status', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'other',
          key: 'pcx:lb7666:api:other',
        ),
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    // One API service is subscribed (alive) → it reads "subscribed"; the rest
    // are merely registered → "online".
    await api.apiSubscribe('pcx:lb7666:api:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(500, 900); // narrow → single list pane
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    expect(find.text('已订阅'), findsOneWidget); // subscribedAlive (zh)
    expect(find.text('在线'), findsWidgets); // relay + unsubscribed api + app
    expect(find.byType(StatusDot), findsWidgets); // availability dots render
    expect(find.byType(PulsingDot), findsNothing); // nothing running
  });

  testWidgets('Services refresh button re-runs discovery', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(500, 900);
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    expect(find.text('App-server'), findsOneWidget);

    // Tapping refresh re-discovers (skeleton flashes, then data) without error.
    await t.tap(find.byKey(const Key('refresh-btn')));
    await t.pumpAndSettle();
    expect(find.text('App-server'), findsOneWidget);
  });

  testWidgets('Services screen shows a loading skeleton before data', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );

    await t.pumpWidget(host(const ServicesScreen(), api));
    // First frame: discovery future hasn't resolved → skeleton.
    expect(find.byType(ListLoadingSkeleton), findsOneWidget);
    await t.pumpAndSettle();
    // Data arrived → skeleton gone, the capability is listed.
    expect(find.byType(ListLoadingSkeleton), findsNothing);
    await openDevice(t);
    expect(find.text('App-server'), findsOneWidget);
  });
}
