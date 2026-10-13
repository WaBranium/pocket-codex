part of '../app_session_screen.dart';

extension _SessionConfiguration on _AppSessionState {
  /// Composite key for the process-wide per-thread caches. Scoped by service so
  /// two hosts can't collide on a shared thread id (matching how the persisted
  /// config is keyed per service); neither segment contains a space.
  String _threadKey(String threadId) => '${widget.serviceKey} $threadId';

  /// The effort the next turn will run with: a pending pick, else the thread's
  /// current effort. Drives the composer chip and what's sent on every turn.
  ReasoningEffort? get _effectiveEffort => _effort ?? _effortActive;

  /// Seed a brand-new conversation's settings from the user's last choices
  /// ([sessionDefaultsProvider]) so it inherits them instead of resetting to
  /// hard defaults. Assigns fields directly; the caller handles _updateState/timing.
  void _seedDefaults() {
    final d = ref.read(sessionDefaultsProvider(widget.serviceKey));
    _model = d.model;
    _modelPickPending = false;
    _mode = d.mode;
    _serviceTier = d.serviceTier;
    _plan = d.plan;
    _planActive = false; // a new thread hasn't been told a mode yet
    // A fresh conversation hasn't toggled plan; clear any stale pending toggle
    // (set on the previous thread without sending) so the first turn only sends
    // a collaborationMode when the seeded plan actually differs from default.
    _planToggledByUser = false;
    // Drop a seeded effort the seeded model can't run (mirrors _pickModel's
    // guard) so the first turn never asserts an unsupported level.
    final m = _model;
    _effort =
        (m != null &&
            d.effort != null &&
            !m.supportedReasoningEfforts.contains(d.effort!.wire))
        ? ReasoningEffort.fromWire(m.defaultReasoningEffort)
        : d.effort; // pending pick → asserted on the first turn
    _effortActive = null;
  }

  /// Remember the user's current settings as the default future new
  /// conversations on this service inherit. Called after each explicit pick
  /// (model / mode / plan / effort) — not on server-driven restoration.
  void _rememberDefaults() {
    _settingsRevision++;
    ref
        .read(sessionDefaultsProvider(widget.serviceKey).notifier)
        .state = SessionDefaults(
      model: _model,
      mode: _mode,
      plan: _plan,
      effort: _effectiveEffort,
      serviceTier: _serviceTier,
    );
  }

  /// The current per-thread settings as a persistable config.
  ThreadConfig _threadConfigSnapshot() => ThreadConfig(
    model: _model?.id,
    reasoningEffort: _effectiveEffort?.wire,
    permissionMode: _mode.name,
    serviceTier: _serviceTier,
    planMode: _plan,
  );

  /// Persist the current per-thread settings on the host so re-opening this
  /// session — on this or another device — restores the user's model / effort /
  /// permission / plan instead of resetting to defaults (requirement #2). No-op
  /// for a brand-new conversation (no thread id yet; persisted at thread-start
  /// instead). Best-effort + fire-and-forget: a failure (e.g. the host meta
  /// tunnel briefly unreachable) must never disrupt the conversation.
  void _persistThreadConfig() {
    final tid = _threadId;
    if (tid == null) return;
    final cfg = _threadConfigSnapshot();
    unawaited(
      ref
          .read(bridgeApiProvider)
          .metaThreadConfigSet(widget.serviceKey, tid, cfg)
          .catchError((_) => cfg),
    );
  }

  /// Adopt a server-reported runtime config. A snapshot from a live
  /// `thread/settings/updated` ([ThreadRuntimeConfig.confirmedByUpdate]) is
  /// authoritative for the sticky selection state too — effort, plan mode and
  /// the model pill sync to it so the composer can never drift from the
  /// server. A start/resume snapshot only refreshes the indicator: it may
  /// predate settings this app already sent (older servers never notify), so
  /// it must not roll the selections back.
  void _applyRuntime(ThreadRuntimeConfig cfg) {
    if (!mounted) return;
    _updateState(() {
      _runtime = cfg;
      _runtimeAt = DateTime.now();
      if (!cfg.confirmedByUpdate) return;
      if (!_modePickPending && cfg.approvalsReviewer != null) {
        final preset = PermissionMode.values
            .where(
              (mode) =>
                  mode.approval == cfg.approvalPolicy &&
                  mode.sandbox == cfg.sandboxMode &&
                  mode.reviewer == cfg.approvalsReviewer,
            )
            .firstOrNull;
        if (preset != null) _mode = preset;
      }
      if (!_serviceTierPickPending) _serviceTier = cfg.serviceTier;

      _effortActive = ReasoningEffort.fromWire(cfg.reasoningEffort);
      final collab = cfg.collaborationMode;
      if (collab != null) {
        _planActive = collab == 'plan';
        if (!_planToggledByUser) _plan = _planActive;
      }
      // Reflect the confirmed model onto the model pill — unless the user is
      // holding a different, not-yet-sent pick. An id missing from the model
      // list (e.g. an unlisted config default) still shows via the status-bar
      // indicator, which renders the raw id.
      final m = cfg.model;
      if (m != null && !_modelPickPending && _model?.id != m) {
        final resolved = _models.where((x) => x.id == m).firstOrNull;
        if (resolved != null) _model = resolved;
      }
    });
    if (!cfg.confirmedByUpdate) return;
    // Keep the per-thread memory on server truth so reopening restores it.
    final tid = _threadId;
    if (tid != null) {
      _AppSessionState._effortByThread[_threadKey(tid)] = _effortActive;
      if (cfg.collaborationMode != null) {
        _AppSessionState._planByThread[_threadKey(tid)] = _planActive;
      }
    }
  }

  /// Pull the bridge's cached runtime config (fed by start/resume responses
  /// and live settings notifications) — cheap, no RPC. Covers the gaps events
  /// can't: the thread/start response of a brand-new conversation, and
  /// notifications that streamed by while no screen was attached.
  void _refreshRuntimeFromCache() {
    final tid = _threadId;
    if (tid == null) return;
    ThreadRuntimeConfig? cfg;
    try {
      cfg = ref
          .read(bridgeApiProvider)
          .appThreadRuntimeConfig(widget.serviceKey, tid);
    } catch (_) {
      return; // best-effort
    }
    if (cfg != null) _applyRuntime(cfg);
  }

  /// Load a thread's persisted config from the host. Best-effort: returns an
  /// all-unset config when the host meta tunnel is unreachable, so the caller
  /// falls back to the server / in-memory restore.
  Future<ThreadConfig> _loadPersistedConfig(String threadId) async {
    try {
      return await ref
          .read(bridgeApiProvider)
          .metaThreadConfigGet(widget.serviceKey, threadId);
    } catch (_) {
      return const ThreadConfig();
    }
  }
}
