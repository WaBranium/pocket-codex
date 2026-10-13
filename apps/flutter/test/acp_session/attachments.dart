part of '../acp_session_test.dart';

void _registerAttachments() {
  testWidgets('picking an image file for a text-only agent attaches nothing', (
    t,
  ) async {
    fakePicker([
      MemXFile(tinyPng(), 'shot.png'),
      MemXFile(Uint8List.fromList([1, 2, 3]), 'notes.md'),
    ]);
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await frames(t);
    expect(find.text('shot.png'), findsNothing, reason: 'no unsupported image');
    expect(
      find.text('notes.md'),
      findsOneWidget,
      reason: 'documents still work',
    );
    expect(attachmentChips(), findsOneWidget);
    expect(find.text('该智能体不接受图片'), findsOneWidget);
  });

  testWidgets('a native session still takes a picked image file', (t) async {
    fakePicker([MemXFile(tinyPng(), 'shot.png')]);
    final api = AcpApi();
    await open(t, api, codex, thread: 'ses-1');
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await frames(t);
    expect(attachmentChips(), findsOneWidget);
  });

  testWidgets('pasting an image into a text-only agent attaches nothing', (
    t,
  ) async {
    await onDesktop(() async {
      fakeClipboard(image: tinyPng());
      final api = AcpApi()..acpCapabilities[acp] = negotiated;
      await open(t, api, acp, thread: 'ses-1');
      await paste(t);
      expect(attachmentChips(), findsNothing);
      expect(find.text('该智能体不接受图片'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('pasting an image into a native session attaches it', (t) async {
    await onDesktop(() async {
      fakeClipboard(image: tinyPng());
      final api = AcpApi();
      await open(t, api, codex, thread: 'ses-1');
      await paste(t);
      expect(attachmentChips(), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  for (final key in [acp, codex]) {
    testWidgets('desktop drop respects image support for $key', (t) async {
      await onDesktop(() async {
        final api = AcpApi()..acpCapabilities[acp] = negotiated;
        await open(t, api, key, thread: 'ses-1');
        final drop = t.widget<DropTarget>(find.byType(DropTarget));
        drop.onDragDone!(
          DropDoneDetails(
            files: [
              DropItemFile.fromData(tinyPng(), path: 'dropped.png'),
              DropItemFile.fromData(
                Uint8List.fromList('safe fixture'.codeUnits),
                path: 'dropped.md',
              ),
            ],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
        await frames(t);
        expect(api.lastUploadName, 'dropped.md');
        expect(api.lastUploadKey, key);
        expect(attachmentChips(), findsNWidgets(key == acp ? 1 : 2));
        expect(find.text('dropped.md'), findsOneWidget);
        expect(
          find.text('该智能体不接受图片'),
          key == acp ? findsOneWidget : findsNothing,
        );
        await t.pumpWidget(const SizedBox.shrink());
      });
    });
  }

  testWidgets('a pick that completes after the agent host was lost attaches '
      'nothing', (t) async {
    final previous = fsel.FileSelectorPlatform.instance;
    final selector = PausedFileSelector();
    fsel.FileSelectorPlatform.instance = selector;
    addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await frames(t);
    // The picker is still open when the host goes away.
    api.pushEvent(acp, hostLost);
    await frames(t);
    selector.selection.complete([
      MemXFile(Uint8List.fromList('fixture'.codeUnits), 'notes.md'),
    ]);
    await frames(t);
    expect(attachmentChips(), findsNothing);
    expect(api.lastUploadName, isNull, reason: 'nothing reaches another host');
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a paused pick with the host intact still attaches', (t) async {
    final previous = fsel.FileSelectorPlatform.instance;
    final selector = PausedFileSelector();
    fsel.FileSelectorPlatform.instance = selector;
    addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await frames(t);
    selector.selection.complete([
      MemXFile(Uint8List.fromList('fixture'.codeUnits), 'notes.md'),
    ]);
    await frames(t);
    expect(attachmentChips(), findsOneWidget);
    expect(api.lastUploadName, 'notes.md');
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a document still being read when the host is lost is never '
      'uploaded', (t) async {
    final slow = SlowMemXFile(
      Uint8List.fromList('must not upload'.codeUnits),
      'slow.md',
    );
    fakePicker([slow]);
    final api = AcpApi()..acpCapabilities[acp] = negotiated;
    await open(t, api, acp, thread: 'ses-1');
    await t.tap(find.byKey(const Key('attach-menu-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('attach-file-btn')));
    await frames(t);
    expect(
      attachmentChips(),
      findsOneWidget,
      reason: 'admitted, still reading',
    );
    api.pushEvent(acp, hostLost);
    await frames(t);
    slow.read.complete();
    await frames(t);
    expect(api.lastUploadName, isNull);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final leave in [false, true]) {
    for (final replace in [false, true]) {
      testWidgets(
        'pending file read retains destination (leave=$leave replace=$replace)',
        (t) async {
          final slow = SlowMemXFile(
            Uint8List.fromList('private fixture'.codeUnits),
            'pending.md',
          );
          fakePicker([slow]);
          final api = AcpApi()..acpCapabilities[acp] = negotiated;
          await open(t, api, acp, thread: 'ses-1');
          await t.tap(find.byKey(const Key('attach-menu-btn')));
          await t.pumpAndSettle();
          await t.tap(find.byKey(const Key('attach-file-btn')));
          await frames(t);
          expect(attachmentChips(), findsOneWidget);
          // Keep the ProviderScope/draft store alive, disposing only the screen.
          if (leave) await t.pumpWidget(host(const SizedBox(), api));
          if (replace) api.uploadContext = 'other-account-same-service-key';
          slow.read.complete();
          await frames(t);
          expect(api.lastUploadName, leave || replace ? isNull : 'pending.md');
          if (leave) {
            await open(t, api, acp, thread: 'ses-1');
            expect(
              find.text('pending.md'),
              findsOneWidget,
              reason: 'the original draft keeps its retryable attachment',
            );
          }
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final guardian in [false, true]) {
    for (final reading in [false, true]) {
      testWidgets(
        '${reading ? 'a document read' : 'a file pick'} completing after '
        '${guardian ? 'Guardian discovery' : 'an active writer rejection'} '
        'never uploads',
        (t) async {
          final previous = fsel.FileSelectorPlatform.instance;
          final selector = PausedFileSelector();
          fsel.FileSelectorPlatform.instance = selector;
          addTearDown(() => fsel.FileSelectorPlatform.instance = previous);
          final api = AcpApi()..metadataOnlyFollow = true;
          await open(t, api, codex, thread: 'ses-1');
          await t.tap(find.byKey(const Key('attach-menu-btn')));
          await t.pumpAndSettle();
          await t.tap(find.byKey(const Key('attach-file-btn')));
          await frames(t);
          final file = SlowMemXFile(
            Uint8List.fromList('must not upload'.codeUnits),
            'pending.md',
          );
          if (reading) {
            selector.selection.complete([file]);
            await frames(t);
            expect(attachmentChips(), findsOneWidget);
          }
          // The normal event-driven history refresh discovers the new
          // ownership while the platform picker/file read is still pending.
          if (guardian) {
            api.appThreads.add(
              const ThreadMeta(
                id: 'ses-1',
                preview: 'Approval review',
                cwd: '/fixture',
                updatedAt: 1,
                parentThreadId: 'parent',
                threadSource: 'guardian_review',
              ),
            );
          } else {
            api.appThreadResumeError = StateError(
              'thread already has an active writer',
            );
          }
          api.pushEvent(
            codex,
            const AppEvent(
              kind: 'thread/compacted',
              threadId: 'ses-1',
              raw: '{}',
            ),
          );
          await frames(t);
          expect(find.byKey(const Key('composer-input')), findsNothing);
          if (guardian) {
            expect(find.byKey(const Key('guardian-read-only')), findsOneWidget);
          }
          if (!reading) selector.selection.complete([file]);
          file.read.complete();
          await frames(t);
          expect(api.lastUploadName, isNull);
          expect(api.lastUploadKey, isNull);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('a clipboard image read when image support goes away attaches '
      'nothing', (t) async {
    await onDesktop(() async {
      final image = Completer<Uint8List?>();
      final previousImage = AppSessionScreen.debugClipboardImage;
      final previousFiles = AppSessionScreen.debugClipboardFiles;
      AppSessionScreen.debugClipboardImage = () => image.future;
      AppSessionScreen.debugClipboardFiles = () async => const [];
      addTearDown(() {
        AppSessionScreen.debugClipboardImage = previousImage;
        AppSessionScreen.debugClipboardFiles = previousFiles;
      });
      final api = AcpApi()..acpCapabilities[acp] = negotiatedWithImages;
      await open(t, api, acp, thread: 'ses-1');
      await paste(t);
      // The reconnected agent no longer takes images.
      api.acpCapabilities[acp] = negotiated;
      api.pushEvent(
        acp,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"phase":"ready","authRequired":false,"connected":true}',
        ),
      );
      await frames(t);
      image.complete(tinyPng());
      await frames(t);
      expect(attachmentChips(), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('a Guardian view refuses dropped documents without uploading', (
    t,
  ) async {
    await onDesktop(() async {
      final api = AcpApi()
        ..appThreads.clear()
        ..appThreads.add(
          const ThreadMeta(
            id: 'reviewer',
            preview: 'Approval review',
            cwd: '/fixture',
            updatedAt: 1,
            parentThreadId: 'parent',
            threadSource: 'guardian_review',
          ),
        )
        ..metadataOnlyFollow = true
        ..readResult = const ThreadHistory(items: [], running: false);
      await open(t, api, codex, thread: 'reviewer');
      expect(find.byKey(const Key('guardian-read-only')), findsOneWidget);
      final drop = t.widget<DropTarget>(find.byType(DropTarget));
      drop.onDragDone!(
        DropDoneDetails(
          files: [
            DropItemFile.fromData(
              Uint8List.fromList('must not upload'.codeUnits),
              path: 'private.md',
            ),
          ],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await frames(t);
      expect(api.lastUploadName, isNull);
      expect(attachmentChips(), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
