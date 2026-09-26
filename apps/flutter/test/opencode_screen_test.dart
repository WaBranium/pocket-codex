import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/opencode_api.dart';
import 'package:pocket_codex/src/screens/opencode_screen.dart';
import 'opencode_controller_test.dart' show FakeOpenCodeApi;

Widget host(FakeOpenCodeApi api, {bool dark = false, String locale = 'en'}) =>
    ProviderScope(
      child: MaterialApp(
        locale: Locale(locale),
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OpenCodeScreen(api: api),
      ),
    );

void main() {
  testWidgets(
    'phone keyboard leaves approvals and composer within the viewport',
    (t) async {
      t.view.physicalSize = const Size(390, 740);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetViewInsets);
      final api = FakeOpenCodeApi()
        ..current = const OpenCodeSnapshot(
          sessionId: 'a',
          status: 'busy',
          permissions: [
            {
              'id': 'p',
              'permission': 'bash',
              'patterns': ['git status'],
            },
          ],
          questions: [
            {'id': 'q', 'questions': []},
          ],
        );
      await t.pumpWidget(host(api));
      await t.enterText(find.byKey(const Key('opencode-directory')), '/work');
      await t.tap(find.byKey(const Key('opencode-connect')));
      await t.pumpAndSettle();
      await t.tap(find.text('Session A'));
      await t.pumpAndSettle();
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pump();
      expect(t.takeException(), isNull);
      expect(
        t.getRect(find.byKey(const Key('opencode-composer'))).bottom,
        lessThanOrEqualTo(440),
      );
    },
  );
  for (final width in [390.0, 800.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'tool and unknown parts remain visible at $width dark=$dark',
        (t) async {
          t.view.physicalSize = Size(width, 900);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final api = FakeOpenCodeApi()
            ..current = const OpenCodeSnapshot(
              sessionId: 'a',
              messages: [
                {
                  'info': {'id': 'm', 'role': 'assistant'},
                  'parts': [
                    {
                      'id': 'tool',
                      'type': 'tool',
                      'tool': 'bash',
                      'state': {
                        'status': 'completed',
                        'output': 'working tree clean',
                      },
                    },
                    {'id': 'new', 'type': 'future.kind', 'value': 'retained'},
                  ],
                },
              ],
            );
          await t.pumpWidget(host(api, dark: dark, locale: dark ? 'zh' : 'en'));
          await t.enterText(
            find.byKey(const Key('opencode-directory')),
            '/work',
          );
          await t.tap(find.byKey(const Key('opencode-connect')));
          await t.pumpAndSettle();
          await t.tap(find.text('Session A'));
          await t.pumpAndSettle();
          expect(find.text('bash · completed'), findsOneWidget);
          expect(find.text('future.kind'), findsOneWidget);
          expect(t.takeException(), isNull);
          expect(
            t
                .widget<IconButton>(
                  find.byKey(const Key('opencode-disconnect')),
                )
                .onPressed,
            isNotNull,
          );
          await t.tap(find.byKey(const Key('opencode-disconnect')));
          await t.pumpAndSettle();
          expect(find.text('Request failed. Try again.'), findsNothing);
          expect(api.disconnected, ['connection']);
          expect(find.byKey(const Key('opencode-connect')), findsOneWidget);
        },
      );
    }
  }
  testWidgets('search and explicit history pagination stay bounded', (t) async {
    final api = FakeOpenCodeApi()
      ..current = const OpenCodeSnapshot(sessionId: 'a', nextCursor: 'opaque');
    await t.pumpWidget(host(api));
    await t.enterText(find.byKey(const Key('opencode-directory')), '/work');
    await t.tap(find.byKey(const Key('opencode-connect')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('opencode-search')), 'Title');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(api.search, 'Title');
    await t.tap(find.text('Session A'));
    await t.pumpAndSettle();
    await t.tap(find.text('Load earlier messages'));
    await t.pumpAndSettle();
    expect(find.text('Older message'), findsOneWidget);
    expect(find.text('Load earlier messages'), findsNothing);
    await t.tap(find.byTooltip('New session'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('opencode-composer')), findsOneWidget);
  });
  testWidgets('questions collect ordered choices and custom text', (t) async {
    final api = FakeOpenCodeApi()
      ..current = const OpenCodeSnapshot(
        sessionId: 'a',
        questions: [
          {
            'id': 'q',
            'questions': [
              {
                'header': 'Language',
                'question': 'Choose languages',
                'multiple': true,
                'custom': false,
                'options': [
                  {'label': 'Dart', 'description': 'UI'},
                  {'label': 'Rust', 'description': 'Host'},
                ],
              },
              {
                'header': 'Name',
                'question': 'Choose a name',
                'custom': true,
                'options': [],
              },
            ],
          },
        ],
      );
    await t.pumpWidget(host(api));
    await t.enterText(find.byKey(const Key('opencode-directory')), '/work');
    await t.tap(find.byKey(const Key('opencode-connect')));
    await t.pumpAndSettle();
    await t.tap(find.text('Session A'));
    await t.pumpAndSettle();
    await t.tap(find.text('Answer questions'));
    await t.pumpAndSettle();
    await t.tap(find.text('Dart'));
    await t.pump();
    await t.tap(find.text('Rust'));
    await t.pump();
    await t.enterText(find.byKey(const Key('opencode-answer-1')), 'Pocket');
    await t.pump();
    await t.tap(find.text('Submit answers'));
    await t.pumpAndSettle();
    expect(api.answers, [
      ['Dart', 'Rust'],
      ['Pocket'],
    ]);
  });
  testWidgets(
    'permission instance scope is explicit and stop only aborts the session',
    (t) async {
      final api = FakeOpenCodeApi()
        ..current = const OpenCodeSnapshot(
          sessionId: 'a',
          status: 'busy',
          permissions: [
            {
              'id': 'p',
              'permission': 'bash',
              'patterns': ['git status'],
            },
          ],
        );
      await t.pumpWidget(host(api));
      await t.enterText(find.byKey(const Key('opencode-directory')), '/work');
      await t.tap(find.byKey(const Key('opencode-connect')));
      await t.pumpAndSettle();
      await t.tap(find.text('Session A'));
      await t.pumpAndSettle();
      await t.tap(find.text('Allow for this instance'));
      await t.pumpAndSettle();
      expect(
        find.text(
          'This also applies to other sessions in this OpenCode instance until it restarts.',
        ),
        findsOneWidget,
      );
      await t.tap(find.text('Allow'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('opencode-abort')));
      await t.pumpAndSettle();
      expect(api.decisions, ['p:always', 'a:abort']);
    },
  );
  testWidgets(
    'unknown send keeps the text and disables send until reconciled',
    (t) async {
      final api = FakeOpenCodeApi()..submission = OpenCodeSubmission.unknown;
      await t.pumpWidget(host(api));
      await t.enterText(find.byKey(const Key('opencode-directory')), '/work');
      await t.tap(find.byKey(const Key('opencode-connect')));
      await t.pumpAndSettle();
      await t.tap(find.text('Session A'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('opencode-composer')), 'Continue');
      await t.pump();
      await t.tap(find.byKey(const Key('opencode-send')));
      await t.pumpAndSettle();
      expect(find.text('Continue'), findsOneWidget);
      expect(
        find.text(
          'Submission unknown. Check the session before sending again.',
        ),
        findsOneWidget,
      );
      expect(
        t.widget<IconButton>(find.byKey(const Key('opencode-send'))).onPressed,
        isNull,
      );
      expect(api.sent, ['Continue']);
      await t.tap(find.text('Review submission'));
      await t.pumpAndSettle();
      expect(
        find.text(
          'The message may already be running. Unlocking does not resend it.',
        ),
        findsOneWidget,
      );
      await t.tap(find.text('I checked the session'));
      await t.pumpAndSettle();
      expect(api.sent, ['Continue']);
      expect(
        t.widget<IconButton>(find.byKey(const Key('opencode-send'))).onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'direct connect opens real history and retains no password in form',
    (t) async {
      final api = FakeOpenCodeApi()
        ..current = const OpenCodeSnapshot(
          sessionId: 'a',
          messages: [
            {
              'info': {'id': 'message', 'role': 'assistant'},
              'parts': [
                {'id': 'part', 'type': 'text', 'text': 'A real reply'},
              ],
            },
          ],
        );
      await t.pumpWidget(host(api));
      await t.enterText(find.byKey(const Key('opencode-directory')), '/work');
      await t.enterText(find.byKey(const Key('opencode-password')), 'secret');
      await t.tap(find.byKey(const Key('opencode-connect')));
      await t.pumpAndSettle();
      await t.tap(find.text('Session A'));
      await t.pumpAndSettle();
      expect(find.text('A real reply'), findsOneWidget);
      expect(find.text('secret'), findsNothing);
    },
  );
}
