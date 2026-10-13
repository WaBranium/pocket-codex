// The composer's controls recover in the same session once a turn ends,
// whatever order its events arrive in: agent options a stale "running"
// state held become usable again, the queue waits for an admitted turn's
// start before sending the next message, a late or repeated terminal event
// never releases it early, and only an authoritative history reload of the
// same conversation, from the current host connection, settles an
// admission whose start never arrived — an older connection's answer
// changes nothing. A failed queued message keeps its text, attachments and
// place: a proven refusal may be retried, any other failure stays uncertain
// — no history answer resolves it — and is sent again only by the user's
// explicit Retry. A send outliving its host connection dispatches nothing
// more and adopts no outcome. Driven through hit-tested taps and typed
// input, with bounded pumps while a turn runs.

import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsel;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/image_attachments.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const acp = 'pcx:dev:acp:agent';
const codex = 'pcx:dev:app:default';

AppCapabilities acpCapsOf({int generation = 1, bool imageInput = false}) =>
    AppCapabilities(
      provider: 'acp',
      fast: false,
      permissionPresets: false,
      guardian: false,
      rateLimits: false,
      takeover: false,
      externalWriterMonitor: false,
      localSessions: false,
      planMode: false,
      protocol: 'acp',
      providerName: 'Agent',
      negotiated: true,
      generation: generation,
      imageInput: imageInput,
      sessionConfig: true,
      permissionOptions: true,
      sessionReopen: 'load',
      sessionList: 'agent',
      runningInventory: 'engine',
    );

SessionSettings settings({required bool running}) => SessionSettings(
  configOptions: const [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: 'fast-1',
      values: [
        SessionConfigValue(value: 'fast-1', name: 'Fast'),
        SessionConfigValue(value: 'large-2', name: 'Large'),
      ],
    ),
  ],
  running: running,
);

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// [n] seconds of reconnect backoff and recovery, then frames.
Future<void> seconds(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(seconds: 1));
  }
  await frames(t);
}

/// Past the 20 s grace an admitted turn's start is waited for, then let the
/// reconciliation it starts run.
Future<void> pastGrace(WidgetTester t) async {
  await t.pump(const Duration(seconds: 21));
  await frames(t);
}

Future<void> type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

Future<void> send(WidgetTester t) async {
  await t.tap(find.byKey(const Key('send-btn')));
  await frames(t);
}

AppEvent turn(String kind, String thread, String id) =>
    AppEvent(kind: kind, threadId: thread, raw: '{"turnId":"$id"}');

String composerText(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

Finder retryButton() => find.widgetWithText(TextButton, '重试').last;

/// The ACP host behind [acp] now answers as [generation]; [replaced] says
/// another host incarnation answers (the bridge's reconcile reports both).
Future<void> hostChange(
  WidgetTester t,
  FakeBridgeApi api,
  int generation, {
  bool replaced = true,
  bool imageInput = false,
}) async {
  api.acpCapabilities[acp] = acpCapsOf(
    generation: generation,
    imageInput: imageInput,
  );
  api.pushEvent(
    acp,
    AppEvent(
      kind: 'acp/host/state',
      raw: '{"generation":$generation,"connected":true,"replaced":$replaced}',
    ),
  );
  await frames(t);
}

/// One recorded turn/start is exactly [text] with [images], to [service]'s
/// [thread].
void expectTurn(
  (String, String, String, List<String>) call, {
  required String service,
  required String thread,
  required String text,
  List<String> images = const [],
}) {
  expect(call.$1, service, reason: 'the service it began on');
  expect(call.$2, thread);
  expect(call.$3, text);
  expect(call.$4, images, reason: 'its images, exactly and in order');
}

const wide = Size(1600, 900);

/// Two conversations in one project, for leaving and reopening `t1`. The
/// sessions pane lists the project of the open conversation (`/work`, from
/// the opened row), so both rows are on screen.
const twoThreads = [
  ThreadMeta(id: 't1', preview: 'one', cwd: '/work', updatedAt: 2),
  ThreadMeta(id: 't2', preview: 'two', cwd: '/work', updatedAt: 1),
];

/// Open [service]'s [thread] and send "first", which is admitted but whose
/// start never arrives; then queue "second" (and "third").
Future<FakeBridgeApi> admittedWithoutStart(
  WidgetTester t, {
  String service = codex,
  String thread = 't1',
  bool third = false,
  List<ThreadMeta> threads = const [],
}) async {
  final api = FakeBridgeApi()
    ..autoCompleteTurn = false
    ..announceTurnStart = false;
  if (service == acp) api.acpCapabilities[acp] = acpCapsOf();
  api.appThreads.addAll(threads);
  await api.appConnect(service, 28080);
  await t.pumpWidget(
    host(AppSessionScreen(serviceKey: service, threadId: thread), api),
  );
  await t.pumpAndSettle();
  await type(t, 'first');
  await send(t);
  await type(t, 'second');
  await send(t);
  if (third) {
    await type(t, 'third');
    await send(t);
  }
  expect(api.turnStartCount, 1, reason: 'nothing raced the admitted turn');
  expect(find.byKey(const Key('queued-0')), findsOneWidget);
  return api;
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'agent options held by a running state work after the turn ends',
    (t) async {
      final api = FakeBridgeApi()
        ..acpCapabilities[acp] = acpCapsOf()
        ..autoCompleteTurn = false;
      api.sessionSettings['$acp|ses-1'] = settings(running: true);
      await api.appConnect(acp, 28080);
      await t.pumpWidget(
        host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
      );
      await frames(t);
      api.pushEvent(acp, turn('turn/started', 'ses-1', 't1'));
      await frames(t);
      // While it runs the option is not offered. (Bounded pumps: a running
      // turn's progress indicator never settles.)
      await t.tap(find.byKey(const Key('agent-config-model')));
      await frames(t);
      expect(find.text('Large'), findsNothing);
      expect(api.sessionConfigCalls, isEmpty);

      // The engine's cached state no longer names the turn once it ended, but
      // no separate session update is delivered.
      api.sessionSettings['$acp|ses-1'] = settings(running: false);
      api.pushEvent(acp, turn('turn/completed', 'ses-1', 't1'));
      await frames(t);
      await t.tap(find.byKey(const Key('agent-config-model')));
      await t.pumpAndSettle();
      await t.tap(find.text('Large').last);
      await t.pumpAndSettle();
      expect(api.sessionConfigCalls, [('ses-1', 'model', 'large-2')]);
    },
  );

  testWidgets(
    'the queue waits for an admitted turn and ignores repeated ends',
    (t) async {
      final api = await admittedWithoutStart(t, third: true);
      expect(find.byKey(const Key('queued-1')), findsOneWidget);

      // A late end of the turn before it does not count.
      api
        ..pushEvent(codex, turn('turn/started', 't1', 'a'))
        ..pushEvent(codex, turn('turn/completed', 't1', 'a'));
      await frames(t);
      expect(api.turnStartCount, 2);
      expect(api.lastTurnText, 'second');
      // "second" is admitted and awaited; a repeated end of "a" is old news.
      api.pushEvent(codex, turn('turn/completed', 't1', 'a'));
      await frames(t);
      expect(api.turnStartCount, 2, reason: 'the queue stays held');
      expect(find.byKey(const Key('queued-1')), findsOneWidget);

      api
        ..pushEvent(codex, turn('turn/started', 't1', 'b'))
        ..pushEvent(codex, turn('turn/completed', 't1', 'b'));
      await frames(t);
      expect(api.turnStartCount, 3);
      expect(api.lastTurnText, 'third');
      expect(find.byKey(const Key('queued-1')), findsNothing);
    },
  );

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

  group('failed and outlived sends', () {
    // Two images with different content and one uploaded file, so a resend can
    // be checked for exactly its own payload, in order.
    final red = tinyPng(red: 10);
    final blue = tinyPng(red: 90);
    const notesPath = '/host/uploads/123/notes.md';

    late FakeImagePicker picker;
    late FakeFileSelector files;
    ImagePickerPlatform? previousPicker;
    fsel.FileSelectorPlatform? previousFiles;
    Future<ProcessedImage> Function(Uint8List)? previousProcess;
    setUp(() {
      previousProcess = processImageImpl;
      // compute() never completes under the fake clock: process inline.
      processImageImpl = (bytes) async => processImageBytes(bytes);
      previousPicker = ImagePickerPlatform.instance;
      previousFiles = fsel.FileSelectorPlatform.instance;
      picker = FakeImagePicker();
      files = FakeFileSelector();
      ImagePickerPlatform.instance = picker;
      fsel.FileSelectorPlatform.instance = files;
    });
    tearDown(() {
      processImageImpl = previousProcess!;
      ImagePickerPlatform.instance = previousPicker!;
      fsel.FileSelectorPlatform.instance = previousFiles!;
    });

    /// Attach [red] and [blue] (one pick) and `notes.md` through the `+` menu,
    /// with bounded pumps (a turn may be running).
    Future<void> attachAll(WidgetTester t) async {
      picker.files = [MemXFile(red, 'red.png'), MemXFile(blue, 'blue.png')];
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-btn')));
      await frames(t);
      files.files = [
        MemXFile(Uint8List.fromList([1, 2, 3]), 'notes.md'),
      ];
      await t.tap(find.byKey(const Key('attach-menu-btn')));
      await frames(t);
      await t.tap(find.byKey(const Key('attach-file-btn')));
      await frames(t);
      for (final id in [0, 1, 2]) {
        expect(find.byKey(Key('attachment-$id')), findsOneWidget);
      }
    }

    final allImages = [
      processImageBytes(red).dataUrl,
      processImageBytes(blue).dataUrl,
    ];
    final secondWithFile = appendFileRefs('second', [notesPath]);

    for (final service in [codex, acp]) {
      final engine = service == codex ? 'Codex' : 'ACP';
      group('$engine: a failed queued message', () {
        /// Queue "second" (with its images and file when [attach]) and
        /// "third" behind a running "first", type "still typing" into the
        /// composer, then end "first" with the next turn/start failing as given.
        Future<FakeBridgeApi> failQueuedSend(
          WidgetTester t, {
          Object? refused,
          Object? lost,
          bool attach = false,
          List<ThreadMeta> threads = const [],
        }) async {
          final api = FakeBridgeApi()..autoCompleteTurn = false;
          if (service == acp) {
            api.acpCapabilities[acp] = acpCapsOf(imageInput: true);
          }
          api.appThreads.addAll(threads);
          await api.appConnect(service, 28080);
          await t.pumpWidget(
            host(AppSessionScreen(serviceKey: service, threadId: 't1'), api),
          );
          await t.pumpAndSettle();
          await type(t, 'first');
          await send(t);
          if (attach) await attachAll(t);
          await type(t, 'second');
          await send(t);
          await type(t, 'third');
          await send(t);
          await type(t, 'still typing');
          api
            ..turnStartError = refused
            ..turnStartLostAnswer = lost;
          api.pushEvent(
            service,
            const AppEvent(kind: 'turn/completed', threadId: 't1', raw: '{}'),
          );
          await frames(t);
          expect(api.turnStartCount, 2, reason: 'tried once');
          return api;
        }

        testWidgets('a proven refusal keeps its place until Retry', (t) async {
          // The agent host's own pre-admission refusal, verbatim.
          final api = await failQueuedSend(
            t,
            refused: 'a turn is already running in this session',
          );
          // Still first in line, not shown as sent, and the queue paused.
          expect(find.byKey(const Key('queued-0')), findsOneWidget);
          expect(find.byKey(const Key('queued-uncertain-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          // Only in its queue chip: not in the rendered conversation. (The
          // bar title falls back to the last text sent or retried.)
          expect(
            find.descendant(
              of: find.byKey(const Key('queued-0')),
              matching: find.text('second'),
            ),
            findsOneWidget,
            reason: 'its queue chip',
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('chat-content')),
              matching: find.text('second'),
            ),
            findsNothing,
            reason: 'not shown as sent',
          );
          expect(find.byKey(const Key('session-error')), findsOneWidget);
          await frames(t);
          expect(api.turnStartCount, 2, reason: 'never replayed by itself');

          await t.tap(retryButton());
          await frames(t);
          expect(api.turnStartCount, 3);
          expect(api.lastTurnText, 'second', reason: 'order preserved');
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(composerText(t), 'still typing');
        });

        for (final phrasing in [
          'request timed out after 30s',
          'the agent did not answer in time',
          'connection reset by peer',
          'something unfamiliar happened',
        ]) {
          testWidgets('"$phrasing" keeps it queued as uncertain', (t) async {
            final api = await failQueuedSend(t, refused: phrasing);
            expect(find.byKey(const Key('queued-0')), findsOneWidget);
            expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
            expect(find.byKey(const Key('queued-1')), findsOneWidget);
            expect(
              composerText(t),
              'still typing',
              reason: 'the newer draft is untouched',
            );
            // Sending more queues behind it and does not replay it.
            await type(t, 'fourth');
            await send(t);
            expect(api.turnStartCount, 2, reason: 'never replayed by itself');
            expect(find.byKey(const Key('queued-2')), findsOneWidget);
          });
        }

        // A readable history never settles an uncertain message: content is
        // no request identity, the tail is bounded and other writers add to it.
        final histories = <String, ThreadHistory>{
          'a later message of another writer': const ThreadHistory(
            items: [
              ThreadItem(
                id: 'u2',
                itemType: 'userMessage',
                title: '',
                text: 'x',
              ),
              ThreadItem(
                id: 'u3',
                itemType: 'userMessage',
                title: '',
                text: 'from another device',
              ),
            ],
            running: false,
          ),
          'a bounded tail without it': const ThreadHistory(
            items: [],
            running: false,
            hasOlder: true,
          ),
          'an identical earlier prompt': const ThreadHistory(
            items: [
              ThreadItem(
                id: 'u0',
                itemType: 'userMessage',
                title: '',
                text: 'second',
              ),
            ],
            running: false,
          ),
        };
        for (final MapEntry(key: name, value: history) in histories.entries) {
          testWidgets('$name leaves it uncertain and unsent', (t) async {
            final api = await failQueuedSend(t, lost: 'request timed out');
            expect(api.lastTurnText, 'second', reason: 'it reached the host');
            api.readResult = history;
            // A reload of the conversation reads that history.
            api.pushEvent(
              service,
              const AppEvent(
                kind: 'thread/compacted',
                threadId: 't1',
                raw: '{}',
              ),
            );
            await frames(t);
            await pastGrace(t);
            expect(api.turnStartCount, 2, reason: 'nothing resent by itself');
            expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
            expect(find.byKey(const Key('queued-1')), findsOneWidget);
            expect(composerText(t), 'still typing');
            // The reload cleared the banner; its Retry is offered again.
            expect(find.textContaining('不会自动发送'), findsOneWidget);
          });
        }

        testWidgets('Retry resends it exactly as queued, images and file', (
          t,
        ) async {
          final api = await failQueuedSend(
            t,
            lost: 'request timed out',
            attach: true,
          );
          expectTurn(
            api.turnStartCalls[1],
            service: service,
            thread: 't1',
            text: secondWithFile,
            images: allImages,
          );
          expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
          expect(
            find.textContaining('不会自动发送'),
            findsOneWidget,
            reason: 'the banner says it may already have arrived',
          );
          await t.tap(retryButton());
          await frames(t);
          expect(api.turnStartCount, 3);
          expectTurn(
            api.turnStartCalls[2],
            service: service,
            thread: 't1',
            text: secondWithFile,
            images: allImages,
          );
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(composerText(t), 'still typing');
        });

        testWidgets('removing it keeps the rest queued until the user sends', (
          t,
        ) async {
          final api = await failQueuedSend(t, lost: 'request timed out');
          await t.tap(find.byKey(const Key('queued-remove-0')));
          await frames(t);
          expect(find.byKey(const Key('queued-0')), findsNothing);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(api.turnStartCount, 2, reason: 'the paused queue holds');
          await type(t, 'fourth');
          await send(t);
          expect(api.turnStartCount, 3);
          expect(
            api.lastTurnText,
            'third',
            reason: 'the queue resumes in order',
          );
        });

        testWidgets('it survives leaving and reopening, unsent', (t) async {
          await t.binding.setSurfaceSize(wide);
          addTearDown(() => t.binding.setSurfaceSize(null));
          final api = await failQueuedSend(
            t,
            refused: 'request timed out',
            threads: twoThreads,
          );
          await t.tap(find.byKey(const Key('conv-tile-t2')));
          await frames(t);
          await t.tap(find.byKey(const Key('conv-tile-t1')));
          await frames(t);
          expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
          expect(find.byKey(const Key('queued-1')), findsOneWidget);
          expect(api.turnStartCount, 2, reason: 'reopening replays nothing');
          // Its explicit Retry is offered again in the reopened conversation.
          expect(retryButton(), findsOneWidget);
        });
      });
    }

    // Every step of a send belongs to the host connection it began on: a step
    // finishing after that connection was lost or replaced dispatches nothing
    // more and adopts nothing (no queue removal, no admission, no drain). Its
    // input stays the user's: back in its draft, or still queued.
    group('a send outliving its host connection', () {
      /// The notice that put an ordinary message back in the composer.
      Finder returned() => find.textContaining('消息已放回输入框');

      // A session created through a connection that moved (another
      // generation or source of the same service name, or a replaced host)
      // is not known to belong to whichever host answers now: it is never
      // adopted, recorded or listed, and the input stays in its own unsent
      // draft. The user's next send starts a session on the current host.
      for (final replaced in [false, true]) {
        testWidgets('a thread start finishing after a host change '
            '(replaced: $replaced) is not adopted; the input returns', (
          t,
        ) async {
          final api = FakeBridgeApi()..acpCapabilities[acp] = acpCapsOf();
          await api.appConnect(acp, 28080);
          await t.pumpWidget(
            host(const AppSessionScreen(serviceKey: acp, cwd: '/work'), api),
          );
          await t.pumpAndSettle();
          final gate = Completer<void>();
          api.threadStartGate = gate;
          await type(t, 'hello');
          await send(t);
          expect(api.threadStartCalls, [acp]);
          await hostChange(t, api, 2, replaced: replaced);
          gate.complete();
          // The brief notice says so as the late answer arrives...
          await frames(t);
          expect(find.textContaining('没有发送这条消息'), findsOneWidget);
          expect(returned(), findsOneWidget);
          // ...and through the reconnect nothing reaches any host.
          await seconds(t, 4);
          expect(api.turnStartCount, 0, reason: 'nothing to any host');
          expect(composerText(t), 'hello');
          expect(
            find.text('thread-0'),
            findsNothing,
            reason: 'the old connection\'s session is not listed',
          );
          // The user's own send asks the current host for a new session.
          await send(t);
          expect(api.threadStartCalls, [acp, acp]);
          expect(api.turnStartCalls, hasLength(1));
          expectTurn(
            api.turnStartCalls.single,
            service: acp,
            thread: 'thread-1',
            text: 'hello',
          );
        });
      }

      testWidgets('a model list of a new conversation finishing after the '
          'connection dropped starts no session; the input returns', (t) async {
        final api = FakeBridgeApi();
        await api.appConnect(codex, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: codex, cwd: '/work'), api),
        );
        await t.pumpAndSettle();
        await turnSetting(t, 'plan');
        final gate = Completer<void>();
        api.modelListGate = gate;
        await type(t, 'plan this');
        await send(t);
        await api.appDisconnect(codex);
        await frames(t);
        gate.complete();
        await frames(t);
        expect(find.textContaining('没有发送这条消息'), findsOneWidget);
        expect(returned(), findsOneWidget);
        await seconds(t, 4);
        expect(api.threadStartCalls, isEmpty, reason: 'no session anywhere');
        expect(api.turnStartCount, 0);
        expect(composerText(t), 'plan this');
        await send(t);
        expect(api.threadStartCalls, [codex]);
        expect(api.turnStartCalls, hasLength(1));
        expectTurn(
          api.turnStartCalls.single,
          service: codex,
          thread: 'thread-0',
          text: 'plan this',
        );
        expect(api.lastCollaborationMode, 'plan');
      });

      testWidgets('a model list finishing after the connection dropped sends '
          'nothing; the input returns', (t) async {
        final api = FakeBridgeApi();
        await api.appConnect(codex, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: codex, threadId: 't1'), api),
        );
        await t.pumpAndSettle();
        // Plan mode needs a concrete model, resolved from the list on send.
        await turnSetting(t, 'plan');
        final gate = Completer<void>();
        api.modelListGate = gate;
        await type(t, 'plan this');
        await send(t);
        // The event stream closes: the view reconnects meanwhile.
        await api.appDisconnect(codex);
        await frames(t);
        gate.complete();
        await frames(t);
        expect(returned(), findsOneWidget);
        await seconds(t, 4);
        expect(api.turnStartCount, 0);
        expect(composerText(t), 'plan this');
        await send(t);
        expect(api.turnStartCalls, hasLength(1));
        expectTurn(
          api.turnStartCalls.single,
          service: codex,
          thread: 't1',
          text: 'plan this',
        );
        expect(api.lastCollaborationMode, 'plan');
      });

      testWidgets('an answer after a host change is not adopted; the input '
          'returns', (t) async {
        final api = FakeBridgeApi()
          ..acpCapabilities[acp] = acpCapsOf()
          ..autoCompleteTurn = false
          ..announceTurnStart = false;
        await api.appConnect(acp, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: acp, threadId: 'ses-1'), api),
        );
        await t.pumpAndSettle();
        final gate = Completer<void>();
        api.turnStartGate = gate;
        await type(t, 'hello');
        await send(t);
        await hostChange(t, api, 2, replaced: false);
        gate.complete();
        await frames(t);
        expect(composerText(t), 'hello', reason: 'kept for the user');
        // In the composer only: the rendered conversation holds no
        // optimistic copy. (The bar title falls back to the last text sent.)
        expect(
          find.descendant(
            of: find.byKey(const Key('composer-input')),
            matching: find.text('hello'),
          ),
          findsOneWidget,
          reason: 'kept in the composer',
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('chat-content')),
            matching: find.text('hello'),
          ),
          findsNothing,
          reason: 'no optimistic copy',
        );
        expect(find.textContaining('无法确定'), findsOneWidget);
        expect(find.byKey(const Key('stop-btn')), findsNothing);
        expect(api.turnStartCalls, hasLength(1), reason: 'never resent');
        // Not awaiting any admission and not locked: the user's send goes.
        await send(t);
        expect(api.turnStartCalls, hasLength(2));
        expectTurn(
          api.turnStartCalls.last,
          service: acp,
          thread: 'ses-1',
          text: 'hello',
        );
      });

      testWidgets('a queued answer after a host change stays queued, uncertain '
          'and exact', (t) async {
        final api = FakeBridgeApi()
          ..acpCapabilities[acp] = acpCapsOf(imageInput: true)
          ..autoCompleteTurn = false
          ..announceTurnStart = false;
        await api.appConnect(acp, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: acp, threadId: 't1'), api),
        );
        await t.pumpAndSettle();
        await type(t, 'first');
        await send(t);
        api.pushEvent(acp, turn('turn/started', 't1', 'a'));
        await frames(t);
        await attachAll(t);
        await type(t, 'second');
        await send(t);
        await type(t, 'third');
        await send(t);
        await type(t, 'still typing');
        final gate = Completer<void>();
        api.turnStartGate = gate;
        api.pushEvent(acp, turn('turn/completed', 't1', 'a'));
        await frames(t);
        expect(api.turnStartCalls, hasLength(2), reason: '"second" is out');
        await hostChange(t, api, 2, replaced: false, imageInput: true);
        gate.complete();
        await frames(t);
        expect(find.byKey(const Key('queued-uncertain-0')), findsOneWidget);
        expect(find.byKey(const Key('queued-1')), findsOneWidget);
        expect(composerText(t), 'still typing');
        expect(find.textContaining('不会自动发送'), findsOneWidget);
        // No admission, no drain: nothing else goes, not even later.
        await pastGrace(t);
        expect(api.turnStartCalls, hasLength(2));
        await t.tap(retryButton());
        await frames(t);
        expect(api.turnStartCalls, hasLength(3));
        for (final call in api.turnStartCalls.skip(1)) {
          expectTurn(
            call,
            service: acp,
            thread: 't1',
            text: secondWithFile,
            images: allImages,
          );
        }
        expect(find.byKey(const Key('queued-0')), findsNothing);
        expect(find.byKey(const Key('queued-1')), findsOneWidget);
      });

      testWidgets('a thread start finishing after the user moved on still '
          'sends for its own draft; the newer view is untouched', (t) async {
        await t.binding.setSurfaceSize(wide);
        addTearDown(() => t.binding.setSurfaceSize(null));
        final api = FakeBridgeApi()..acpCapabilities[acp] = acpCapsOf();
        api.appThreads.addAll(const [
          ThreadMeta(id: 'ses-1', preview: 'one', cwd: '/work', updatedAt: 2),
          ThreadMeta(id: 'ses-2', preview: 'two', cwd: '/work', updatedAt: 1),
        ]);
        await api.appConnect(acp, 28080);
        await t.pumpWidget(
          host(const AppSessionScreen(serviceKey: acp, cwd: '/work'), api),
        );
        await t.pumpAndSettle();
        final gate = Completer<void>();
        api.threadStartGate = gate;
        await type(t, 'hello');
        await send(t);
        // Away to another conversation, and a newer send there.
        await t.tap(find.byKey(const Key('conv-tile-ses-2')));
        await frames(t);
        await type(t, 'other');
        await send(t);
        expect(api.turnStartCalls, hasLength(1));
        expectTurn(
          api.turnStartCalls.single,
          service: acp,
          thread: 'ses-2',
          text: 'other',
        );
        gate.complete();
        await frames(t);
        expect(api.threadStartCalls, [acp]);
        expect(api.turnStartCalls, hasLength(2));
        expectTurn(
          api.turnStartCalls.last,
          service: acp,
          thread: 'thread-0',
          text: 'hello',
        );
        expect(composerText(t), '', reason: 'the shown draft is untouched');
        expect(returned(), findsNothing);
        // Neither send holds the composer: the next one goes too.
        await type(t, 'more');
        await send(t);
        expect(api.turnStartCalls, hasLength(3));
        expectTurn(
          api.turnStartCalls.last,
          service: acp,
          thread: 'ses-2',
          text: 'more',
        );
      });
    });
  });
}
