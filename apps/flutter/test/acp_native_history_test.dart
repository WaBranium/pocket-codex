import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

const service = 'pcx:native:acp:claude';
const thread = 'native-session';
const ownership = SessionLiveness(
  threadId: thread,
  turnState: 'unknown',
  heldOpen: false,
  safety: 'nativeUnknown',
  allowsResume: false,
  requiresTakeover: false,
  holders: [],
);

ThreadHistory history(String text, String epoch) => ThreadHistory(
  historyEpoch: epoch,
  running: false,
  cwd: '/project',
  items: [
    ThreadItem(
      id: text,
      turnId: 'turn',
      itemType: 'agentMessage',
      title: '',
      text: text,
    ),
  ],
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);
  testWidgets('release replaces ACP replay only when native history succeeds', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const message = 'One original reply';
    final api = FakeBridgeApi()
      ..metadataOnlyFollow = true
      ..readResult = const ThreadHistory(
        running: false,
        items: [
          ThreadItem(
            id: 'live-item',
            turnId: 'live-turn',
            itemType: 'agentMessage',
            title: '',
            text: message,
          ),
        ],
      );
    api.acpCapabilities[service] = negotiatedAcpCapabilities(
      providerName: 'Claude',
      nativeHistory: true,
    );
    api.liveness[thread] = ownership;
    await api.appConnect(service, 28080);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: service, threadId: thread), api),
    );
    await frames(t);
    expect(find.text(message), findsOneWidget);
    final nativeRead = Completer<ThreadHistory>();
    api.pendingReads[thread] = [nativeRead.future];
    api.pushEvent(
      service,
      const AppEvent(
        kind: 'acp/session/updated',
        threadId: thread,
        raw: '{"sessionId":"native-session","admitted":false}',
      ),
    );
    await frames(t);
    nativeRead.completeError(StateError('temporary native read failure'));
    await frames(t);
    expect(find.text(message), findsOneWidget);
    expect(find.byKey(const Key('chat-read-only-action')), findsOneWidget);

    api.readResult = history(message, 'source-one');
    api.pushMetaSessionUpdate(
      thread,
      const SessionFollowUpdate(
        liveness: ownership,
        items: [],
        historyRevision: 'native-revision',
      ),
    );
    await frames(t);
    expect(find.text(message), findsOneWidget);
    api.readResult = history('Updated original reply', 'source-one');
    api.pushMetaSessionUpdate(
      thread,
      const SessionFollowUpdate(
        liveness: ownership,
        items: [],
        historyRevision: 'next-native-revision',
      ),
    );
    await frames(t);
    expect(find.text(message), findsOneWidget);
    expect(find.text('Updated original reply'), findsOneWidget);
    expect(api.turnStartCount, 0);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    await frames(t);
  });
  testWidgets(
    'native ACP history remains read-only and follows source replacement',
    (t) async {
      t.view.physicalSize = const Size(1280, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api =
          FakeBridgeApi(
              config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
            )
            ..metadataOnlyFollow = true
            ..appThreadResumeError = StateError(
              'native history is read-only; explicitly acquire the session before sending',
            )
            ..readResult = history('Original native message', 'source-one');
      api.acpCapabilities[service] = negotiatedAcpCapabilities(
        providerName: 'Claude',
        nativeHistory: true,
      );
      api.liveness[thread] = ownership;
      await api.appConnect(service, 28080);
      await t.pumpWidget(
        host(
          const AppSessionScreen(serviceKey: service, threadId: thread),
          api,
        ),
      );
      await frames(t);
      expect(find.text('Original native message'), findsOneWidget);
      expect(find.byKey(const Key('chat-read-only-action')), findsOneWidget);
      expect(find.byKey(const Key('chat-takeover-action')), findsNothing);
      final l10n = AppLocalizations.of(
        t.element(find.byType(AppSessionScreen)),
      );
      expect(find.text(l10n.sessionRunningElsewhere), findsNothing);
      expect(find.text(l10n.readOnlyViewing), findsNothing);
      expect(find.text(l10n.nativeHistoryReadOnly), findsNWidgets(2));
      expect(find.byKey(const Key('chat-session-control')), findsOneWidget);
      expect(api.turnStartCount, 0);
      expect(api.lastResumed, isNull);
      expect(api.lastMetaResumedThread, isNull);
      expect(api.metaSessionEventSubscriptions, 1);

      api.readResult = history('Replacement native message', 'source-two');
      api.pushMetaSessionUpdate(
        thread,
        const SessionFollowUpdate(
          liveness: ownership,
          items: [],
          historyRevision: 'source-two-revision',
        ),
      );
      await frames(t);
      expect(find.text('Original native message'), findsNothing);
      expect(find.text('Replacement native message'), findsOneWidget);
      expect(find.byKey(const Key('chat-read-only-action')), findsOneWidget);
      expect(api.turnStartCount, 0);
      for (final state in ['idle', 'running', 'unknown']) {
        api.pushMetaSessionUpdate(
          thread,
          SessionFollowUpdate(
            liveness: SessionLiveness(
              threadId: thread,
              turnState: state,
              heldOpen: state != 'unknown',
              safety: switch (state) {
                'idle' => 'nativeOwnedIdle',
                'running' => 'nativeOwnedRunning',
                _ => 'nativeUnknown',
              },
              allowsResume: false,
              requiresTakeover: false,
              holders: const [],
            ),
            items: const [],
            historyRevision: 'source-two-revision',
          ),
        );
        await frames(t);
        expect(
          find.text(l10n.sessionRunningElsewhere),
          state == 'running' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(l10n.sessionInUseElsewhere),
          state == 'idle' ? findsOneWidget : findsNothing,
        );
        expect(find.byKey(const Key('chat-takeover-action')), findsNothing);
        expect(api.turnStartCount, 0);
        expect(api.lastResumed, isNull);
        expect(api.lastMetaResumedThread, isNull);
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      await frames(t);
    },
  );
}
