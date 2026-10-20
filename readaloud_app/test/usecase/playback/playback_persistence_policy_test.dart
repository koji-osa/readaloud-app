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
      // RA-PROG-IMPL-A-01: 停止時の進捗率は現在の本文長が分母（本文1000文字）。
      final content = Content(
          id: 'c1', title: 't', body: 'x' * 1000, sourceType: 'text');
      contentRepo.store['c1'] = content;
      policy = PersistentPersistencePolicy(
        target: PersistentTarget.of(content),
        playbackRepo: playbackRepo,
        savePlaybackState: SavePlaybackStateUseCase(
            playbackRepo: playbackRepo, contentRepo: contentRepo),
      );
    });

    // T1（旧: 「progressPctが0の既存状態では従来式でclampされcompletedになる」）
    test('T1: 既存0%・本文1000文字・停止位置70 → 7%、completedにならない', () async {
      final result = await policy.persistStopPosition(position: 70);

      expect(result.succeeded, isTrue);
      expect(playbackRepo.store['c1']!.position, 70);
      expect(playbackRepo.store['c1']!.progressPct, closeTo(7.0, 1e-9));
      expect(contentRepo.store['c1']!.status, 'unread',
          reason: '誤ってcompletedへ昇格させない');
    });

    // T2（旧: 「旧StopPlaybackUseCase step3と同じ値を保存する」25%→25%の凍結）
    test('T2: 既存25%・停止位置400 → 40%（旧進捗率が凍結しない）', () async {
      playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 250, progressPct: 25.0);

      final result = await policy.persistStopPosition(position: 400);

      expect(result.succeeded, isTrue);
      expect(playbackRepo.store['c1']!.position, 400);
      expect(playbackRepo.store['c1']!.progressPct, closeTo(40.0, 1e-9));
    });

    test('T3: 既存100%（誤データ）・停止位置300 → 30%（status降格はPR-B対象外）', () async {
      playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 999, progressPct: 100.0);
      contentRepo.store['c1'] =
          contentRepo.store['c1']!.copyWith(status: 'completed');

      await policy.persistStopPosition(position: 300);

      expect(playbackRepo.store['c1']!.progressPct, closeTo(30.0, 1e-9));
      expect(contentRepo.store['c1']!.status, 'completed',
          reason: 'PR-Aではstatusを降格しない（既存挙動を維持）');
    });

    test('T4: 末尾（位置=本文長）で停止 → 100%、現行規則でcompleted', () async {
      await policy.persistStopPosition(position: 1000);

      expect(playbackRepo.store['c1']!.progressPct, 100.0);
      expect(contentRepo.store['c1']!.status, 'completed');
    });

    test('T5a: 空本文 → 既存pctを維持、ゼロ除算・新規completedなし、position=0', () async {
      contentRepo.store['c1'] = contentRepo.store['c1']!.copyWith(body: '');
      playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 0, progressPct: 12.5);

      final result = await policy.persistStopPosition(position: 7);

      expect(result.succeeded, isTrue);
      expect(playbackRepo.store['c1']!.progressPct, 12.5);
      expect(playbackRepo.store['c1']!.position, 0);
      expect(contentRepo.store['c1']!.status, 'unread');
    });

    test('T5b: Content欠損 → 既存pctを維持、新規completedなし、positionは0以上へ', () async {
      contentRepo.store.remove('c1');
      playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 5, progressPct: 30.0);

      final result = await policy.persistStopPosition(position: 7);

      expect(result.succeeded, isTrue);
      expect(playbackRepo.store['c1']!.progressPct, 30.0);
      expect(playbackRepo.store['c1']!.position, 7);
      expect(contentRepo.store.containsKey('c1'), isFalse);
    });

    test('T5c: 既存100%・空本文でも status を新たに変更しない', () async {
      contentRepo.store['c1'] =
          contentRepo.store['c1']!.copyWith(body: '', status: 'in_progress');
      playbackRepo.store['c1'] =
          PlaybackState(contentId: 'c1', position: 0, progressPct: 100.0);

      await policy.persistStopPosition(position: 0);

      expect(contentRepo.store['c1']!.status, 'in_progress');
    });

    test('T6a: 負の停止位置 → positionは0、pctは0〜100', () async {
      await policy.persistStopPosition(position: -50);

      expect(playbackRepo.store['c1']!.position, 0);
      expect(playbackRepo.store['c1']!.progressPct, 0.0);
    });

    test('T6b: 本文長超過の停止位置 → positionは本文長へclamp、pctは100', () async {
      await policy.persistStopPosition(position: 5000);

      expect(playbackRepo.store['c1']!.position, 1000);
      expect(playbackRepo.store['c1']!.progressPct, 100.0);
    });

    test('T6c: 有効範囲内のpositionは変更せず保存する', () async {
      for (final p in [0, 1, 333, 999, 1000]) {
        await policy.persistStopPosition(position: p);
        expect(playbackRepo.store['c1']!.position, p);
      }
    });

    test('T7: 保存失敗は例外にならず構造化結果で返る（B-01独立性）', () async {
      playbackRepo.failSave = true;
      final result = await policy.persistStopPosition(position: 3);
      expect(result.succeeded, isFalse);
      expect(result.errorType, isNotNull);
    });

    test('T7b: Content読込失敗も例外にならず構造化結果で返る', () async {
      contentRepo.failGet = true;
      final result = await policy.persistStopPosition(position: 3);
      expect(result.succeeded, isFalse);
      expect(result.errorType, isNotNull);
    });

    test('T7c: PlaybackState読込失敗も例外にならず構造化結果で返る', () async {
      playbackRepo.failGet = true;
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
  bool failGet = false;

  @override
  Future<Content?> getById(String id) async {
    if (failGet) throw StateError('getById failed (test)');
    return store[id];
  }

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
  bool failGet = false;

  @override
  Future<PlaybackState?> getByContentId(String contentId) async {
    if (failGet) throw StateError('getByContentId failed (test)');
    return store[contentId];
  }

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
