import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/util/share_fingerprint.dart';
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

  group('QuickListenViewModel Observability（症状1のEvidence）', () {
    late _FakeContentRepository contentRepo;
    late _FakeSettingsRepository settingsRepo;
    late _FakeTtsService ttsService;
    late StreamController<dynamic> positionController;
    late QuickListenViewModel viewModel;

    setUp(() {
      DebugLogger.testSink = [];
      contentRepo = _FakeContentRepository();
      settingsRepo = _FakeSettingsRepository();
      ttsService = _FakeTtsService();
      positionController = StreamController<dynamic>.broadcast();
      final countUsage = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      viewModel = QuickListenViewModel(
        ttsService: ttsService,
        settingsRepo: settingsRepo,
        saveContent: SaveContentUseCase(contentRepo),
        countUsage: countUsage,
        positionStream: positionController.stream,
        getCurrentPosition: () => 0,
      );
    });

    tearDown(() async {
      DebugLogger.testSink = null;
      await positionController.close();
    });

    test(
        'session start → position received → play requested の順でイベントが記録される',
        () async {
      viewModel.start(QuickListenSession(text: '順序を検証するテキスト'));

      // 直前セッション（Player等）から漏れてきた想定のpositionイベント
      positionController.add(const TtsPlaybackPosition(
        charPosition: 999,
        isPlaying: false,
        ttsStatus: TtsStatus.stopped,
      ));
      // ストリームのmicrotaskを消化させる
      await Future.delayed(Duration.zero);

      await viewModel.play();

      final events = DebugLogger.testSink!
          .map((line) => line.split(' ').first.replaceFirst('event=', ''))
          .toList();

      final startedIndex = events.indexOf('quick_listen_session_started');
      final receivedIndex = events.indexOf('tts_position_received');
      final requestedIndex = events.indexOf('tts_play_requested');

      expect(startedIndex, isNonNegative);
      expect(receivedIndex, isNonNegative);
      expect(requestedIndex, isNonNegative);
      expect(startedIndex, lessThan(receivedIndex));
      expect(receivedIndex, lessThan(requestedIndex));
    });

    test('tts_position_receivedの本文断片(word等)は記録されない（DebugLoggerのforbidden key経由で保証）',
        () async {
      viewModel.start(QuickListenSession(text: '本文が漏れないことを確認するテキスト'));
      positionController.add(const TtsPlaybackPosition(
        charPosition: 5,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      await Future.delayed(Duration.zero);

      for (final line in DebugLogger.testSink!) {
        expect(line, isNot(contains('本文が漏れないことを確認するテキスト')));
      }
    });

    test(
        'play()がDebugLogger.logEvent()のawaitで止まっている間にpositionStreamの'
        '更新が届いても、まだこのセッション自身の再生開始が確認できていないため'
        'stateへは反映されず、記録値と実際にspeak()へ渡されたstartPositionも'
        '一致する（食い違いのregression防止。症状1修正後はゲートにより'
        'そもそもstateが汚染されなくなったことも合わせて確認する）', () async {
      final logGate = Completer<void>();
      DebugLogger.testAwaitHook = () => logGate.future;
      addTearDown(() => DebugLogger.testAwaitHook = null);

      viewModel.start(QuickListenSession(text: 'レース条件を検証するテキスト'));

      final playFuture = viewModel.play();
      // play()内部がtts_play_requestedのlogEvent()（testAwaitHook）で
      // 止まるまでマイクロタスクを進める。
      await Future.delayed(Duration.zero);

      // ログ書き込み待ちの間に、positionStream経由で（症状1調査で見つかった
      // 競合パターンを再現するため）isPlaying:trueのイベントが届く。
      // このセッション自身はまだspeak()を呼び出していない（play()内部の
      // ゲートがまだ開いていない）ため、症状1修正後はstateへ反映されない。
      positionController.add(const TtsPlaybackPosition(
        charPosition: 777,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      await Future.delayed(Duration.zero);
      expect(viewModel.state.highlightPosition, 0,
          reason: '症状1修正: play()自身がspeak()を呼ぶ前に届いたイベントは'
              'ゲートにより無視され、stateを汚染しない');

      logGate.complete();
      await playFuture;

      expect(ttsService.speakStartPositions, hasLength(1));
      final actualStartPosition = ttsService.speakStartPositions.single;
      // play()呼び出し時点のhighlightPosition(0)のまま一貫しているべきで、
      // ログ待ち中に届いた777に引きずられてはいけない。
      expect(actualStartPosition, 0);

      final requestedLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=tts_play_requested'));
      expect(requestedLine, contains('startPositionPassedToSpeak=$actualStartPosition'));
      expect(requestedLine, contains('highlightPositionAtPlayCall=$actualStartPosition'));

      final receivedLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=tts_position_received'));
      expect(receivedLine, contains('appliedToState=false'));
    });
  });

  group('QuickListenViewModel 症状1: 旧Player/旧セッションのstale position', () {
    late _FakeContentRepository contentRepo;
    late _FakeSettingsRepository settingsRepo;
    late _FakeTtsService ttsService;
    late StreamController<dynamic> positionController;
    late QuickListenViewModel viewModel;

    setUp(() {
      DebugLogger.testSink = [];
      contentRepo = _FakeContentRepository();
      settingsRepo = _FakeSettingsRepository();
      ttsService = _FakeTtsService();
      positionController = StreamController<dynamic>.broadcast();
      final countUsage = CountTtsUsageUseCase(
        settingsRepo: settingsRepo,
        checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
      );
      viewModel = QuickListenViewModel(
        ttsService: ttsService,
        settingsRepo: settingsRepo,
        saveContent: SaveContentUseCase(contentRepo),
        countUsage: countUsage,
        positionStream: positionController.stream,
        getCurrentPosition: () => 0,
      );
    });

    tearDown(() async {
      DebugLogger.testSink = null;
      await positionController.close();
    });

    test(
        '実機ログ再現: 旧Player position=601 → 新Quick Listen session start → '
        'stale position=601(stopped)が届く → play()はstartPosition:0でspeak()する',
        () async {
      // 直前の通常Playerがcharacter position=601でpauseしていた状態を模し、
      // 新しいQuick Listen sessionをstartする前に共有positionStream
      // (audioHandler.customState相当)へ601/stoppedが流れてくる状況を再現する。
      viewModel.start(QuickListenSession(text: '新しく共有されたテキスト'));
      expect(viewModel.state.highlightPosition, 0,
          reason: '新セッション開始直後はposition=0を維持する');

      // 新session start直後、このセッション自身はまだplay()していないのに
      // 旧Player/旧セッション由来と思われるstale eventが届く。
      positionController.add(const TtsPlaybackPosition(
        charPosition: 601,
        isPlaying: false,
        ttsStatus: TtsStatus.stopped,
      ));
      await Future.delayed(Duration.zero);

      expect(viewModel.state.highlightPosition, 0,
          reason: '症状1修正: play()前に届いたstale positionはstateへ適用されない');
      final staleLine = DebugLogger.testSink!
          .firstWhere((l) => l.contains('charPosition=601'));
      expect(staleLine, contains('appliedToState=false'),
          reason: 'Evidence取得のためログ自体は残しつつ、適用有無を記録する');

      await viewModel.play();

      expect(ttsService.speakStartPositions, hasLength(1));
      expect(ttsService.speakStartPositions.single, 0,
          reason: '実機不具合の再現防止: speak()にstartPosition:601が渡ってはいけない');
      expect(viewModel.state.highlightPosition, 0);
    });

    test('play()直後に旧stopped/pausedイベントが届いてもstateを汚染しない', () async {
      viewModel.start(QuickListenSession(text: '再生直後の汚染を検証するテキスト'));

      await viewModel.play();
      expect(ttsService.speakStartPositions.single, 0);

      // play()呼び出し直後、このセッション自身の再生開始を示すisPlaying:true
      // イベントがまだ届く前に、旧セッション由来と思われるstopped/pausedが
      // 紛れ込んだ場合を再現する。
      positionController.add(const TtsPlaybackPosition(
        charPosition: 601,
        isPlaying: false,
        ttsStatus: TtsStatus.stopped,
      ));
      await Future.delayed(Duration.zero);

      expect(viewModel.state.highlightPosition, 0,
          reason: 'play()直後の旧stopped/pausedイベントでstateが汚染されない');

      // このセッション自身の再生開始を示す最初のisPlaying:trueイベントが届く。
      positionController.add(const TtsPlaybackPosition(
        charPosition: 12,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      await Future.delayed(Duration.zero);

      expect(viewModel.state.highlightPosition, 12,
          reason: 'current-session playingイベント以降は通常どおり反映される');

      // 以降のpositionStream更新も通常どおり反映され続けることを確認する。
      positionController.add(const TtsPlaybackPosition(
        charPosition: 34,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      await Future.delayed(Duration.zero);

      expect(viewModel.state.highlightPosition, 34);
    });

    test(
        '競合ケース: play()後に旧Player由来のstale isPlaying:trueイベント'
        '(sessionId無しのためcharPosition=601)が先着し、その直後に現Quick Listen'
        '自身のcharPosition=0/playingイベントが届く場合でも、最終的にstateは'
        'stale 601へ不正に確定せず、speak()にはstartPosition:0が渡ったままである',
        () async {
      // audioHandler.customStateにはQuick Listen sessionIdが乗らないため、
      // 現在のゲート(_hasCalledPlayForCurrentSession && isPlaying)は
      // 「play()後に届いた最初のisPlaying:trueイベント」を無条件に
      // "このセッション自身の再生開始"とみなしてしまう。もし旧Playerの
      // isPlaying:trueイベント(charPosition=601)がこの意味で「最初の
      // isPlaying:trueイベント」としてplay()直後に紛れ込んだ場合、
      // ゲートはそのstale 601で開いてしまう。この場合でも、後続の
      // 「現Quick Listen自身のcharPosition=0/playing」イベントが正しく
      // 反映されて最終的な表示・状態が0へ復旧することを確認する
      // （=旧Playerのpositionへ不正確定したまま留まる回帰がないことの証明）。
      viewModel.start(QuickListenSession(text: '競合ケースを検証するテキスト'));

      // 旧Player position=601 → 新Quick Listen session start
      expect(viewModel.state.highlightPosition, 0);

      // stale 601/stopped (start()直後、play()より前に届く旧イベント)
      positionController.add(const TtsPlaybackPosition(
        charPosition: 601,
        isPlaying: false,
        ttsStatus: TtsStatus.stopped,
      ));
      await Future.delayed(Duration.zero);
      expect(viewModel.state.highlightPosition, 0,
          reason: 'play()前なので無条件に無視される');

      // play() （snapshotされるstartPositionはこの時点の0）
      await viewModel.play();
      expect(ttsService.speakStartPositions, hasLength(1));
      expect(ttsService.speakStartPositions.single, 0,
          reason: 'speak(startPosition:0)は必ず維持される');

      // stale 601/playing が到着（sessionIdが無いため「このセッションの再生開始」
      // と区別できず、現在のゲート設計ではここで開いてしまう）
      positionController.add(const TtsPlaybackPosition(
        charPosition: 601,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      await Future.delayed(Duration.zero);
      // 現在のゲート設計の既知の弱点: sessionIdが無いためこの時点では
      // 一時的に601が反映されてしまう(ゲートがここで開く)。
      // ただし後続の正しいイベントで必ず上書きされるため「確定」はしない
      // ことを以降で検証する。
      expect(viewModel.state.highlightPosition, 601,
          reason: '既知の弱点: sessionId不在のためstale isPlaying:trueで一時的に'
              '601へ反映されてしまう（次の正しいイベントで直ちに上書きされる）');

      // 現Quick Listen自身のposition=0/playing が到着
      positionController.add(const TtsPlaybackPosition(
        charPosition: 0,
        isPlaying: true,
        ttsStatus: TtsStatus.playing,
      ));
      await Future.delayed(Duration.zero);

      expect(viewModel.state.highlightPosition, 0,
          reason: 'stale 601へ不正に確定せず、正しいセッション自身の位置(0)へ復旧する');
      expect(viewModel.state.isPlaying, isTrue);

      // pause()はstate.highlightPositionではなくgetCurrentPosition()（実機では
      // audioHandler.currentPositionそのもの）を使うため、上記の一時的な601とは
      // 独立しており、pause/resumeが601へ不正確定することはない。
      final position = await () async {
        await viewModel.pause();
        return viewModel.state.highlightPosition;
      }();
      expect(position, 0,
          reason: 'pause()はgetCurrentPosition()由来の値を使うため601に汚染されない'
              '（本テストのFakeはgetCurrentPosition: () => 0固定）');
    });

    test(
        'No.94 Observability: quick_listen_session_startedにpayloadHash/'
        'trimmedPayloadHashが記録され、本文そのものは含まれない', () async {
      const secret = 'SECRET_TEST_PAYLOAD_12345';
      viewModel.start(QuickListenSession(text: secret));

      final line = DebugLogger.testSink!
          .firstWhere((l) => l.contains('event=quick_listen_session_started'));

      final expectedHash = ShareFingerprint.sha256Hex(secret);
      expect(line, contains('payloadHash=$expectedHash'));
      expect(line, contains('trimmedPayloadHash=$expectedHash'));
      expect(line, isNot(contains(secret)));
    });

    test('_handleSharedPayload()相当: セッション未設定のままpositionイベントが届いても'
        'stateへ反映されない（play()を一度も呼んでいないため）', () async {
      // start()すら呼ばれていない（session未設定）状態で、
      // audioHandler.customState購読直後にstale eventが再送されるケースを再現。
      positionController.add(const TtsPlaybackPosition(
        charPosition: 601,
        isPlaying: false,
        ttsStatus: TtsStatus.stopped,
      ));
      await Future.delayed(Duration.zero);

      expect(viewModel.state.session, isNull);
      expect(viewModel.state.highlightPosition, 0);
    });
  });
}

class _FakeTtsService implements TtsService {
  final List<String> speakCalls = [];
  final List<int> speakStartPositions = [];
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
    speakStartPositions.add(startPosition);
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
