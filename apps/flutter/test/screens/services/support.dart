part of '../services_test.dart';

FakeBridgeApi accountFake() => FakeBridgeApi(
  config: const ConfigInfo(
    relay: '',
    hasKey: false,
    mode: 'account',
    accountLogin: 'acking-you',
  ),
  services: const [],
);

// The agent chooser sits above the Codex form, so its controls may start
// below the dialog's fold: scroll them in and require a real hit first.
Future<void> tapRevealed(WidgetTester t, Finder control) async {
  await t.ensureVisible(control);
  await t.pumpAndSettle();
  expect(control.hitTestable(), findsOneWidget, reason: '$control');
  await t.tap(control);
  await t.pumpAndSettle();
}
