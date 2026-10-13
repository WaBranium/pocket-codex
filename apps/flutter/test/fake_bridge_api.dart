import 'dart:async';
import 'dart:typed_data';

import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/service_key.dart';

part 'support/fake_bridge/state.dart';
part 'support/fake_bridge/connection.dart';
part 'support/fake_bridge/host_sessions.dart';
part 'support/fake_bridge/hosting.dart';
part 'support/fake_bridge/threads.dart';

/// In-memory bridge with shared, inspectable state for widget tests.
class FakeBridgeApi extends _FakeBridgeState
    with _FakeConnection, _FakeHostSessions, _FakeHosting, _FakeThreads {
  /// Creates a fake seeded with optional configuration and services.
  FakeBridgeApi({super.config, super.services});
}
