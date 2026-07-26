import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repository/obsidian_repository.dart';
import '../repository/vault_data_source.dart';
import '../usecase/content/import_content_usecase.dart';
import '../usecase/obsidian/obsidian_importer.dart';
import '../util/markdown_content_parser.dart';

/// ノート取り込み1回分の結果集計。
class ImportSummary {
  const ImportSummary({required this.successCount, required this.failureCount});

  final int successCount;
  final int failureCount;
}

class ObsidianImportState {
  final bool isLoading;
  final bool vaultConfigured;
  final List<VaultEntry> notes;
  final Set<String> selectedUris;
  final bool isImporting;
  final ImportSummary? importResult;

  ObsidianImportState({
    this.isLoading = false,
    this.vaultConfigured = false,
    this.notes = const [],
    this.selectedUris = const {},
    this.isImporting = false,
    this.importResult,
  });

  ObsidianImportState copyWith({
    bool? isLoading,
    bool? vaultConfigured,
    List<VaultEntry>? notes,
    Set<String>? selectedUris,
    bool? isImporting,
    ImportSummary? importResult,
  }) =>
      ObsidianImportState(
        isLoading: isLoading ?? this.isLoading,
        vaultConfigured: vaultConfigured ?? this.vaultConfigured,
        notes: notes ?? this.notes,
        selectedUris: selectedUris ?? this.selectedUris,
        isImporting: isImporting ?? this.isImporting,
        // importResultは消費（SnackBar表示）後にclearImportResult()で明示的に
        // nullへ戻す前提のため、他の更新時に引き継がない（successMessage等と同様の設計）。
        importResult: importResult,
      );
}

/// Obsidian Vault内のノート一覧表示・複数選択・取り込みを管理するViewModel。
class ObsidianImportViewModel extends StateNotifier<ObsidianImportState> {
  ObsidianImportViewModel({
    required ObsidianRepository repository,
    required ObsidianImporter importer,
    required ImportContentUseCase importContent,
  })  : _repository = repository,
        _importer = importer,
        _importContent = importContent,
        super(ObsidianImportState());

  final ObsidianRepository _repository;
  final ObsidianImporter _importer;
  final ImportContentUseCase _importContent;

  /// Vault内のノート一覧を読み込む。
  ///
  /// listNotes()はVault未設定でも空リストを返すため、Vault未設定かどうかは
  /// getVaultUri()の結果で別途判定する。
  Future<void> loadNotes() async {
    state = state.copyWith(isLoading: true);

    try {
      final vaultUri = await _repository.getVaultUri();
      if (vaultUri == null) {
        state = state.copyWith(vaultConfigured: false, notes: []);
        return;
      }

      final notes = await _repository.listNotes();
      state = state.copyWith(vaultConfigured: true, notes: notes);
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  /// [uri]の選択状態を切り替える。
  void toggleSelection(String uri) {
    final selected = Set<String>.from(state.selectedUris);
    if (!selected.remove(uri)) {
      selected.add(uri);
    }
    state = state.copyWith(selectedUris: selected);
  }

  /// 選択中の全ノートを取り込む。
  ///
  /// [shouldClean]がtrueの場合、Obsidian記法変換後の本文に対して
  /// TextCleaner.clean()を適用する([ImportContentUseCase.execute]に委譲)。
  Future<void> importSelected({bool shouldClean = false}) async {
    if (state.selectedUris.isEmpty || state.isImporting) return;

    state = state.copyWith(isImporting: true);

    try {
      final results = await _importer.importNotes(state.selectedUris.toList());

      var successCount = 0;
      var failureCount = 0;
      for (final result in results) {
        if (!result.isSuccess) {
          failureCount++;
          continue;
        }
        try {
          await _importContent.execute(
            raw: result.content!,
            parser: MarkdownContentParser(obsidianExtensions: true),
            sourceType: 'obsidian',
            shouldClean: shouldClean,
          );
          successCount++;
        } catch (_) {
          failureCount++;
        }
      }

      state = state.copyWith(
        selectedUris: {},
        importResult: ImportSummary(successCount: successCount, failureCount: failureCount),
      );
    } finally {
      // importResultはcopyWith()内で明示的に渡さない限りnullへ戻る設計のため、
      // ここで現在値を渡し直して直前の集計結果を保持する。
      state = state.copyWith(isImporting: false, importResult: state.importResult);
    }
  }

  void clearImportResult() => state = state.copyWith(importResult: null);
}
