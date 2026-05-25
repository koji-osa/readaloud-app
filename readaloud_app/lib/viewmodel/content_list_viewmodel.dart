import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../usecase/content/get_all_contents_usecase.dart';
import '../usecase/content/delete_content_usecase.dart';
import '../usecase/content/update_content_usecase.dart';
import '../repository/playback_repository.dart';

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

  // コンテンツ一覧を取得
  Future<void> loadContents() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final contents = state.selectedFilter == 'all'
          ? await _getAllContents.execute()
          : await _getAllContents.executeByStatus(state.selectedFilter);

      // 各コンテンツの進捗率を取得
      final progressMap = <String, double>{};
      for (final c in contents) {
        final playback = await _playbackRepo.getByContentId(c.id);
        if (playback != null) {
          progressMap[c.id] = playback.progressPct;
        }
      }

      state = state.copyWith(
        contents: contents,
        progressMap: progressMap,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'コンテンツの取得に失敗しました: $e',
      );
    }
  }

  // フィルターを変更
  Future<void> changeFilter(String filter) async {
    state = state.copyWith(selectedFilter: filter);
    await loadContents();
  }

  // コンテンツを削除
  Future<void> deleteContent(String id) async {
    try {
      await _deleteContent.execute(id);
      await loadContents();
    } catch (e) {
      state = state.copyWith(errorMessage: '削除に失敗しました: $e');
    }
  }

  // タイトルを編集
  Future<void> updateTitle(String id, String newTitle) async {
    try {
      await _updateContent.execute(id: id, title: newTitle);
      await loadContents();
    } catch (e) {
      state = state.copyWith(errorMessage: 'タイトルの更新に失敗しました: $e');
    }
  }
}
