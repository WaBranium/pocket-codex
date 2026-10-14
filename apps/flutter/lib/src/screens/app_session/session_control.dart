part of '../app_session_screen.dart';

extension _SessionControl on _AppSessionState {
  Future<void> _showSessionControl() async {
    final thread = _threadId;
    if (!_caps.isAcp ||
        thread == null ||
        _guardianReadOnly ||
        _sessionControlOpen) {
      return;
    }
    final service = widget.serviceKey;
    final load = _threadLoadGeneration;
    final link = _linkEpoch;
    final caps = _capsEpoch;
    final l10n = AppLocalizations.of(context);
    bool current() =>
        mounted &&
        widget.serviceKey == service &&
        _threadId == thread &&
        _threadLoadGeneration == load &&
        _linkEpoch == link &&
        _capsEpoch == caps;
    _sessionControlOpen = true;
    try {
      final choice = await showDialog<SessionControlChoice>(
        context: context,
        builder: (_) => SessionControlDialog(
          load: () async {
            if (!current()) throw StateError(l10n.sessionControlChanged);
            final snapshot = await ref
                .read(bridgeApiProvider)
                .appAcpSessionControl(service, thread);
            if (!current() || snapshot.sessionId != thread) {
              throw StateError(l10n.sessionControlChanged);
            }
            return snapshot;
          },
        ),
      );
      if (!current() || choice == null) return;
      if (choice.action == 'release') {
        // Freeze admissions before the close, including automatic queue drain.
        // Draft contents and queued messages remain in their original slot.
        _enterExternalWriterMode(thread);
      }
      _updateState(() {
        _takingOver = true;
        _error = null;
        _retry = null;
      });
      await ref
          .read(bridgeApiProvider)
          .appAcpControlSession(service, choice.snapshot, choice.action);
      if (!current()) return;
      if (choice.action == 'release') {
        _updateState(() => _takingOver = false);
        return;
      }
      _cancelExternalWriterSubscription();
      _updateState(() {
        _externalWriterMode = false;
        _externalWriterLiveness = null;
        _takingOver = false;
      });
      await _resumeAndLoad();
    } catch (error) {
      if (current()) {
        _updateState(() {
          _takingOver = false;
          _error = friendlyError(error);
        });
      }
    } finally {
      _sessionControlOpen = false;
      if (mounted &&
          widget.serviceKey == service &&
          _threadId == thread &&
          _threadLoadGeneration == load) {
        _updateState(() => _takingOver = false);
      }
    }
  }
}
