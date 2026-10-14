part of '../../fake_bridge_api.dart';

mixin _FakeHostSessions on _FakeBridgeState {
  @override
  Future<SessionControl> appAcpSessionControl(
    String serviceKey,
    String threadId,
  ) async => throw UnsupportedError('No session control fixture');

  @override
  Future<void> appAcpControlSession(
    String serviceKey,
    SessionControl snapshot,
    String action,
  ) async => throw UnsupportedError('No session control fixture');

  @override
  Future<NativeSessionList> appNativeSessions(
    String provider, {
    String? cursor,
    String? sourceId,
  }) async => NativeSessionList(
    sourceId: provider,
    location: '/fixture/$provider',
    sessions: const [],
  );
  @override
  Future<NativeSessionPage> appNativeSessionPage(
    String provider,
    String threadId, {
    String? before,
    String? sourceId,
  }) => throw UnimplementedError('Native fixture required');
  @override
  Future<NativeSessionRevision> appNativeSessionRevision(
    String provider,
    String threadId, {
    String? sourceId,
  }) => throw UnimplementedError('Native fixture required');

  @override
  Future<ForceResumeReport> appForceResume(
    String serviceKey,
    String threadId,
  ) async {
    lastForceResumedKey = serviceKey;
    lastForceResumedThread = threadId;
    return forceResumeResult;
  }

  @override
  Future<List<ThreadItem>> appLocalSessionTranscript(String threadId) async =>
      transcripts[threadId] ?? const [];

  @override
  Future<List<LocalSession>> metaSessions(
    String serviceKey, {
    bool runningOnly = false,
  }) async => (remoteSessions[serviceKey] ?? localSessions)
      .where((session) => !runningOnly || session.safety == 'ownedRunning')
      .toList();

  @override
  Future<SessionLiveness> metaSessionLiveness(
    String serviceKey,
    String threadId,
  ) async => appSessionLiveness(threadId);

  @override
  Stream<SessionFollowUpdate> metaSessionEvents(
    String serviceKey,
    String threadId,
  ) {
    metaSessionEventSubscriptions++;
    final existing = _metaSessionEvents[threadId];
    if (existing != null) return existing.stream;
    late final StreamController<SessionFollowUpdate> controller;
    controller = StreamController<SessionFollowUpdate>.broadcast(
      onListen: () => unawaited(() async {
        if (metaFollowGate != null) await metaFollowGate;
        controller.add(
          SessionFollowUpdate(
            liveness: await appSessionLiveness(threadId),
            items: metadataOnlyFollow
                ? const []
                : transcripts[threadId] ?? const [],
            historyRevision: metadataOnlyFollow ? 'initial' : null,
          ),
        );
      }()),
    );
    _metaSessionEvents[threadId] = controller;
    return controller.stream;
  }

  @override
  Future<List<ThreadItem>> metaSessionTranscript(
    String serviceKey,
    String threadId,
  ) async => transcripts[threadId] ?? const [];

  @override
  Future<ForceResumeReport> metaForceResume(
    String serviceKey,
    String threadId,
  ) async {
    lastMetaResumedKey = serviceKey;
    lastMetaResumedThread = threadId;
    return forceResumeResult;
  }

  @override
  Future<String> metaUploadFile(
    String serviceKey,
    String fileName,
    Uint8List bytes,
  ) async {
    if (uploadError != null) throw uploadError!;
    lastUploadKey = serviceKey;
    lastUploadName = fileName;
    lastUploadBytes = bytes;
    return '/host/uploads/123/$fileName';
  }

  @override
  String metaUploadContext() => uploadContext;

  @override
  Future<String> metaUploadFileScoped(
    String serviceKey,
    String fileName,
    Uint8List bytes,
    String context,
  ) async {
    if (context != uploadContext) {
      throw StateError('attachment context changed');
    }
    return metaUploadFile(serviceKey, fileName, bytes);
  }

  @override
  Future<ThreadConfig> metaThreadConfigGet(
    String serviceKey,
    String threadId,
  ) async {
    lastConfigGetThread = threadId;
    await configReadGate?.future;
    return threadConfigs[threadId] ?? const ThreadConfig();
  }

  @override
  Future<ThreadConfig> metaThreadConfigSet(
    String serviceKey,
    String threadId,
    ThreadConfig config,
  ) async {
    lastConfigSetThread = threadId;
    threadConfigs[threadId] = config;
    return config;
  }

  @override
  Future<ProjectConfig> metaProjectConfig(String serviceKey) async {
    projectConfigCalls++;
    if (failNextProjectConfig) {
      failNextProjectConfig = false;
      throw StateError('meta tunnel not ready');
    }
    return projectConfigs[serviceKey] ?? const ProjectConfig();
  }

  @override
  Future<ProjectConfig> metaSetProjectConfig(
    String serviceKey,
    List<String> projectRoots,
    String? defaultProject,
  ) async {
    final cfg = ProjectConfig(
      projectRoots: projectRoots,
      defaultProject: defaultProject,
    );
    projectConfigs[serviceKey] = cfg;
    return cfg;
  }

  @override
  Future<List<HostDirEntry>> metaListDir(
    String serviceKey,
    String path,
  ) async => dirTree[path] ?? const [];

  @override
  Future<List<HostFileEntry>> metaListFiles(
    String serviceKey,
    String path,
  ) async => fileTree[path] ?? const [];

  @override
  Future<Uint8List> metaReadFile(String serviceKey, String path) async =>
      fileBytes[path] ?? Uint8List(0);
  @override
  Future<bool> metaHostIsLocal(String serviceKey) async => hostIsLocal;

  @override
  Future<FilePreviewData> metaFilePreview(
    String serviceKey,
    String? threadId,
    String href,
  ) async {
    filePreviewRequests.add('$serviceKey/$threadId/$href');
    final bytes = fileBytes[href];
    if (bytes == null) throw StateError('File unavailable');
    return FilePreviewData(bytes: bytes, totalSize: bytes.length);
  }

  @override
  Future<void> metaFileDownload(
    String serviceKey,
    String? threadId,
    String href,
    String destination,
  ) async {
    throw UnimplementedError(
      'Seed a file download implementation in this test',
    );
  }

  @override
  Future<Uint8List> metaReadThreadImage(
    String serviceKey,
    String threadId,
    String path,
  ) async {
    final bytes = threadImageBytes[path];
    if (bytes == null) {
      throw StateError('403 path is outside the configured project roots');
    }
    return bytes;
  }

  @override
  Future<String> metaWriteFile(
    String serviceKey,
    String dir,
    String fileName,
    Uint8List bytes,
  ) async {
    lastWriteDir = dir;
    lastWriteName = fileName;
    return '$dir/$fileName';
  }
}
