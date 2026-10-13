part of '../composer_recovery_test.dart';

void _registerReconciliation() {
  group('an admission whose start never arrived', () {
    testWidgets('a failed reconciliation keeps it; a later idle one releases '
        'it and the queue continues once', (t) async {
      final api = await admittedWithoutStart(t);
      api.appThreadResumeError = StateError(
        'the agent host could not be '
        'reached',
      );
      await pastGrace(t);
      expect(api.turnStartCount, 1, reason: 'a failed reload decides nothing');
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      // Time alone never drains it either.
      await pastGrace(t);
      expect(api.turnStartCount, 1);

      api.appThreadResumeError = null;
      await pastGrace(t);
      expect(api.turnStartCount, 2, reason: 'the idle reload released it');
      expect(api.lastTurnText, 'second');
      expect(find.byKey(const Key('queued-0')), findsNothing);
      await pastGrace(t);
      expect(api.turnStartCount, 2, reason: 'the next admission waits again');
    });

    testWidgets('a running reconciliation follows the turn; its end drains '
        'the queue', (t) async {
      final api = await admittedWithoutStart(t);
      api.readResult = const ThreadHistory(
        items: [],
        running: true,
        activeTurnId: 'a',
      );
      await pastGrace(t);
      expect(find.byKey(const Key('stop-btn')), findsOneWidget);
      expect(api.turnStartCount, 1);
      await t.tap(find.byKey(const Key('stop-btn')));
      await frames(t);
      expect(api.lastInterruptTurnId, 'a', reason: 'Stop names that turn');

      api.readResult = const ThreadHistory(items: [], running: false);
      api.pushEvent(codex, turn('turn/completed', 't1', 'a'));
      await frames(t);
      expect(api.turnStartCount, 2);
      expect(api.lastTurnText, 'second');
    });

    testWidgets('a host replacement settles it through the reconnect reload', (
      t,
    ) async {
      final api = await admittedWithoutStart(t, service: acp, thread: 'ses-1');
      await hostChange(t, api, 2);
      await seconds(t, 6);
      expect(api.turnStartCount, 2, reason: 'the reload found it idle');
      expect(api.lastTurnText, 'second');
    });

    testWidgets('a newer admission outlives an older reconciliation', (
      t,
    ) async {
      final api = await admittedWithoutStart(t, third: true);
      final held = Completer<ThreadHistory>();
      api.pendingReads['t1'] = [held.future];
      await pastGrace(t);
      // While that reload is held, the turn starts and ends; the queue
      // waits for the reload (history is syncing) and then sends "second",
      // whose own start is now awaited.
      api
        ..pushEvent(codex, turn('turn/started', 't1', 'a'))
        ..pushEvent(codex, turn('turn/completed', 't1', 'a'));
      await frames(t);
      held.complete(const ThreadHistory(items: [], running: false));
      await frames(t);
      expect(api.turnStartCount, 2);
      expect(api.lastTurnText, 'second');
      // The older reload's idle answer is not "second"'s.
      await frames(t);
      expect(api.turnStartCount, 2, reason: '"third" waits for "second"');
      expect(find.byKey(const Key('queued-1')), findsOneWidget);
      // "second"'s own reconciliation settles it.
      await pastGrace(t);
      expect(api.turnStartCount, 3);
      expect(api.lastTurnText, 'third');
    });

    testWidgets('leaving and reopening waits for the reopened history', (
      t,
    ) async {
      await t.binding.setSurfaceSize(wide);
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = await admittedWithoutStart(t, threads: twoThreads);
      await t.tap(find.byKey(const Key('conv-tile-t2')));
      await frames(t);
      final held = Completer<ThreadHistory>();
      api.pendingReads['t1'] = [held.future];
      await t.tap(find.byKey(const Key('conv-tile-t1')));
      await frames(t);
      await pastGrace(t);
      expect(api.turnStartCount, 1, reason: 'nothing before the history');
      expect(find.byKey(const Key('queued-0')), findsOneWidget);
      held.complete(const ThreadHistory(items: [], running: false));
      await frames(t);
      expect(api.turnStartCount, 2);
      expect(api.lastTurnText, 'second');
      expect(api.lastTurnThread, 't1');
    });
  });
}
