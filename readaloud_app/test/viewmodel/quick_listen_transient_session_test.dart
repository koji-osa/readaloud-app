import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/content/library_promotion_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/playback_defaults_reader.dart';
import 'package:readaloud_app/usecase/playback/playback_usage_accounting.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';

// Shared Player Core Slice 5: Transient session 正式化
// T-S1 / T-S2 / T-S3 / T-E1 / T-N3 / terminal close（INV-T3/T7/T10）
void main() {
  late _RecordingTts tts;
  late _RecordingFence fence;
  late StreamController<dynamic> positions;
  late int handlerPosition;
  late SharedPlaybackTransport transport;
  late _FakeDefaultsReader defaults;
  late QuickListenViewModel vm;

  QuickListenSession session(String text) => QuickListenSession(
        request: PlaybackRequest(
          target: const TransientTarget(),
          text: text,
          startPosition: 0,
          source: const SourceDescriptor(sourceType: 'share'),
        ),
      );

  Future<void> emit(int pos, {bool playing = true}) async {
    positions.add(TtsPlaybackPosition(
      charPosition: pos,
      isPlaying: playing,
      ttsStatus: playing ? TtsStatus.playing : TtsStatus.paused,
    ));
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    DebugLogger.testSink = [];
    tts = _RecordingTts();
    fence = _RecordingFence();
    positions = StreamController<dynamic>.broadcast(sync: true);
    handlerPosition = 0;
    transport = SharedPlaybackTransport(
      tts: tts,
      positionStream: positions.stream,
      currentPosition: () => handlerPosition,
      resumeFence: fence,
    );
    defaults = _FakeDefaultsReader(1.0);
    vm = QuickListenViewModel(
      transport: transport,
      defaultsReader: defaults,
      promotion: LibraryPromotionService(
        saveContent: SaveContentUseCase(_ThrowingContentRepository()),
        playbackRepo: _ThrowingPlaybackRepository(),
        defaultsReader: defaults,
      ),
    );
  });

  tearDown(() async {
    DebugLogger.testSink = null;
    if (vm.mounted) vm.dispose();
    transport.dispose();
    await positions.close();
  });

  group('T-S1: tap-to-seek', () {
    test('停止中のタップは位置だけを更新し、TTSへは作用しない。次のplayはその位置から', () async {
      vm.start(session('0123456789ABCDEFGHIJ'));
      await vm.seekToPosition(7);
      expect(vm.state.highlightPosition, 7);
      expect(tts.calls, isEmpty);

      await vm.play();
      expect(tts.calls, ['speak:7']);
    });

    test('再生中のタップは stop(owner) → position → start(pos) で再開する', () async {
      vm.start(session('0123456789ABCDEFGHIJ'));
      await vm.play();
      await emit(3);
      tts.calls.clear();

      await vm.seekToPosition(12);

      expect(tts.calls, ['stop', 'speak:12']);
      expect(vm.state.highlightPosition, 12);
      expect(vm.state.isPlaying, isTrue);
      expect(transport.activeOwner,
          PlaybackOwnerKey.transient(vm.state.session!.id));
    });

    test('タップ位置は本文長へclampされる', () async {
      vm.start(session('abc'));
      await vm.seekToPosition(99);
      expect(vm.state.highlightPosition, 3);
    });
  });

  test('T-S2: seek-to-start は再生中なら先頭から再開し、停止中なら位置0へ', () async {
    vm.start(session('0123456789'));
    await vm.seekToPosition(5);
    await vm.seekToStart();
    expect(vm.state.highlightPosition, 0);

    await vm.play();
    await emit(4);
    tts.calls.clear();
    await vm.seekToStart();
    expect(tts.calls, ['stop', 'speak:0']);
  });

  test('T-S3: pause → play で一時停止位置から再開する', () async {
    vm.start(session('0123456789ABCDEFGHIJ'));
    await vm.play();
    await emit(9);
    handlerPosition = 9;

    await vm.pause();
    expect(vm.state.isPlaying, isFalse);
    expect(vm.state.highlightPosition, 9);

    await vm.play();
    expect(tts.calls, ['speak:0', 'pause', 'speak:9']);
  });

  group('T-E1: stale event', () {
    test('他owner（NP）の受理済みeventはTransient stateへ反映しない', () async {
      vm.start(session('0123456789'));
      await transport.start(
        PlaybackOwnerKey.normalPlayer('np-1'),
        PlaybackRequest(
            target: const TransientTarget(), text: 'x' * 900, startPosition: 0),
        accounting: const NoUsageAccounting(),
      );
      await emit(601);
      expect(vm.state.highlightPosition, 0);
      expect(vm.state.isPlaying, isFalse);
    });

    test('close後に届いたeventは破棄済みsessionへも新sessionへも反映しない', () async {
      vm.start(session('0123456789'));
      await vm.play();
      await emit(3);
      await vm.close();
      await emit(8);
      expect(vm.state.session, isNull);
      expect(vm.state.highlightPosition, 0);

      vm.start(session('abcdefghij'));
      await emit(5);
      expect(vm.state.highlightPosition, 0);
    });
  });

  test('T-N3: defaultSpeedはread-onlyなPlaybackDefaultsReaderからplay時に読む',
      () async {
    defaults.speed = 1.75;
    vm.start(session('0123456789'));
    await vm.play();
    expect(tts.speeds, [1.75]);
    expect(defaults.readCount, 1);

    defaults.speed = 2.0;
    await vm.seekToPosition(0); // 停止中ではないため stop → start
    expect(tts.speeds.last, 2.0, reason: '取得タイミングは再生開始時');
  });

  group('terminal close（INV-T3 / INV-T7 / INV-T10 / NEW-Q1=A）', () {
    test('owner一致: stop + fence(clearIfNoLiveOwner) + state破棄。再openは位置0から',
        () async {
      vm.start(session('0123456789'));
      await vm.play();
      await emit(6);

      await vm.close();

      expect(tts.calls.last, 'stop');
      expect(fence.calls, [NotificationDisposition.clearIfNoLiveOwner]);
      expect(transport.activeOwner, isNull);
      expect(vm.state.session, isNull);

      vm.start(session('0123456789'));
      expect(vm.state.highlightPosition, 0, reason: 'AC-07');
    });

    test('share到着時のretire（shareTeardown）はhandoff fence', () async {
      vm.start(session('0123456789'));
      await vm.play();
      await vm.close(reason: TeardownReason.shareTeardown);
      expect(fence.calls, [NotificationDisposition.handoff]);
    });

    test('stale close: 旧sessionのcloseが遅れて届いても現sessionのTTS・fence・stateへ触れない',
        () async {
      vm.start(session('OLD-TEXT'));
      final oldId = vm.state.session!.id;
      vm.start(session('NEW-TEXT'));
      await vm.play();
      await emit(2);
      tts.calls.clear();

      await vm.close(sessionId: oldId);

      expect(tts.calls, isEmpty);
      expect(fence.calls, isEmpty);
      expect(vm.state.session!.request.text, 'NEW-TEXT');
      expect(vm.state.isPlaying, isTrue);
    });

    test('TTS stop失敗でもsession stateは破棄される（routeを閉じられる）', () async {
      vm.start(session('0123456789'));
      await vm.play();
      tts.failStop = true;
      await vm.close();
      expect(vm.state.session, isNull);
    });
  });

  test('AC-19: start失敗後はエラー表示され、次のplayはクリーンに開始できる', () async {
    vm.start(session('0123456789'));
    tts.failSpeak = true;
    await vm.play();
    expect(vm.state.errorMessage, contains('再生に失敗しました'));
    expect(vm.state.isPlaying, isFalse);
    expect(transport.activeOwner, isNull);

    tts.failSpeak = false;
    vm.clearError();
    await vm.play();
    expect(vm.state.isPlaying, isTrue);
  });
}

class _FakeDefaultsReader implements PlaybackDefaultsReader {
  _FakeDefaultsReader(this.speed);
  double speed;
  int readCount = 0;

  @override
  Future<double> readDefaultSpeed() async {
    readCount++;
    return speed;
  }
}

class _RecordingTts implements TtsService {
  final List<String> calls = [];
  final List<double> speeds = [];
  bool failSpeak = false;
  bool failStop = false;

  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {
    if (failSpeak) throw StateError('speak failed');
    calls.add('speak:$startPosition');
    speeds.add(speed);
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failStop) throw StateError('stop failed');
  }

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _RecordingFence implements PlaybackResumeFence {
  final List<NotificationDisposition> calls = [];

  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async =>
      calls.add(notificationDisposition);
}

class _ThrowingContentRepository implements ContentRepository {
  Never _fail() => throw StateError('Transient再生操作はContentRepositoryへ到達しない');

  @override
  Future<void> save(Content content) async => _fail();

  @override
  Future<List<Content>> getAll() async => _fail();

  @override
  Future<List<Content>> getByStatus(String status) async => _fail();

  @override
  Future<Content?> getById(String id) async => _fail();

  @override
  Future<void> update(Content content) async => _fail();

  @override
  Future<void> delete(String id) async => _fail();
}

class _ThrowingPlaybackRepository implements PlaybackRepository {
  Never _fail() => throw StateError('Transient再生操作はPlaybackRepositoryへ到達しない');

  @override
  Future<PlaybackState?> getByContentId(String contentId) async => _fail();

  @override
  Future<void> save(PlaybackState state) async => _fail();

  @override
  Future<void> resetAbRepeat(String contentId) async => _fail();

  @override
  Future<void> resetAllAbRepeat() async => _fail();

  @override
  Future<void> delete(String contentId) async => _fail();
}
