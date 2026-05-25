import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/content.dart';
import '../usecase/content/save_content_usecase.dart';
import '../usecase/content/fetch_url_content_usecase.dart';
import '../usecase/content/extract_pdf_content_usecase.dart';

class AddContentState {
  final bool isLoading;
  final String? errorMessage;
  final String? successMessage;
  final Content? savedContent;
  final String inputText;
  final String inputUrl;

  AddContentState({
    this.isLoading = false,
    this.errorMessage,
    this.successMessage,
    this.savedContent,
    this.inputText = '',
    this.inputUrl = '',
  });

  AddContentState copyWith({
    bool? isLoading,
    String? errorMessage,
    String? successMessage,
    Content? savedContent,
    String? inputText,
    String? inputUrl,
  }) =>
      AddContentState(
        isLoading: isLoading ?? this.isLoading,
        errorMessage: errorMessage,
        successMessage: successMessage,
        savedContent: savedContent ?? this.savedContent,
        inputText: inputText ?? this.inputText,
        inputUrl: inputUrl ?? this.inputUrl,
      );
}

class AddContentViewModel extends StateNotifier<AddContentState> {
  final SaveContentUseCase _saveContent;
  final FetchUrlContentUseCase _fetchUrl;
  final ExtractPdfContentUseCase _extractPdf;

  AddContentViewModel({
    required SaveContentUseCase saveContent,
    required FetchUrlContentUseCase fetchUrl,
    required ExtractPdfContentUseCase extractPdf,
  })  : _saveContent = saveContent,
        _fetchUrl = fetchUrl,
        _extractPdf = extractPdf,
        super(AddContentState());

  // テキスト入力から保存
  Future<Content?> saveFromText(String text) async {
    if (text.trim().isEmpty) {
      state = state.copyWith(errorMessage: 'テキストを入力してください');
      return null;
    }
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final content = await _saveContent.execute(
        body: text.trim(),
        sourceType: 'text',
      );
      state = state.copyWith(
        isLoading: false,
        savedContent: content,
        successMessage: 'コンテンツを保存しました',
      );
      return content;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '保存に失敗しました: $e',
      );
      return null;
    }
  }

  // URLから取得して保存
  Future<Content?> saveFromUrl(String url) async {
    if (url.trim().isEmpty) {
      state = state.copyWith(errorMessage: 'URLを入力してください');
      return null;
    }
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _fetchUrl.execute(url.trim());
      final content = await _saveContent.execute(
        body: result.body,
        sourceType: 'url',
        title: result.title.isNotEmpty ? result.title : null,
        sourceUrl: url.trim(),
      );
      state = state.copyWith(
        isLoading: false,
        savedContent: content,
        successMessage: 'Webページを取得しました',
      );
      return content;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'URLの取得に失敗しました: $e',
      );
      return null;
    }
  }

  // PDFから取得して保存
  Future<Content?> saveFromPdf(String filePath) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _extractPdf.execute(filePath);
      final content = await _saveContent.execute(
        body: result.body,
        sourceType: 'file',
        title: result.title,
        sourceFilename: filePath.split('/').last,
      );
      state = state.copyWith(
        isLoading: false,
        savedContent: content,
        successMessage: 'PDFを読み込みました',
      );
      return content;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'PDFの読み込みに失敗しました: $e',
      );
      return null;
    }
  }

  // Share Intentから保存
  Future<Content?> saveFromShare(String text) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final content = await _saveContent.execute(
        body: text.trim(),
        sourceType: 'share',
      );
      state = state.copyWith(
        isLoading: false,
        savedContent: content,
        successMessage: 'コンテンツを保存しました',
      );
      return content;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '保存に失敗しました: $e',
      );
      return null;
    }
  }

  void clearError() => state = state.copyWith(errorMessage: null);
  void clearSuccess() => state = state.copyWith(successMessage: null);
}
