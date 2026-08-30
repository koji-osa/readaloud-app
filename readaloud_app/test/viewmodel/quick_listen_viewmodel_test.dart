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

  @override
  Future<void> save(Content content) async {
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
