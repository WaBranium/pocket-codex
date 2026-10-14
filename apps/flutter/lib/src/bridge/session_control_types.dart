part of '../bridge_api.dart';

/// Immutable ownership snapshot captured before confirming an operation.
class SessionControl {
  const SessionControl({
    required this.sessionId,
    required this.hostId,
    required this.generation,
    this.sourceGeneration,
    required this.provider,
    required this.status,
    required this.canContinue,
    required this.canRelease,
    required this.canAcquire,
  });

  final String sessionId;
  final String hostId;
  final int generation;
  final String? sourceGeneration;
  final String provider;
  final String status;
  final bool canContinue;
  final bool canRelease;
  final bool canAcquire;
}
