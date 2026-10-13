part of '../app_session_screen.dart';

extension _SessionCapabilities on _AppSessionState {
  Set<String> get _answeredAsyncQuestions =>
      ref.read(answeredAsyncQuestionsProvider(widget.serviceKey));

  void _markAsyncQuestionAnswered(String threadId, String itemId) {
    ref.read(answeredAsyncQuestionsProvider(widget.serviceKey).notifier).state =
        {..._answeredAsyncQuestions, '$threadId:$itemId'};
  }

  AppCapabilities get _caps {
    final cached = _capsCache;
    if (_capsKey != widget.serviceKey ||
        cached == null ||
        (cached.isAcp && !cached.negotiated)) {
      _capsKey = widget.serviceKey;
      _capsCache = ref
          .read(bridgeApiProvider)
          .appCapabilities(widget.serviceKey);
    }
    return _capsCache!;
  }

  /// Drop cached capabilities (host generation / phase changed, reconnect)
  /// and stop native microphone features the new connection does not have.
  void _invalidateCaps() {
    _capsEpoch++;
    final imageInputBefore = _capsCache?.imageInput;
    _capsCache = null;
    final caps = _caps;
    // An image granted before may not reach a host that no longer takes
    // images. (One refused before never becomes admissible by itself: an
    // admission never exceeds its grant.)
    if (imageInputBefore == true && !caps.imageInput) {
      _drafts.revokeAdmissions();
    }
    if (!caps.dictation) unawaited(_dictation.close());
    if (!caps.voice && _voice.busy) unawaited(_voice.stop());
  }

  /// The session an agent option change would apply to right now, or null
  /// when there is none. A change is bound to the target current when its
  /// menu opened and refused if any part moved (conversation, its load,
  /// capabilities/host generation, event connection).
  _AgentTarget? _agentTarget() {
    final tid = _threadId;
    if (tid == null) return null;
    return (
      service: widget.serviceKey,
      thread: tid,
      load: _threadLoadGeneration,
      caps: _capsEpoch,
      link: _subscriptionEpoch,
    );
  }

  /// Whether the agent's per-session options can be changed now: a live,
  /// editable, idle conversation.
  bool get _agentControlsEnabled =>
      _caps.sessionConfig &&
      !_sending &&
      !_preparingSession &&
      !_streaming &&
      !(_agentSettings?.running ?? false) &&
      !_externalWriterMode &&
      !_guardianReadOnly &&
      !_reconnecting &&
      !_historySyncing &&
      !_showingCachedHistory &&
      !_connectionLost;

  /// Whether a change bound to [target] may still be sent.
  bool _agentTargetCurrent(_AgentTarget? target) =>
      mounted &&
      target != null &&
      target == _agentTarget() &&
      _agentControlsEnabled;

  void _refreshAgentSettings() {
    final tid = _threadId;
    final next = tid == null || !_caps.sessionConfig
        ? null
        : ref
              .read(bridgeApiProvider)
              .appSessionSettings(widget.serviceKey, tid);
    if (mounted) _updateState(() => _agentSettings = next);
  }

  Future<void> _decide(AppEvent prompt, String decision) async {
    _updateState(() => _approvals.remove(prompt));
    try {
      await ref
          .read(bridgeApiProvider)
          .appRespondApproval(widget.serviceKey, prompt.requestId!, decision);
    } catch (e) {
      // The host may have dropped between the prompt and the answer; swallow so a
      // dead connection can't surface an uncaught async error.
      debugPrint('appRespondApproval failed: $e');
    }
  }

  /// Answer an ACP permission with one of the options the agent offered. The
  /// card stays until the host accepts the answer: a failed send keeps it so
  /// the user can retry, and a request resolved elsewhere arrives as
  /// `serverRequest/resolved` and drops it.
  Future<void> _answerAgentPermission(AppEvent prompt, String optionId) async {
    try {
      await ref
          .read(bridgeApiProvider)
          .appRespondApproval(widget.serviceKey, prompt.requestId!, optionId);
      if (mounted) _updateState(() => _approvals.remove(prompt));
    } catch (e) {
      if (!mounted) return;
      final message = friendlyError(e);
      // Already answered / withdrawn on the host: the card is obsolete.
      if (message.contains('already resolved') ||
          message.contains('unknown permission')) {
        _updateState(() => _approvals.remove(prompt));
        return;
      }
      showToastError(
        context,
        AppLocalizations.of(context).permissionAnswerFailed,
      );
    }
  }

  /// Open the ACP agent's session for the chosen project without sending, so
  /// its model, effort and mode can be chosen before the first prompt (the
  /// agent's catalog is per session and project). The current draft — text,
  /// attachments, queue — is adopted by the new session as is; nothing is
  /// sent. Only a completion for the same service, project, draft and
  /// conversation state is applied: if the user switched project or
  /// conversation meanwhile, the new session stays an empty entry in the
  /// host's list and this view is left alone.
  Future<void> _prepareAgentSession() async {
    final cwd = _cwd;
    if (_threadId != null ||
        cwd == null ||
        _preparingSession ||
        _sending ||
        !_caps.sessionConfig ||
        _externalWriterMode ||
        _guardianReadOnly ||
        _reconnecting ||
        _connectionLost ||
        _showingCachedHistory) {
      return;
    }
    final serviceKey = widget.serviceKey;
    final generation = _threadLoadGeneration;
    final selection = _projectSelectionGeneration;
    final caps = _capsEpoch;
    final link = _subscriptionEpoch;
    _saveDraft();
    final draft = _draft;
    // The same view, project, draft and connection, still editable and
    // still offering per-session options.
    bool current() =>
        mounted &&
        widget.serviceKey == serviceKey &&
        generation == _threadLoadGeneration &&
        selection == _projectSelectionGeneration &&
        caps == _capsEpoch &&
        link == _subscriptionEpoch &&
        identical(_draft, draft) &&
        _threadId == null &&
        _cwd == cwd &&
        !_sending &&
        !_externalWriterMode &&
        !_guardianReadOnly &&
        !_reconnecting &&
        !_connectionLost &&
        _caps.sessionConfig;
    _updateState(() {
      _preparingSession = true;
      _error = null;
    });
    try {
      final id = await ref
          .read(bridgeApiProvider)
          .appThreadStart(serviceKey, cwd: cwd);
      if (!current()) return;
      _drafts.adoptThread(draft, id);
      _threadId = id;
      ref.read(uiPrefsProvider.notifier).setLastThread(serviceKey, id);
      _updateState(() {
        if (!_threads.any((t) => t.id == id)) {
          _threads = [
            ThreadMeta(id: id, preview: '', cwd: cwd, updatedAt: 0),
            ..._threads,
          ];
        }
      });
      _refreshAgentSettings();
      unawaited(_loadThreads());
    } catch (e) {
      if (current()) _updateState(() => _error = friendlyError(e));
    } finally {
      if (mounted) _updateState(() => _preparingSession = false);
    }
  }

  /// Set the agent's option [configId] to [value] for [target]. Refused —
  /// nothing is sent — when [target] is no longer the open, editable
  /// conversation or the value is no longer advertised.
  Future<void> _setAgentConfig(
    _AgentTarget? target,
    String configId,
    String value,
  ) async {
    if (!_agentTargetCurrent(target)) return;
    final offered = _agentSettings?.configOptions
        .where((o) => o.id == configId)
        .firstOrNull;
    if (offered == null || !offered.values.any((v) => v.value == value)) {
      return;
    }
    try {
      await ref
          .read(bridgeApiProvider)
          .appSetSessionConfig(target!.service, target.thread, configId, value);
    } catch (e) {
      // The agent kept its previous value; its option set is unchanged. A
      // failure for a conversation the user already left is not shown here.
      if (mounted && _agentTarget() == target) {
        _updateState(() => _error = friendlyError(e));
      }
    }
    if (mounted && _agentTarget() == target) _refreshAgentSettings();
  }

  /// Switch the agent's legacy mode for [target]; refused like
  /// [_setAgentConfig].
  Future<void> _setAgentMode(_AgentTarget? target, String modeId) async {
    if (!_agentTargetCurrent(target)) return;
    final settings = _agentSettings;
    if (settings == null ||
        !showsLegacyModes(settings) ||
        !settings.modes.any((m) => m.id == modeId)) {
      return;
    }
    try {
      await ref
          .read(bridgeApiProvider)
          .appSetSessionMode(target!.service, target.thread, modeId);
    } catch (e) {
      if (mounted && _agentTarget() == target) {
        _updateState(() => _error = friendlyError(e));
      }
    }
    if (mounted && _agentTarget() == target) _refreshAgentSettings();
  }

  /// Answer a `request_user_input` elicitation. `answers` maps each question id
  /// to the chosen answer string(s); an empty map cancels (the turn proceeds
  /// without an answer). Sends the codex `ToolRequestUserInputResponse` shape.
  Future<void> _answerUserInput(
    AppEvent prompt,
    Map<String, List<String>> answers,
  ) async {
    _updateState(() => _approvals.remove(prompt));
    try {
      await ref
          .read(bridgeApiProvider)
          .appRespondUserInput(
            widget.serviceKey,
            prompt.requestId!,
            jsonEncode(answers),
          );
    } catch (e) {
      // A dropped host between the elicitation and the answer must not surface an
      // uncaught async error.
      debugPrint('appRespondUserInput failed: $e');
    }
  }

  Future<void> _answerAsyncInput(
    AsyncQuestionPrompt prompt,
    Map<String, List<String>> answers,
  ) async {
    final threadId = _threadId;
    if (threadId == null || _sending || _reconnecting) return;
    if (answers.isEmpty) {
      _updateState(() {
        _asyncQuestions.remove(prompt.id);
        _markAsyncQuestionAnswered(threadId, prompt.id);
      });
      return;
    }
    final text = prompt.answerText(answers);
    final hold = Object();
    _updateState(() => _holdSend(hold));
    try {
      final api = ref.read(bridgeApiProvider);
      if (_streaming) {
        final turnId = _turnId;
        await api.appTurnSteer(widget.serviceKey, threadId, turnId, text);
      } else {
        await api.appTurnStart(widget.serviceKey, threadId, text);
      }
      if (!mounted || _threadId != threadId) return;
      _updateState(() {
        _asyncQuestions.remove(prompt.id);
        _markAsyncQuestionAnswered(threadId, prompt.id);
        _error = null;
      });
    } catch (e) {
      if (mounted && _threadId == threadId) {
        _updateState(() => _error = friendlyError(e));
      }
    } finally {
      if (mounted) _updateState(() => _releaseSend(hold));
    }
  }
}
