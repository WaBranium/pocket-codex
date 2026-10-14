import 'dart:async';
import 'dart:convert';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/image_attachments.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/widgets/session_control_dialog.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

const service = 'pcx:control:acp:claude';
const thread = 'original-session';
const released = SessionControl(
  sessionId: thread,
  hostId: 'owner',
  generation: 7,
  sourceGeneration: 'source-one',
  provider: 'claude',
  status: 'released',
  canContinue: false,
  canRelease: false,
  canAcquire: true,
);
const owned = SessionControl(
  sessionId: thread,
  hostId: 'owner',
  generation: 7,
  provider: 'claude',
  status: 'owned',
  canContinue: true,
  canRelease: true,
  canAcquire: false,
);

class ControlApi extends FakeBridgeApi {
  SessionControl view = released;
  Completer<SessionControl>? pendingView;
  final operations = <(String, SessionControl, String)>[];

  @override
  Future<SessionControl> appAcpSessionControl(String key, String id) async =>
      pendingView?.future ?? view;

  @override
  Future<void> appAcpControlSession(
    String key,
    SessionControl snapshot,
    String action,
  ) async {
    operations.add((key, snapshot, action));
    appThreadResumeError = action == 'release'
        ? StateError('native history is read-only')
        : null;
  }
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> openChat(
  WidgetTester t,
  ControlApi api, {
  bool readOnly = true,
}) async {
  t.view.physicalSize = const Size(1280, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  api.acpCapabilities[service] = negotiatedAcpCapabilities(
    providerName: 'Claude',
    generation: 7,
    nativeHistory: true,
  );
  api.metadataOnlyFollow = true;
  api.liveness[thread] = const SessionLiveness(
    threadId: thread,
    turnState: 'idle',
    heldOpen: false,
    safety: 'nativeUnknown',
    allowsResume: false,
    requiresTakeover: false,
    holders: [],
  );
  if (readOnly) {
    api.appThreadResumeError = StateError('native history is read-only');
  }
  api.readResult = const ThreadHistory(
    running: false,
    cwd: '/project',
    items: [],
    historyEpoch: 'source-one',
  );
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(const AppSessionScreen(serviceKey: service, threadId: thread), api),
  );
  await frames(t);
}

Future<void> disposeChat(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await frames(t);
  expect(t.takeException(), isNull);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'refresh removes old authority and returns exactly the newly displayed snapshot',
    (t) async {
      final pending = Completer<SessionControl>();
      var calls = 0;
      SessionControlChoice? result;
      await t.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<SessionControlChoice>(
                  context: context,
                  builder: (_) => SessionControlDialog(
                    load: () async {
                      calls++;
                      return calls == 1 ? owned : pending.future;
                    },
                  ),
                );
              },
              child: const Text('Inspect'),
            ),
          ),
          FakeBridgeApi(),
        ),
      );
      await t.tap(find.text('Inspect'));
      await frames(t);
      expect(find.byKey(const Key('session-control-release')), findsOneWidget);
      await t.tap(find.byKey(const Key('session-control-refresh')));
      await t.pump();
      expect(find.byKey(const Key('session-control-release')), findsNothing);
      expect(find.byKey(const Key('session-control-acquire')), findsNothing);
      pending.complete(released);
      await frames(t);
      await t.tap(find.byKey(const Key('session-control-acquire')));
      await frames(t);
      expect(result?.snapshot, same(released));
      expect(result?.action, 'acquire');
      await disposeChat(t);
    },
  );

  testWidgets(
    'external OpenCode engine explains the boundary without offering a second writer',
    (t) async {
      await t.pumpWidget(
        host(
          SessionControlDialog(
            load: () async => const SessionControl(
              sessionId: thread,
              hostId: 'owner',
              generation: 7,
              provider: 'opencode',
              status: 'engine_required',
              canContinue: false,
              canRelease: false,
              canAcquire: false,
            ),
          ),
          FakeBridgeApi(),
        ),
      );
      await frames(t);
      final l10n = AppLocalizations.of(
        t.element(find.byType(SessionControlDialog)),
      );
      expect(find.text(l10n.sessionControlEngineRequired), findsOneWidget);
      for (final action in ['acquire', 'release', 'continue']) {
        expect(find.byKey(Key('session-control-$action')), findsNothing);
      }
      expect(t.takeException(), isNull);
      await disposeChat(t);
    },
  );

  testWidgets(
    'opening native history never claims; explicit acquire sends its immutable snapshot',
    (t) async {
      final api = ControlApi();
      await openChat(t, api);
      expect(api.operations, isEmpty);
      expect(api.lastResumed, isNull);
      await t.tap(find.byKey(const Key('chat-session-control')));
      await frames(t);
      expect(api.operations, isEmpty);
      await t.tap(find.byKey(const Key('session-control-acquire')));
      await frames(t);
      expect(api.operations, [(service, released, 'acquire')]);
      expect(api.lastResumed, thread);
      expect(find.byKey(const Key('chat-read-only-action')), findsNothing);
      expect(api.turnStartCount, 0);
      await disposeChat(t);
    },
  );

  testWidgets(
    'generation change while the dialog waits cannot apply its old snapshot',
    (t) async {
      final api = ControlApi()..pendingView = Completer<SessionControl>();
      await openChat(t, api);
      await t.tap(find.byKey(const Key('chat-session-control')));
      await frames(t);
      api.acpCapabilities[service] = negotiatedAcpCapabilities(
        providerName: 'Claude',
        generation: 8,
        nativeHistory: true,
      );
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"generation":8,"connected":true}',
        ),
      );
      await frames(t);
      api.pendingView!.complete(released);
      await frames(t);
      expect(find.byKey(const Key('session-control-acquire')), findsNothing);
      expect(api.operations, isEmpty);
      final l10n = AppLocalizations.of(
        t.element(find.byType(SessionControlDialog)),
      );
      expect(find.textContaining(l10n.sessionControlChanged), findsOneWidget);
      await disposeChat(t);
    },
  );

  testWidgets(
    'another controller releasing preserves the draft and blocks sends until explicit continuation',
    (t) async {
      final api = ControlApi()..view = owned;
      await openChat(t, api, readOnly: false);
      await t.enterText(
        find.byKey(const Key('composer-input')),
        'Keep my unsent draft',
      );
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'acp/session/updated',
          threadId: thread,
          raw:
              '{"sessionId":"original-session","admitted":true,"pending":true,"releasing":true}',
        ),
      );
      await frames(t);
      expect(find.byKey(const Key('chat-read-only-action')), findsOneWidget);
      expect(find.byKey(const Key('composer-input')), findsNothing);
      expect(api.turnStartCount, 0);
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'acp/session/updated',
          threadId: thread,
          raw: '{"sessionId":"original-session","admitted":false}',
        ),
      );
      await frames(t);
      await t.tap(find.byKey(const Key('chat-session-control')));
      await frames(t);
      await t.tap(find.byKey(const Key('session-control-continue')));
      await frames(t);
      expect(
        t
            .widget<TextField>(find.byKey(const Key('composer-input')))
            .controller!
            .text,
        'Keep my unsent draft',
      );
      expect(api.turnStartCount, 0);
      expect(api.operations.single.$3, 'continue');
      await disposeChat(t);
    },
  );
  testWidgets(
    'release keeps queued images and a newer draft through explicit continuation',
    (t) async {
      final api = ControlApi()
        ..view = owned
        ..autoCompleteTurn = false;
      await openChat(t, api, readOnly: false);
      api.acpCapabilities[service] = negotiatedAcpCapabilities(
        providerName: 'Claude',
        generation: 7,
        nativeHistory: true,
        imageInput: true,
      );
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"connected":true,"generation":7}',
        ),
      );
      await frames(t);
      await t.enterText(find.byKey(const Key('composer-input')), 'first');
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await frames(t);
      expect(api.turnStartCount, 1);
      final previousPicker = fsel.FileSelectorPlatform.instance;
      final picker = FakeFileSelector();
      fsel.FileSelectorPlatform.instance = picker;
      addTearDown(() => fsel.FileSelectorPlatform.instance = previousPicker);
      final previousProcess = processImageImpl;
      processImageImpl = (bytes) async => processImageBytes(bytes);
      addTearDown(() => processImageImpl = previousProcess);
      final queuedImage = tinyPng(red: 80);
      picker.files = [MemXFile(queuedImage, 'queued.png')];
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-file-btn')));
      await frames(t);
      await t.enterText(
        find.byKey(const Key('composer-input')),
        'queued original',
      );
      await t.pump();
      await t.tap(find.byKey(const Key('send-btn')));
      await frames(t);
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      final draftImage = tinyPng(red: 40);
      picker.files = [MemXFile(draftImage, 'draft.png')];
      void expectDraftImage() {
        final image = t.widget<Image>(
          find.descendant(
            of: find.byKey(const Key('attachment-1')),
            matching: find.byType(Image),
          ),
        );
        final provider = image.image as ResizeImage;
        expect(
          (provider.imageProvider as MemoryImage).bytes,
          orderedEquals(draftImage),
        );
      }

      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-file-btn')));
      await frames(t);
      await t.enterText(find.byKey(const Key('composer-input')), 'newer draft');
      api.pushEvent(
        service,
        const AppEvent(
          kind: 'acp/session/updated',
          threadId: thread,
          raw: '{"sessionId":"original-session","admitted":false}',
        ),
      );
      api.pushEvent(
        service,
        const AppEvent(kind: 'turn/completed', threadId: thread, raw: '{}'),
      );
      await frames(t);
      expect(
        api.turnStartCount,
        1,
        reason: 'release cannot drain the queued image',
      );
      expect(find.byKey(const Key('chat-read-only-action')), findsOneWidget);
      await t.tap(find.byKey(const Key('chat-session-control')));
      await frames(t);
      await t.tap(find.byKey(const Key('session-control-continue')));
      await frames(t);
      expect(
        t
            .widget<TextField>(find.byKey(const Key('composer-input')))
            .controller!
            .text,
        'newer draft',
      );
      expectDraftImage();
      if (api.turnStartCount == 1) {
        expect(find.byKey(const Key('queued-0')), findsOneWidget);
        api.pushEvent(
          service,
          const AppEvent(kind: 'turn/completed', threadId: thread, raw: '{}'),
        );
        await frames(t);
      }
      expect(api.turnStartCalls, hasLength(2));
      final call = api.turnStartCalls.last;
      expect((call.$1, call.$2, call.$3), (service, thread, 'queued original'));
      expect(call.$4, ['data:image/png;base64,${base64Encode(queuedImage)}']);
      expectDraftImage();
      await disposeChat(t);
    },
  );
}
