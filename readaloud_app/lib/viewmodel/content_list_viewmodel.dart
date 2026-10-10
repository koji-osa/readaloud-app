import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../usecase/content/get_all_contents_usecase.dart';
import '../usecase/content/delete_content_usecase.dart';
import '../usecase/content/update_content_usecase.dart';
import '../repository/playback_repository.dart';
import '../util/debug_logger.dart';

class ContentListState {
  final List<Content> contents;
  final bool isLoading;
  final String? errorMessage;
  final String selectedFilter; // 'all' / 'unread' / 'in_progress' / 'completed'
  final Map<String, double> progressMap; // contentId → progressPct

  ContentListState({
    this.contents = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedFilter = 'all',
    this.progressMap = const {},
  });

  ContentListState copyWith({
    List<Content>? contents,
    bool? isLoading,
    String? errorMessage,
    String? selectedFilter,
    Map<String, double>? progressMap,
  }) =>
      ContentListState(
        contents: contents ?? this.contents,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: errorMessage,
        selectedFilter: selectedFilter ?? this.selectedFilter,
        progressMap: progressMap ?? this.progressMap,
      );
}

class ContentListViewModel extends StateNotifier<ContentListState> {
  final GetAllContentsUseCase _getAllContents;
  final DeleteContentUseCase _deleteContent;
  final UpdateContentUseCase _updateContent;
  final PlaybackRepository _playbackRepo;

  ContentListViewModel({
    required GetAllContentsUseCase getAllContents,
    required DeleteContentUseCase deleteContent,
    required UpdateContentUseCase updateContent,
    required PlaybackRepository playbackRepo,
  })  : _getAllContents = getAllContents,
        _deleteContent = deleteContent,
        _updateContent = updateContent,
        _playbackRepo = playbackRepo,
        super(ContentListState()) {
    loadContents();
  }

  // loadContents() の世代番号。最新の呼び出しだけが state へ commit できる
  // (Latest request wins)。古い request の完了が新しい filter の結果や
  // isLoading / errorMessage を上書きしないようにする。
  int _loadGeneration = 0;

  bool _isLatest(int requestId) => mounted && requestId == _loadGeneration;

  void _log(String name, Map<String, Object?> fields) {
    // ログ失敗が一覧読み込みへ波及しないようにする。本文・タイトルは渡さない。
    DebugLogger.instance.logEvent(name, fields).catchError((_) {});
  }

  // コンテンツ一覧を取得
  Future<void> loadContents() async {
    final requestId = ++_loadGeneration;
    final filter = state.selectedFilter;
    final stopwatch = Stopwatch()..start();
    state = state.copyWith(isLoading: true, errorMessage: null);
    _log('content_list_load_start', {'requestId': requestId, 'filter': filter});

    // Step 1: Content 一覧の取得。失敗は一覧 load 全体の failure。
    final List<Content> contents;
    try {
      contents = filter == 'all'
          ? await _getAllContents.execute()
          : await _getAllContents.executeByStatus(filter);
    } catch (e) {
      if (!_isLatest(requestId)) {
        _log('content_list_load_obsolete', {'requestId': requestId});
        return;
      }
      _log('content_list_load_error', {
        'requestId': requestId,
        'stage': 'content_query',
        'errorType': e.runtimeType,
      });
      state = state.copyWith(
        isLoading: false,
        // 内部例外(DB/path 等)はユーザー表示に出さず、errorType は log に残す。
        errorMessage: 'コンテンツの取得に失敗しました。再試行してください。',
      );
      return;
    }
    if (!_isLatest(requestId)) {
      _log('content_list_load_obsolete', {'requestId': requestId});
      return;
    }
    _log('content_query_done', {
      'requestId': requestId,
      'count': contents.length,
      'elapsedMs': stopwatch.elapsedMilliseconds,
    });

    // Step 2: 一覧を先に commit する。進捗の enrichment (playback lookup) が
    // pending / stall / 失敗しても、取得済みの一覧は表示可能な状態にする。
    // progressMap は取得済み Content に対応する既存値だけを引き継ぐ。
    final ids = contents.map((c) => c.id).toSet();
    final initialProgress = <String, double>{
      for (final e in state.progressMap.entries)
        if (ids.contains(e.key)) e.key: e.value,
    };
    state = state.copyWith(
      contents: contents,
      progressMap: initialProgress,
      isLoading: false,
    );
    _log('content_list_load_commit', {
      'requestId': requestId,
      'filter': filter,
      'contentCount': contents.length,
    });

    // Step 3: 進捗率の enrichment。個別の失敗は一覧に影響させない
    // (失敗した Content は進捗 0 のまま表示する)。
    final progressMap = <String, double>{};
    var enrichmentFailures = 0;
    for (final c in contents) {
      try {
        final playback = await _playbackRepo.getByContentId(c.id);
        if (playback != null) {
          progressMap[c.id] = playback.progressPct;
        }
      } catch (e) {
        enrichmentFailures++;
        // 一時的な lookup 失敗で、先行 commit に引き継いだ既知 progress を 0 へ後退させない。
        final known = initialProgress[c.id];
        if (known != null) progressMap[c.id] = known;
        // contentId / title / body は記録しない。
        _log('progress_enrichment_failure', {
          'requestId': requestId,
          'stage': 'playback_lookup',
          'failureOrdinal': enrichmentFailures,
          'errorType': e.runtimeType.toString(),
        });
      }
      if (!_isLatest(requestId)) {
        _log('content_list_load_obsolete', {'requestId': requestId});
        return;
      }
    }
    _log('progress_enrichment_done', {
      'requestId': requestId,
      'count': progressMap.length,
      'failureCount': enrichmentFailures,
    });

    if (!mapEquals(progressMap, state.progressMap)) {
      state = state.copyWith(
        progressMap: progressMap,
        errorMessage: state.errorMessage,
      );
    }
  }

  // フィルターを変更
  Future<void> changeFilter(String filter) async {
    if (filter == state.selectedFilter) {
      // 同一 filter は refresh 扱い。load 失敗でも既存の一覧/progress を保持する。
      await loadContents();
      return;
    }
    // filter 変更時は旧 filter 由来の一覧/progress を破棄する。新 filter の query が
    // 失敗しても旧 filter の一覧を新 filter として表示しないため。
    state = state.copyWith(
      selectedFilter: filter,
      contents: const [],
      progressMap: const {},
    );
    await loadContents();
  }

  // コンテンツを削除
  Future<void> deleteContent(String id) async {
    try {
      await _deleteContent.execute(id);
      await loadContents();
    } catch (e) {
      _log('content_mutation_error',
          {'operation': 'delete', 'errorType': e.runtimeType.toString()});
      state = state.copyWith(errorMessage: '削除に失敗しました。もう一度お試しください。');
    }
  }

  // タイトルを編集
  Future<void> updateTitle(String id, String newTitle) async {
    try {
      await _updateContent.execute(id: id, title: newTitle);
      await loadContents();
    } catch (e) {
      _log('content_mutation_error',
          {'operation': 'update_title', 'errorType': e.runtimeType.toString()});
      state = state.copyWith(errorMessage: 'タイトルの更新に失敗しました。もう一度お試しください。');
    }
  }
}
