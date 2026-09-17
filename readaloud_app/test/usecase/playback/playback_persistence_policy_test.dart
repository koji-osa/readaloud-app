import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/usecase/playback/playback_persistence_policy.dart';
import 'package:readaloud_app/usecase/playback/save_playback_state_usecase.dart';

// Slice 2: PlaybackPersistencePolicy / T-F1
void main() {
  group('TransientPersistencePolicy', () {
    test('依存を持たないconstで、全メソッドがno-op（notApplicable）', () async {
      const policy = TransientPersistencePolicy();
      final result = await policy.persistStopPosition(position: 10);
      expect(result.succeeded, isTrue);
      expect(result.errorType, isNull);
      await policy.persistPosition(position: 1, progressPct: 1);
      await policy.persistVoiceParams(position: 1, progressPct: 1, speed: 2);
    });
  });

  group('PersistentPersistencePolicy', () {
    late _FakeContentRepository contentRepo;
    late _FakePlaybackRepository playbackRepo;
    late PersistentPersistencePolicy policy;

    setUp(() {
      contentRepo = _FakeContentRepository();
      playbackRepo = _FakePlaybackRepository();
      final content =
          Content(id: 'c1', title: 't', body: 'body', sourceType: 'text');
      contentRepo.store['c1'] = content;
      policy = PersistentPersistencePolicy(
        target: PersistentTarget.of(content),
        playbackRepo: playbackRepo,
        savePlaybackState: SavePlaybackStateUseCase(
            playbackRepo: playbackRepo, contentRepo: contentRepo),
      );
    });

    test('persistStopPositionは旧StopPlaybackUseCase step3と同じ値を保存する', () async {
      playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 50, progressPct: 25.0);

      final result = await policy.persistStopPosition(position: 100);

      expect(result.succeeded, isTrue);
      // totalChars = 100 / 0.25 = 400 → progress = 25%
      expect(playbackRepo.store['c1']!.position, 100);
      expect(playbackRepo.store['c1']!.progressPct, 25.0);
    });

    test('progressPctが0の既存状態では従来式（totalChars=1）でclampされcompletedになる', () async {
      final result = await policy.persistStopPosition(position: 7);

      expect(result.succeeded, isTrue);
      expect(playbackRepo.store['c1']!.progressPct, 100.0);
      expect(contentRepo.store['c1']!.status, 'completed',
          reason: 'SavePlaybackStateUseCaseの既存completed分岐をそのまま使う');
    });

    test('保存失敗は例外にならず構造化結果で返る（B-01独立性）', () async {
      playbackRepo.failSave = true;
      final result = await policy.persistStopPosition(position: 3);
      expect(result.succeeded, isFalse);
      expect(result.errorType, isNotNull);
    });
  });

  test(
      'T-F1: TransientTargetはPersistentTargetではなく、PersistentTarget.ofはContent必須',
      () {
    const PlaybackTarget transient = TransientTarget();
    expect(transient, isNot(isA<PersistentTarget>()));
    final content =
        Content(id: 'cx', title: 't', body: 'b', sourceType: 'text');
    expect(PersistentTarget.of(content).contentId, 'cx');
  });
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> store = {};

  @override
  Future<Content?> getById(String id) async => store[id];

  @override
  Future<void> update(Content content) async => store[content.id] = content;

  @override
  Future<List<Content>> getAll() async => store.values.toList();

  @override
  Future<List<Content>> getByStatus(String status) async => [];

  @override
  Future<void> save(Content content) async => store[content.id] = content;

  @override
  Future<void> delete(String id) async => store.remove(id);
}

class _FakePlaybackRepository implements PlaybackRepository {
  final Map<String, PlaybackState> store = {};
  bool failSave = false;

  @override
  Future<PlaybackState?> getByContentId(String contentId) async =>
      store[contentId];

  @override
  Future<void> save(PlaybackState state) async {
    if (failSave) throw StateError('save failed (test)');
    store[state.contentId] = state;
  }

  @override
  Future<void> resetAbRepeat(String contentId) async {}

  @override
  Future<void> resetAllAbRepeat() async {}

  @override
  Future<void> delete(String contentId) async => store.remove(contentId);
}
