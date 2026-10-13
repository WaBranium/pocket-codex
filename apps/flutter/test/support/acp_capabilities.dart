import 'package:pocket_codex/src/bridge_api.dart';

/// Negotiated ACP capabilities; native-only controls remain unavailable.
AppCapabilities negotiatedAcpCapabilities({
  required String providerName,
  String profileId = '',
  int generation = 1,
  bool imageInput = false,
  bool steer = false,
}) => AppCapabilities(
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
  providerName: providerName,
  profileId: profileId,
  negotiated: true,
  generation: generation,
  imageInput: imageInput,
  steer: steer,
  sessionConfig: true,
  permissionOptions: true,
  sessionReopen: 'load',
  sessionList: 'agent',
  runningInventory: 'engine',
);
