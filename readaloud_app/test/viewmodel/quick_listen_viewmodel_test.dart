import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';

void main() {
  group('QuickListenViewModel', () {
    late _FakeContentRepository contentRepo;
    late _FakeSettingsRepository settingsRepo;
    late _FakeTtsService ttsService;
    late QuickListenViewModel viewModel;

    setUp(() {
      contentRepo = _FakeContentRepository();
      settingsRepo = _FakeSettingsRepository();
      ttsService = _FakeTtsService();
      final countUsage = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      viewModel = QuickListenViewModel(
        ttsService: ttsService,
        settingsRepo: settingsRepo,
        saveContent: SaveContentUseCase(contentRepo),
        countUsage: countUsage,
        positionStream: const Stream.empty(),
        getCurrentPosition: () => 0,
      );
    });

    test('start()でセッションを開いただけではDBに一切書き込まれない', () {
      viewModel.start(QuickListenSession(text: '共有された本文'));

      expect(viewModel.state.session, isNotNull);
      expect(viewModel.state.session!.text, '共有された本文');
      expect(contentRepo.saved, isEmpty);
    });

    test('play()は既存TtsServiceのspeakを呼ぶだけでDBには書き込まれない', () async {
      viewModel.start(QuickListenSession(text: '読み上げるテキスト'));

      await viewModel.play();

      expect(ttsService.speakCalls, hasLength(1));
      expect(ttsService.speakCalls.single, '読み上げるテキスト');
      expect(contentRepo.saved, isEmpty);
    });

    test('空文字・空白のみのテキストではplay()は何もしない（不正payloadの安全な処理）', () async {
      viewModel.start(QuickListenSession(text: '   '));

      await viewModel.play();

      expect(ttsService.speakCalls, isEmpty);
    });

    test('close()はTTSを止めてセッションを破棄するが、DBへは一切書き込まれない', () async {
      viewModel.start(QuickListenSession(text: '本文'));
      await viewModel.play();

      await viewModel.close();

      expect(ttsService.stopCalls, 1);
      expect(viewModel.state.session, isNull);
      expect(contentRepo.saved, isEmpty);
    });

    test('save()は通常Contentを1回だけ作成する（初回保存）', () async {
      viewModel.start(QuickListenSession(text: '保存するテキスト', title: 'タイトル'));

      final content = await viewModel.save();

      expect(content, isNotNull);
      expect(contentRepo.saved, hasLength(1));
      expect(contentRepo.saved.single.body, '保存するテキスト');
      expect(contentRepo.saved.single.sourceType, 'share');
      expect(viewModel.state.hasSaved, isTrue);
    });

    test('同一セッションからsave()を複数回呼んでも二重保存されない', () async {
      viewModel.start(QuickListenSession(text: '保存するテキスト'));

      final first = await viewModel.save();
      final second = await viewModel.save();

      expect(contentRepo.saved, hasLength(1));
      expect(second, same(first));
    });

    test('save()を同時(Future.wait)に呼んでも二重保存されず、両方の呼び出し元が同じ結果を受け取る'
        '（concurrent double tap対策）', () async {
      viewModel.start(QuickListenSession(text: '同時タップされるテキスト'));

      final results = await Future.wait([viewModel.save(), viewModel.save()]);

      expect(contentRepo.saved, hasLength(1));
      expect(results[0], isNotNull);
      // 2回目の呼び出しが1回目の完了を待たずに古い状態(null)を返してしまう
      // 回帰がないことを確認する。
      expect(results[1], same(results[0]));
    });

    test('save()実行中に新しい共有でセッションが置き換わっても、完了時に古いセッションの状態で上書きしない',
        () async {
      viewModel.start(QuickListenSession(text: '保存対象だったテキストA'));
      final pendingSave = viewModel.save();

      // 保存が完了する前（マイクロタスクが進む前）に新しい共有が届いたケースを再現
      viewModel.start(QuickListenSession(text: 'B（Aの保存中に届いた新しい共有）'));

      final result = await pendingSave;

      expect(result, isNotNull);
      expect(contentRepo.saved, hasLength(1));
      expect(contentRepo.saved.single.body, '保存対象だったテキストA');
      // 画面には新しいセッションBがそのまま表示され続け、Aの保存完了によって
      // 上書きされていないこと（=表示中テキストが勝手に巻き戻らないこと）を確認
      expect(viewModel.state.session!.text, 'B（Aの保存中に届いた新しい共有）');
      expect(viewModel.state.hasSaved, isFalse);
    });

    test('save()が失敗した場合は何も保存されず、再試行(retry)で成功した時だけ1件保存される',
        () async {
      contentRepo.failNextSaves = 1;
      viewModel.start(QuickListenSession(text: '失敗後にリトライするテキスト'));

      final failedResult = await viewModel.save();
      expect(failedResult, isNull);
      expect(contentRepo.saved, isEmpty);
      expect(viewModel.state.hasSaved, isFalse);
      expect(viewModel.state.errorMessage, isNotNull);

      final retryResult = await viewModel.save();

      expect(retryResult, isNotNull);
      expect(contentRepo.saved, hasLength(1));
      expect(viewModel.state.hasSaved, isTrue);
    });

    test('start()で既存セッションが再生中に新しい共有が来ると、旧セッションの音声を止めてから置き換える', () async {
      viewModel.start(QuickListenSession(text: '旧テキスト'));
      await viewModel.play();
      expect(ttsService.speakCalls, hasLength(1));

      viewModel.start(QuickListenSession(text: '新しいテキスト'));

      // 旧セッションの音声がstop()されたことを確認（新テキストが混ざって聞こえる回帰を防止）
      expect(ttsService.stopCalls, greaterThanOrEqualTo(1));
      expect(viewModel.state.session!.text, '新しいテキスト');
      expect(viewModel.state.isPlaying, isFalse);
    });

    test('最初のstart()（既存セッションなし）ではTTSのstop()を余計に呼ばない', () {
      viewModel.start(QuickListenSession(text: '最初のテキスト'));

      expect(ttsService.stopCalls, 0);
    });
  });
}

class _FakeTtsService implements TtsService {
  final List<String> speakCalls = [];
  int stopCalls = 0;
  int pauseCalls = 0;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    speakCalls.add(text);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _FakeSettingsRepository implements SettingsRepository {
  final Map<String, String> _store = {};

  @override
  Future<String?> get(String key) async => _store[key];

  @override
  Future<void> set(String key, String value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_store);
}

class _FakeContentRepository implements ContentRepository {
  final List<Content> saved = [];

  /// 次のsave()呼び出しをこの回数だけ失敗させる（retryテスト用）。
  int failNextSaves = 0;

  @override
  Future<void> save(Content content) async {
    if (failNextSaves > 0) {
      failNextSaves--;
      throw Exception('保存に失敗しました（テスト用）');
    }
    saved.add(content);
  }

  @override
  Future<List<Content>> getAll() async =>
      throw UnimplementedError('Quick Listenでは使用されないはず');

  @override
  Future<List<Content>> getByStatus(String status) async =>
      throw UnimplementedError('Quick Listenでは使用されないはず');

  @override
  Future<Content?> getById(String id) async =>
      throw UnimplementedError('Quick Listenでは使用されないはず');

  @override
  Future<void> update(Content content) async =>
      throw UnimplementedError('Quick Listenでは使用されないはず');

  @override
  Future<void> delete(String id) async =>
      throw UnimplementedError('Quick Listenでは使用されないはず');
}
