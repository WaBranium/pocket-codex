part of '../composer_recovery_test.dart';

void _registerConnectionHistory() {
  // A history read the previous host connection answers after it was lost
  // or replaced shows nothing, settles nothing and sends nothing — whether
  // the reconnect is waiting to connect, cannot start yet (backgrounded,
  // debounced) or is already running — and the current connection's own
  // reload then recovers the conversation exactly once.
  group('an old connection\'s history answer', () {
    const running = ThreadHistory(items: [], running: true, activeTurnId: 'a');
    const stale = ThreadHistory(
      items: [],
      running: true,
      activeTurnId: 'stale',
    );
    const idle = ThreadHistory(items: [], running: false);

    /// The old answer showed nothing and released nothing.
    void unchanged(FakeBridgeApi api) {
      expect(
        find.byKey(const Key('stop-btn')),
        findsNothing,
        reason: 'its running state is not shown',
      );
      expect(api.turnStartCount, 1, reason: 'it released nothing');
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
    }

    for (final (oldAnswer, newAnswer) in [(stale, idle), (idle, running)]) {
      final label = oldAnswer.running ? 'running' : 'idle';
      testWidgets('an old $label answer while the replacement connects', (
        t,
      ) async {
        final api = await admittedWithoutStart(
          t,
          service: acp,
          thread: 'ses-1',
        );
        final old = Completer<ThreadHistory>();
        api.pendingReads['ses-1'] = [old.future];
        // The reconciliation's reload now waits on the old connection.
        await pastGrace(t);
        final connect = Completer<void>();
        api.appConnectGate = connect.future;
        await hostChange(t, api, 2);
        old.complete(oldAnswer);
        await frames(t);
        unchanged(api);

        api.readResult = newAnswer;
        connect.complete();
        await seconds(t, 4);
        if (newAnswer.running) {
          // The current host says "a" runs: it is followed, and the queue
          // waits for its end.
          expect(find.byKey(const Key('stop-btn')), findsOneWidget);
          await t.tap(find.byKey(const Key('stop-btn')));
          await frames(t);
          expect(api.lastInterruptTurnId, 'a', reason: 'never "stale"');
          expect(api.turnStartCount, 1);
        } else {
          expect(api.turnStartCount, 2, reason: 'recovered once');
          expect(api.lastTurnText, 'second');
          expect(find.byKey(const Key('queued-0')), findsNothing);
          await pastGrace(t);
          expect(api.turnStartCount, 2, reason: '"second" awaits its own');
        }
      });
    }

    testWidgets('an old answer while the app is in the background', (t) async {
      final api = await admittedWithoutStart(t, service: acp, thread: 'ses-1');
      final old = Completer<ThreadHistory>();
      api.pendingReads['ses-1'] = [old.future];
      await pastGrace(t);
      final binding = t.binding;
      binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final connects = api.appConnectCount;
      await hostChange(t, api, 2);
      expect(api.appConnectCount, connects, reason: 'no reconnect yet');
      old.complete(stale);
      await frames(t);
      unchanged(api);

      binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await seconds(t, 4);
      expect(api.appConnectCount, connects + 1, reason: 'on return');
      expect(api.turnStartCount, 2, reason: 'recovered once');
      expect(api.lastTurnText, 'second');
    });

    testWidgets('an old answer while a reconnect is already running', (
      t,
    ) async {
      final api = await admittedWithoutStart(t, service: acp, thread: 'ses-1');
      final old = Completer<ThreadHistory>();
      // The first replacement's own reload waits on it...
      api.pendingReads['ses-1'] = [old.future];
      await hostChange(t, api, 2);
      // ...when the host is replaced again.
      await hostChange(t, api, 3);
      old.complete(stale);
      await frames(t);
      unchanged(api);
      // That reconnect notices it is not current and tries again.
      await seconds(t, 4);
      expect(api.turnStartCount, 2, reason: 'recovered once');
      expect(api.lastTurnText, 'second');
      await seconds(t, 4);
      expect(api.turnStartCount, 2);
    });

    // A running reconnect's own history read is outrun by a second change:
    // only another generation (the host is neither lost nor replaced), or
    // the host lost. The reconnect does not report ready on that read, its
    // loading flags do not linger, and it asks the current host once more:
    // exactly one recovery, with a composer that works afterwards.
    for (final second in ['generation', 'lost']) {
      testWidgets('a reconnect whose read is outrun ($second) retries', (
        t,
      ) async {
        final api = await admittedWithoutStart(
          t,
          service: acp,
          thread: 'ses-1',
        );
        final old = Completer<ThreadHistory>();
        api.pendingReads['ses-1'] = [old.future];
        await hostChange(t, api, 2);
        final reads = api.threadReads.length;
        api.acpCapabilities[acp] = acpCapsOf(generation: 3);
        api.pushEvent(
          acp,
          AppEvent(
            kind: 'acp/host/state',
            raw: second == 'lost'
                ? '{"connected":false}'
                : '{"generation":3,"connected":true,"replaced":false}',
          ),
        );
        await frames(t);
        expect(
          api.threadReads.length,
          reads,
          reason: 'the running reconnect owns the next read',
        );
        old.complete(stale);
        await frames(t);
        unchanged(api);
        api.readResult = idle;
        await seconds(t, 6);
        expect(api.threadReads.length, greaterThan(reads), reason: 'retried');
        expect(api.turnStartCount, 2, reason: 'recovered once');
        expect(api.lastTurnText, 'second');
        expect(find.byKey(const Key('queued-0')), findsNothing);
        // Nothing left the composer blocked: an ordinary send goes after the
        // admitted turn's own end.
        api.pushEvent(acp, turn('turn/started', 'ses-1', 'b'));
        api.pushEvent(acp, turn('turn/completed', 'ses-1', 'b'));
        await frames(t);
        await type(t, 'third');
        await send(t);
        expect(api.turnStartCount, 3);
        expect(api.lastTurnText, 'third');
        await seconds(t, 4);
        expect(api.turnStartCount, 3, reason: 'nothing replayed');
      });
    }

    testWidgets('an old answer while the reconnect is debounced', (t) async {
      final api = FakeBridgeApi()
        ..autoCompleteTurn = false
        ..announceTurnStart = false
        ..acpCapabilities[acp] = acpCapsOf();
      await api.appConnect(acp, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
      );
      await frames(t);
      // A first replacement reconnects at once, starting the 3 s window.
      final connects = api.appConnectCount;
      await hostChange(t, api, 2);
      expect(api.appConnectCount, connects + 1);
      await type(t, 'first');
      await send(t);
      await type(t, 'second');
      await send(t);
      expect(api.turnStartCount, 1);
      final old = Completer<ThreadHistory>();
      api.pendingReads['ses-1'] = [old.future];
      api.pushEvent(
        acp,
        const AppEvent(kind: 'thread/compacted', threadId: 'ses-1', raw: '{}'),
      );
      await frames(t);
      await hostChange(t, api, 3);
      expect(api.appConnectCount, connects + 1, reason: 'debounced');
      old.complete(idle);
      await frames(t);
      unchanged(api);
      // The health check (every 12 s) starts the reconnect; its reload, from
      // the current host, settles "first" once.
      await t.pump(const Duration(seconds: 13));
      await seconds(t, 4);
      expect(api.appConnectCount, connects + 2);
      expect(api.turnStartCount, 2);
      expect(api.lastTurnText, 'second');
    });
  });
}
