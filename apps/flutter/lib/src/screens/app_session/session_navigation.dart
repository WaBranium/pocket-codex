part of '../app_session_screen.dart';

extension _SessionNavigation on _AppSessionState {
  // Track whether we're pinned to the bottom so streaming auto-follows only
  // when the user hasn't scrolled up to read earlier messages.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
    if (atBottom != _atBottom) _updateState(() => _atBottom = atBottom);
    // Publish the visible rows for the turn minimap. Straight onto the notifier
    // — no _updateState — so a scroll frame repaints ticks, not the transcript.
    // Back out the "older history" row so the rail's range is in row indices,
    // which is what its ticks are numbered in.
    if (_listCtl.isAttached) _visibleRows.value = _visibleRowRange();
    // Reading back past the top of what's loaded fetches the previous page.
    // Only user scrolling triggers this. An indexed rail jump must not remove
    // the older-page header halfway through its animation and shift the target.
    if (!_settlingToEnd &&
        _scroll.position.userScrollDirection != ScrollDirection.idle &&
        !_loadingOlder &&
        !_historyError) {
      final range = _visibleRowRange();
      final rows = _rows;
      if (range != null) {
        for (
          var i = range.$1;
          i <= math.min(range.$2 + 1, rows.length - 1);
          i++
        ) {
          if (rows[i] case final HistoryGap gap) {
            _loadGap(gap);
            return;
          }
        }
      }
      // Prefetch while the reader still has a screen or so of history above
      // them, so the next page is usually in place before they reach the top
      // and the "load older" row is never something they have to press. The
      // anchor capture keeps the reading position put when it lands.
      final prefetchBand = math.max(
        600.0,
        _scroll.position.viewportDimension * 1.5,
      );
      final nearTop =
          _scroll.position.pixels <=
              _scroll.position.minScrollExtent + prefetchBand ||
          (range != null && range.$1 <= 3);
      if (!_startsAtBeginning &&
          _scroll.position.userScrollDirection == ScrollDirection.forward &&
          nearTop) {
        _loadAtTop();
      }
    }
  }

  void _repinForKeyboard() {
    if (isDesktop || !_inputFocus.hasFocus || !_atBottom) return;
    _scrollToEnd(force: true);
  }

  /// Scroll to the latest message. Auto-follow only when already pinned to the
  /// bottom (so reading earlier messages isn't interrupted); [force] overrides
  /// that (e.g. right after the user sends or taps the jump button).
  void _scrollToEnd({bool force = false}) {
    if (!force && !_atBottom) return;
    final intent = _scrollIntent;
    final generation = _historyGeneration;
    if (!force) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _historyGeneration &&
            intent == _scrollIntent &&
            _atBottom &&
            _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
      return;
    }
    // Forced jump (opening a conversation, sending, the jump button): a tall
    // conversation lays its variable-height items out over several frames, so
    // maxScrollExtent keeps growing after the first jump. Re-jump to the bottom
    // each frame until it settles — otherwise a long conversation opens blank
    // / mid-content until the user scrolls manually.
    // Each of those jumps notifies the scroll listener from a position that can
    // read as the top of a short list, which would fetch older history the user
    // never asked for. Hold the flag until the jumps are done.
    _settlingToEnd = true;
    final epoch = ++_settleEpoch;
    void settle(int tries) {
      if (!mounted ||
          generation != _historyGeneration ||
          intent != _scrollIntent ||
          epoch != _settleEpoch) {
        if (epoch == _settleEpoch) _settlingToEnd = false;
        return;
      }
      if (!_scroll.hasClients) {
        _settlingToEnd = false;
        return;
      }
      final before = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(before);
      if (_listCtl.isAttached) _visibleRows.value = _visibleRowRange();
      if (tries <= 0) {
        _settlingToEnd = false;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients &&
            _scroll.position.maxScrollExtent > before + 1) {
          settle(tries - 1);
        } else {
          _settlingToEnd = false;
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => settle(10));
  }

  /// Jump the transcript to the previous ([next] false) or next ([next] true)
  /// conversation turn — i.e. the nearest user message above/below the current
  /// viewport top — placing it at the top so its whole exchange is in view.
  /// User messages are never grouped, so each is its own row; we map row
  /// indices and drive super_sliver_list's index-aware scroll.
  void _gotoAdjacentTurn({required bool next}) {
    if (!_listCtl.isAttached || !_scroll.hasClients) return;
    final rows = _rows;
    final turns = _turnMinimapItems(rows);
    if (rows.isEmpty || turns.isEmpty) return;
    final anchor = _visibleRowRange()?.$1 ?? 0;
    final visibleTurn = _rowItems(
      rows[anchor.clamp(0, rows.length - 1)],
    ).firstOrNull?.turnId;
    var current = turns.indexWhere((turn) => turn.turnId == visibleTurn);
    if (current < 0) {
      current = turns.lastIndexWhere(
        (turn) => turn.rowIndex >= 0 && turn.rowIndex <= anchor,
      );
    }
    if (current < 0) return;
    final entry = turns[current];
    final target = next
        ? current + 1
        : entry.rowIndex < 0 || entry.rowIndex < anchor
        ? current
        : current - 1;
    if (target >= 0 && target < turns.length) {
      _selectTurn(turns[target]);
    } else if (!next) {
      _loadAtTop(reveal: true);
    }
  }

  Iterable<TranscriptItem> _rowItems(Object row) => switch (row) {
    TranscriptItem() => [row],
    TurnWork() => row.items,
    ActivityGroup() => row.items,
    AgentTurn() => row.items,
    _ => const [],
  };

  /// One minimap entry per turn: the user's message, and how the turn answered.
  ///
  /// When the server enumerated the thread's turns, every one of them gets a
  /// tick — including turns whose items aren't loaded, which the rail is meant
  /// to show because it represents the whole conversation's shape. Loaded turns
  /// resolve to their real row so selecting one scrolls; the rest carry a
  /// `rowIndex` of -1 and are fetched on selection.
  List<TurnMinimapItem> _turnMinimapItems(List<Object> rows) {
    final locale = Localizations.localeOf(context);
    if (_minimapLocale == locale &&
        identical(rows, _minimapRows) &&
        identical(_turnSummaries, _minimapTurns) &&
        identical(_items.lastOrNull?.text, _minimapLastText)) {
      return _minimapEntries;
    }
    _minimapLocale = locale;
    _minimapRows = rows;
    _minimapTurns = _turnSummaries;
    _minimapLastText = _items.lastOrNull?.text;
    return _minimapEntries = _buildTurnMinimapItems(rows);
  }

  String _requestPreview(String text) {
    final request = ApprovalReviewRequest.parse(text);
    return request == null
        ? previewWithoutFileRefs(text, '')
        : '${request.tool} · ${request.summary}';
  }

  String _replyPreview(String text) {
    final result = ApprovalReviewResult.parse(text);
    if (result == null) return _collapseWhitespace(text);
    final l10n = AppLocalizations.of(context);
    return _collapseWhitespace(
      '${result.outcome == 'allow' ? l10n.reviewAllowed : l10n.reviewDenied} · ${result.rationale}',
    );
  }

  List<TurnMinimapItem> _buildTurnMinimapItems(List<Object> rows) {
    if (_turnSummaries.isEmpty) return _turnMinimapItemsFromRows(rows);
    // Where each loaded turn's user message ended up among the rows.
    final rowOfTurn = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is TranscriptItem && row.isUser) {
        rowOfTurn.putIfAbsent(row.turnId, () => i);
      }
    }
    final out = <TurnMinimapItem>[];
    for (final turn in _turnSummaries) {
      final row = rowOfTurn[turn.turnId];
      final user = _collapseWhitespace(_requestPreview(turn.userText));
      // A loaded turn's reply comes from the rows, which carry the whole turn;
      // the skeleton's own summary answers for turns not scrolled back to.
      final reply = row != null
          ? _finalReplyAfter(rows, row)
          : (_collapseWhitespace(turn.assistantText).isEmpty
                ? null
                : _replyPreview(turn.assistantText));
      out.add(
        TurnMinimapItem(
          rowIndex: row ?? -1,
          turnId: turn.turnId,
          userText: user,
          assistantText: user.isEmpty && reply == null ? null : reply,
        ),
      );
    }
    final snapshotIds = _turnSummaries.map((turn) => turn.turnId).toSet();
    out.addAll(
      _turnMinimapItemsFromRows(rows).where(
        (turn) => turn.turnId.isEmpty || !snapshotIds.contains(turn.turnId),
      ),
    );
    return out;
  }

  /// The visible range in ROW indices, with the leading "older history" row
  /// backed out — the rail numbers its ticks by row, not by list position.
  (int, int)? _visibleRowRange() {
    final range = _listCtl.visibleRange;
    if (range == null) return null;
    final (first, last) = range;
    return ((first - 1).clamp(0, 1 << 30), (last - 1).clamp(0, 1 << 30));
  }

  /// A row saying history continues above, which doubles as the loading state
  /// while the previous page is in flight.
  ///
  /// Tappable as well as scroll-triggered: when the loaded page is shorter than
  /// the viewport there is nothing to scroll, so reaching the top by scrolling
  /// is impossible and this row is the only way back.
  Widget _olderHistoryHeader(AppLocalizations l10n) => SizedBox(
    key: const ValueKey('history-header'),
    height: isDesktop ? 36 : 44,
    child: Center(
      child: _startsAtBeginning
          ? Text(
              l10n.historyStart,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : SizedBox(
              key: const Key('chat-older-history'),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                  textStyle: Theme.of(context).textTheme.labelSmall,
                ),
                key: _loadingOlder
                    ? null
                    : const Key('chat-older-history-load'),
                onPressed: _loadingOlder
                    ? null
                    : () => _loadAtTop(reveal: true),
                icon: _loadingOlder && _historyFromTop
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _historyError && _historyFromTop
                            ? Icons.refresh_rounded
                            : Icons.history_rounded,
                        size: 16,
                      ),
                label: Text(
                  _loadingOlder && _historyFromTop
                      ? l10n.historyLoading
                      : _historyError && _historyFromTop
                      ? l10n.historyRetry
                      : l10n.olderHistoryHint,
                ),
              ),
            ),
    ),
  );

  Key _rowKey(Object row) => ValueKey(switch (row) {
    TurnWork() => 'w:${row.items.first.id}',
    ActivityGroup() => 'g:${row.items.first.id}',
    AgentTurn() => 't:${row.items.first.id}',
    TranscriptItem() => row.id,
    HistoryGap() => 'gap:${row.turnId}:${row.continuation}',
    _ => throw StateError('Unknown transcript row'),
  });

  /// Jump to a turn the rail selected, fetching it first when the transcript
  /// hasn't loaded it yet.
  Future<void> _selectTurn(TurnMinimapItem item) async {
    final navigation = ++_turnNavigation;
    final generation = _historyGeneration;
    if (item.rowIndex >= 0) {
      _updateState(() {
        _navigatingTurn = null;
        _navigationLoading = false;
      });
      _scrollToRow(item.rowIndex);
      return;
    }
    _updateState(() {
      _navigatingTurn = item;
      _navigationLoading = true;
    });
    // Keep the current reading position until the latest target is ready.
    await _loadTurn(item.turnId, navigation: navigation);
    // Let the virtual list lay out inserted rows before navigating by index.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        _historyGeneration != generation ||
        navigation != _turnNavigation) {
      return;
    }
    // Its row exists now that its items are in; re-derive to find where.
    final row = _turnMinimapItems(
      _rows,
    ).where((entry) => entry.turnId == item.turnId).firstOrNull;
    _updateState(() {
      _navigationLoading = false;
      if (row != null && row.rowIndex >= 0) _navigatingTurn = null;
    });
    if (row != null && row.rowIndex >= 0) _scrollToRow(row.rowIndex);
  }

  Future<void> _openTurnOutline() async {
    final items = _turnMinimapItems(_rows);
    final visible = _visibleRowRange()?.$1 ?? 0;
    var current = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].rowIndex >= 0 && items[i].rowIndex <= visible) current = i;
    }
    final generation = _historyGeneration;
    final item = await showTurnOutline(context, items: items, current: current);
    if (mounted && generation == _historyGeneration && item != null) {
      // Rows can shift while the outline is open; resolve the stable identity.
      final target = _turnMinimapItems(_rows)
          .where(
            (entry) => item.messageId.isNotEmpty
                ? entry.messageId == item.messageId
                : entry.turnId == item.turnId,
          )
          .firstOrNull;
      if (target != null) await _selectTurn(target);
    }
  }

  /// Rail entries derived from the loaded rows alone — the shape for a thread
  /// whose history arrived whole, so the rows already cover every turn.
  List<TurnMinimapItem> _turnMinimapItemsFromRows(List<Object> rows) {
    final out = <TurnMinimapItem>[];
    final seen = <String>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! TranscriptItem || !row.isUser) continue;
      if (row.turnId.isNotEmpty && !seen.add(row.turnId)) continue;
      // The raw text can be wire machinery (an attachment block, an IDE context
      // fragment); the same cleaner the sidebar and title bar use resolves it,
      // so all three agree on what a turn is called.
      //
      // The placeholder is passed EMPTY on purpose. A sidebar row must say
      // something, so there it becomes "[file]" — but on the rail that produced
      // a card whose headline was the word "file" above the reply, which named
      // the attachment instead of the turn. With nothing to head the card, the
      // reply speaks for the turn by itself.
      final user = _collapseWhitespace(_requestPreview(row.text));
      final reply = _finalReplyAfter(rows, i);
      // Neither half has anything to show — an empty card that only occludes the
      // conversation. The tick stays; it just has no preview.
      if (user.isEmpty && reply == null) {
        out.add(
          TurnMinimapItem(
            rowIndex: i,
            turnId: row.turnId,
            messageId: row.id,
            userText: '',
          ),
        );
        continue;
      }
      out.add(
        TurnMinimapItem(
          rowIndex: i,
          turnId: row.turnId,
          messageId: row.id,
          userText: user,
          assistantText: reply,
        ),
      );
    }
    return out;
  }

  /// The last reply of the turn starting at [userRow] — its conclusion, not the
  /// preamble it opened with. Null when the turn produced no prose.
  String? _finalReplyAfter(List<Object> rows, int userRow) {
    String? last;
    for (var i = userRow + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row is TranscriptItem && row.isUser) break;
      if (row is AgentTurn) {
        last = row.text;
      } else if (row is TranscriptItem && row.isAgent) {
        last = row.text;
      }
    }
    final text = _replyPreview(last ?? '');
    return text.isEmpty ? null : text;
  }

  /// Flatten a message to one line, so a preview shows its opening words rather
  /// than the first line of a code block.
  String _collapseWhitespace(String text) =>
      (text.length > 600 ? text.substring(0, 600) : text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  /// The space beside the conversation column, which is where the turn rail
  /// lives. Zero on a window narrow enough that the column fills it.
  double _gutterWidth(double available) =>
      math.max(0, (available - _AppSessionState._kColumnWidth) / 2);

  /// How many turns the rail would have ticks for.
  ///
  /// Counts the whole thread's turns when the server enumerated them, so a long
  /// conversation gets its rail immediately instead of only after enough of it
  /// has been scrolled back into memory. Falls back to the loaded user messages
  /// for a thread that arrived whole.
  int get _turnCount {
    final ids = _turnSummaries.map((turn) => turn.turnId).toSet();
    var unknown = 0;
    for (final item in _items.where((item) => item.isUser)) {
      if (item.turnId.isEmpty) {
        unknown++;
      } else {
        ids.add(item.turnId);
      }
    }
    return ids.length + unknown;
  }

  /// Whether the gutter rail can take turn navigation over at [available] width,
  /// so the corner arrows can stand down rather than offer the same thing twice.
  ///
  /// Answered from the transcript's own laid-out width, not a MediaQuery: the
  /// conversation sits between two collapsible panes, so the window size says
  /// nothing useful about how much room it actually got.
  ///
  /// The turn count is part of the question, not just the width: the rail hides
  /// itself below [kTurnMinimapMinItems], so without this a three-turn
  /// conversation on a wide window would get NO turn navigation — the rail gone
  /// by its own rule and the arrows stood down in deference to it.
  bool _railOwnsTurnNav(double available) =>
      isDesktop &&
      _gutterWidth(available) > kTurnMinimapRailInset &&
      _turnCount >= kTurnMinimapMinItems;

  /// The turn rail, plus the corner cluster that defers to it — one layout pass
  /// for both, since the same width decides whether the rail has a gutter and
  /// therefore whether the arrows are still needed.
  Widget _turnNavOverlay() => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final rail = _railOwnsTurnNav(width);
      return Stack(
        children: [
          if (rail)
            Positioned.fill(
              child: TurnMinimap(
                items: _turnMinimapItems(_rows),
                onOpenOutline: _openTurnOutline,
                visibleRange: _visibleRows,
                gutterWidth: _gutterWidth(width),
                onSelect: _selectTurn,
              ),
            ),
          // Where the rail has taken the turn jumps, jump-to-latest is all that
          // is left — and that is about the conversation rather than about a
          // corner, so it centres over the column, where every other chat app
          // puts its scroll-down pill. With the arrows still in it, the cluster
          // is a stack of three and keeps to the right, out of the text.
          if (rail)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Center(child: _navCluster(showTurnNav: false)),
            )
          else
            Positioned.fill(
              // Two turns is enough for stepping to mean something, which is a
              // lower bar than the rail's: the arrows carry a label and do not
              // need a shape to read.
              child: DraggableNavigation(
                label: AppLocalizations.of(context).moveTurnNavigation,
                child: _navCluster(showTurnNav: _turnCount >= 2),
              ),
            ),
        ],
      );
    },
  );

  /// Scroll a turn's user message to the top of the viewport. Shared by the
  /// minimap and the compact prev/next buttons so both land identically.
  void _scrollToRow(int index) {
    if (!_listCtl.isAttached || !_scroll.hasClients) return;
    _scrollIntent++;
    _settleEpoch++;
    _settlingToEnd = true;
    _listCtl.jumpToItem(
      // Callers speak in row indices; the list puts the "older history" row
      // ahead of them, so translate once here rather than at each call site.
      index: index == 0 && _startsAtBeginning ? 0 : index + 1,
      scrollController: _scroll,
      alignment: 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _settlingToEnd = false;
        if (_listCtl.isAttached) _visibleRows.value = _visibleRowRange();
      }
    });
  }

  /// The bottom-right navigation cluster: prev/next-turn jumps (shown once
  /// there are ≥2 turns) and a jump-to-latest (shown when scrolled up). A
  /// single compact rounded bar rather than scattered FABs, so it stays out of
  /// the way of the messages.
  ///
  /// [showTurnNav] is false where the left-gutter [TurnMinimap] is carrying turn
  /// navigation, which does the same job better *once there is a conversation
  /// shape to show*: the arrows can only step, one turn per click, with no sense
  /// of how many turns exist or what you will land on. They stay for the cases
  /// the rail can't serve — touch, windows too narrow to hold a gutter, and
  /// conversations short enough that a handful of ticks says less than a labelled
  /// button (see [kTurnMinimapMinItems]).
  Widget _navCluster({required bool showTurnNav}) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!showTurnNav && _atBottom) return const SizedBox.shrink();
    Widget btn(Key key, IconData icon, String tip, VoidCallback onTap) =>
        IconButton(
          key: key,
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          padding: const EdgeInsets.all(6),
          constraints: BoxConstraints(
            minWidth: isDesktop ? 34 : 48,
            minHeight: isDesktop ? 34 : 48,
          ),
          color: scheme.onSurfaceVariant,
          onPressed: onTap,
          icon: Icon(icon),
        );
    // Opaque, and a shadow rather than a Material elevation: this floats over
    // the scrolling transcript, so a translucent ground would let text read
    // through it — and Material can't composite a wash against the page anyway.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        // Stronger than a panel's: this one floats over moving content.
        boxShadow: panelShadow(scheme, blur: 12),
      ),
      child: Material(
        elevation: 0,
        color: scheme.surfaceBright,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showTurnNav) ...[
                  btn(
                    const Key('nav-turn-outline'),
                    Icons.format_list_numbered,
                    l10n.conversationOutline,
                    _openTurnOutline,
                  ),
                  btn(
                    const Key('nav-prev-turn'),
                    Icons.keyboard_arrow_up,
                    l10n.prevTurn,
                    () => _gotoAdjacentTurn(next: false),
                  ),
                  btn(
                    const Key('nav-next-turn'),
                    Icons.keyboard_arrow_down,
                    l10n.nextTurn,
                    () => _gotoAdjacentTurn(next: true),
                  ),
                ],
                if (!_atBottom)
                  btn(
                    const Key('nav-to-bottom'),
                    Icons.vertical_align_bottom,
                    l10n.jumpToLatest,
                    () => _scrollToEnd(force: true),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
