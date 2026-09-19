import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:readaloud_app/db/database_helper.dart';
import 'package:readaloud_app/model/bookmark.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/model/quick_listen_session.dart';
import 'package:readaloud_app/model/setting.dart';
import 'package:readaloud_app/model/tts_playback_position.dart';
import 'package:readaloud_app/repository/impl/bookmark_repository_impl.dart';
import 'package:readaloud_app/repository/impl/content_repository_impl.dart';
import 'package:readaloud_app/repository/impl/playback_repository_impl.dart';
import 'package:readaloud_app/repository/impl/settings_repository_impl.dart';
import 'package:readaloud_app/repository/tts/tts_service.dart';
import 'package:readaloud_app/usecase/content/library_promotion_service.dart';
import 'package:readaloud_app/usecase/content/save_content_usecase.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';
import 'package:readaloud_app/usecase/playback/playback_defaults_reader.dart';
import 'package:readaloud_app/usecase/playback/shared_playback_transport.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/viewmodel/quick_listen_viewmodel.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Shared Player Core: Transient no-write 境界（Detailed Design v1.2 FINAL §7.5 / §16）
// T-N1（構造 + sqflite_common_ffi での DB 境界）/ T-N2（tts_used_chars 不変）/
// T-M3（Source 変更・消失後も Library snapshot 不変）。
void main() {
  late StreamController<dynamic> positions;
  late int handlerPosition;
  late SharedPlaybackTransport transport;
  late QuickListenViewModel vm;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbPath = p.join(await getDatabasesPath(), 'readaloud.db');
    final file = File(dbPath);
    if (await file.exists()) await file.delete();
  });

  setUp(() {
    DebugLogger.testSink = [];
    positions = StreamController<dynamic>.broadcast(sync: true);
    handlerPosition = 0;
    transport = SharedPlaybackTransport(
      tts: _NoopTts(),
      positionStream: positions.stream,
      currentPosition: () => handlerPosition,
      resumeFence: _NoopFence(),
    );
    // production と同じ composition（quickListenViewModelProvider と同一構成）。
    final defaultsReader =
        SettingsPlaybackDefaultsReader(SettingsRepositoryImpl());
    vm = QuickListenViewModel(
      transport: transport,
      defaultsReader: defaultsReader,
      promotion: LibraryPromotionService(
        saveContent: SaveContentUseCase(ContentRepositoryImpl()),
        playbackRepo: PlaybackRepositoryImpl(),
        defaultsReader: defaultsReader,
      ),
    );
  });

  tearDown(() async {
    DebugLogger.testSink = null;
    if (vm.mounted) vm.dispose();
    transport.dispose();
    await positions.close();
  });

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final db = await DatabaseHelper().database;
    return {
      for (final table in [
        'contents',
        'playback_states',
        'bookmarks',
        'settings'
      ])
        table: await db.rawQuery('SELECT * FROM $table ORDER BY 1'),
    };
  }

  Future<void> emit(int pos, {bool playing = true}) async {
    handlerPosition = pos;
    positions.add(TtsPlaybackPosition(
        charPosition: pos,
        isPlaying: playing,
        ttsStatus: playing ? TtsStatus.playing : TtsStatus.paused));
    await Future<void>.delayed(Duration.zero);
  }

  test(
      'T-N1 / T-N2: Transientの play / pause / seek / seek-to-start / close 一巡で '
      'contents・playback_states・bookmarks・settings(tts_used_chars) が不変',
      () async {
    final content = Content(
        id: 'lib-1',
        title: 'Library',
        body: 'library body',
        sourceType: 'text');
    await ContentRepositoryImpl().save(content);
    await PlaybackRepositoryImpl().save(
        PlaybackState(contentId: 'lib-1', position: 3, progressPct: 25.0));
    await BookmarkRepositoryImpl()
        .save(Bookmark(contentId: 'lib-1', position: 2, label: 'bm'));
    await SettingsRepositoryImpl().set(SettingKeys.ttsUsedChars, '123');
    await SettingsRepositoryImpl().set(SettingKeys.defaultSpeed, '1.5');

    final before = await snapshot();

    vm.start(QuickListenSession.fromSharedText('Transientで再生する本文です。' * 5));
    await vm.play();
    await emit(5);
    await emit(10);
    await vm.pause();
    await vm.play();
    await emit(12);
    await vm.seekToPosition(20);
    await emit(22);
    await vm.seekToStart();
    await emit(4);
    await vm.close();

    final after = await snapshot();
    expect(after, before,
        reason: 'promotion以外のTransient操作はLibrary tablesへ一切書き込まない（AC-03）');
    expect(
        after['settings']!
            .firstWhere((r) => r['key'] == SettingKeys.ttsUsedChars)['value'],
        '123',
        reason: 'T-N2 / PD-1: Transientはtts_used_charsを更新しない（AC-16）');
  });

  test(
      'T-M3: 保存後にSourceを変更・削除してもLibrary bodyは保存時snapshotのまま、'
      'Transient再生も影響を受けず、Library側で再生できる', () async {
    // simulated Source（供給元）: 保存後に更新・消失する。
    final source = <String, String>{'doc': '保存時点のSource本文。'};

    vm.start(QuickListenSession(
      request: PlaybackRequest(
        target: const TransientTarget(),
        text: source['doc']!,
        title: 'Sourceタイトル',
        startPosition: 0,
        source: const SourceDescriptor(sourceType: 'share'),
      ),
    ));
    final saved = await vm.save();
    expect(saved, isNotNull);

    source['doc'] = '更新後のSource本文（Libraryへは反映されない）';
    source.remove('doc');

    final libraryContent = await ContentRepositoryImpl().getById(saved!.id);
    expect(libraryContent!.body, '保存時点のSource本文。');
    expect(vm.state.session!.request.text, '保存時点のSource本文。');

    // AC-10: Source 消失後も Library の Persistent 経路で本文を解決できる。
    final request = await PersistentPlaybackResolver(
      contentRepo: ContentRepositoryImpl(),
      playbackRepo: PlaybackRepositoryImpl(),
    ).resolveForStart(saved.id);
    expect(request.text, '保存時点のSource本文。');
  });

  test(
      'T-N1（tripwire）: Transient controller / session / Core はwrite-capableな'
      'repository・DAO・DB usecaseをimportしない', () {
    const transientFiles = [
      'lib/viewmodel/quick_listen_viewmodel.dart',
      'lib/model/quick_listen_session.dart',
      'lib/model/playback_request.dart',
      'lib/usecase/playback/shared_playback_transport.dart',
      'lib/usecase/playback/seek_math.dart',
      'lib/repository/tts/playback_resume_fence.dart',
    ];
    const forbidden = [
      'repository/impl/',
      '/db/',
      'content_repository.dart',
      'playback_repository.dart',
      'bookmark_repository.dart',
      'settings_repository.dart',
      'history_repository.dart',
      'save_playback_state_usecase.dart',
      'update_content_usecase.dart',
      'save_content_usecase.dart',
      'usecase/bookmark/',
      'count_tts_usage_usecase.dart',
      'check_tts_limit_usecase.dart',
    ];
    for (final path in transientFiles) {
      final imports = File(path)
          .readAsLinesSync()
          .where((l) => l.trimLeft().startsWith('import '))
          .toList();
      for (final line in imports) {
        for (final f in forbidden) {
          expect(line.contains(f), isFalse, reason: '$path: $line');
        }
      }
    }
  });
}

class _NoopTts implements TtsService {
  @override
  Future<void> speak({
    required String text,
    required int startPosition,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceId,
  }) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<List<VoiceInfo>> getAvailableVoices() async => [];

  @override
  Future<void> dispose() async {}
}

class _NoopFence implements PlaybackResumeFence {
  @override
  Future<void> discardResumeState({
    required NotificationDisposition notificationDisposition,
  }) async {}
}
