part of '../acp_session_test.dart';

void _registerOmissions() {
  testWidgets('an omission notice re-sent empty disappears and leaves the '
      'tool named like it', (t) async {
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    AppEvent item(String id, String type, String text, {bool done = true}) =>
        AppEvent(
          kind: done ? 'item/completed' : 'item/started',
          threadId: 'ses-1',
          itemId: id,
          itemType: type,
          title: type == 'contentOmitted' ? '' : 'Tool $id',
          text: text,
          raw: '{"threadId":"ses-1","turnId":"T","itemId":"$id"}',
        );
    api.pushEvent(
      acp,
      const AppEvent(
        kind: 'turn/started',
        threadId: 'ses-1',
        raw: '{"threadId":"ses-1","turnId":"T","turn":{"id":"T"}}',
      ),
    );
    // Tool `x` dropped an oversized diff; another tool is legally named
    // `x:omitted`.
    api.pushEvent(acp, item('tool:x', 'dynamicToolCall', '{}', done: false));
    api.pushEvent(acp, item('#omitted:tool:x', 'contentOmitted', 'diffs'));
    api.pushEvent(
      acp,
      item('tool:x:omitted', 'dynamicToolCall', '{}', done: false),
    );
    await frames(t);
    if (find.byType(ContentOmittedNotice).evaluate().isEmpty) {
      final toggle = find.byKey(const Key('turn-work-toggle'));
      if (toggle.evaluate().isNotEmpty) {
        await t.tap(toggle.first);
        await frames(t);
      }
    }
    expect(find.byType(ContentOmittedNotice), findsOneWidget);
    expect(find.text('Tool tool:x:omitted'), findsOneWidget);
    // The replacement diff fits: the bridge re-sends the notice empty.
    api.pushEvent(acp, item('#omitted:tool:x', 'contentOmitted', ''));
    await frames(t);
    expect(find.byType(ContentOmittedNotice), findsNothing);
    // With the notice removed, the now-adjacent tools form a collapsed
    // activity group. Open it through the same control the reader uses.
    final group = find.byType(GroupedActivityCard);
    expect(group, findsOneWidget);
    expect(
      t.widget<GroupedActivityCard>(group).group.items.map((item) => item.id),
      ['tool:x', 'tool:x:omitted'],
    );
    final toggle = find.descendant(of: group, matching: find.byType(InkWell));
    await t.ensureVisible(toggle);
    await t.tap(toggle);
    await frames(t);
    expect(find.text('Tool tool:x'), findsOneWidget);
    expect(find.text('Tool tool:x:omitted'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final alreadyVisible in [false, true]) {
    testWidgets(
      'omission deletion survives pending history (visible=$alreadyVisible)',
      (t) async {
        const notice = ThreadItem(
          id: '#omitted:tool:x',
          itemType: 'contentOmitted',
          title: '',
          text: 'diffs',
          turnId: 'T',
        );
        const tools = [
          ThreadItem(
            id: 'tool:x',
            itemType: 'dynamicToolCall',
            title: 'Tool x',
            text: '{}',
            turnId: 'T',
          ),
          ThreadItem(
            id: 'tool:x:omitted',
            itemType: 'dynamicToolCall',
            title: 'Tool x:omitted',
            text: '{}',
            turnId: 'T',
          ),
        ];
        final api = AcpApi()..acpCapabilities[acp] = negotiated;
        api.readResult = ThreadHistory(
          items: [tools.first, if (alreadyVisible) notice, tools.last],
          running: false,
        );
        await open(t, api, acp, thread: 'ses-1');
        final read = Completer<ThreadHistory>();
        api.pendingReads['ses-1'] = [read.future];
        api.pushEvent(
          acp,
          const AppEvent(
            kind: 'thread/compacted',
            threadId: 'ses-1',
            raw: '{}',
          ),
        );
        await frames(t);
        expect(
          api.pendingReads['ses-1'],
          isEmpty,
          reason: 'production history refresh must be waiting',
        );
        api.pushEvent(
          acp,
          const AppEvent(
            kind: 'item/completed',
            threadId: 'ses-1',
            itemId: '#omitted:tool:x',
            itemType: 'contentOmitted',
            text: '',
            raw: '{"threadId":"ses-1","turnId":"T"}',
          ),
        );
        await frames(t);
        read.complete(
          ThreadHistory(
            items: [tools.first, notice, tools.last],
            running: false,
          ),
        );
        await frames(t);
        final work = find.byKey(const Key('turn-work-toggle'));
        if (work.evaluate().isNotEmpty) {
          await t.tap(work.first);
          await frames(t);
        }
        expect(find.byType(ContentOmittedNotice), findsNothing);
        final group = find.byType(GroupedActivityCard);
        expect(group, findsOneWidget);
        expect(
          t
              .widget<GroupedActivityCard>(group)
              .group
              .items
              .map((item) => item.id),
          ['tool:x', 'tool:x:omitted'],
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final (reasons, english) in [
    (
      'images,diffs',
      'Not kept because it was too large: images, file changes.',
    ),
    (
      'unavailable',
      'Part of this reply could not be read from the agent host.',
    ),
  ]) {
    testWidgets('omitted content is named: $reasons', (t) async {
      await t.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ContentOmittedNotice(reasons: reasons)),
        ),
      );
      expect(find.text(english), findsOneWidget);
    });
  }
}
