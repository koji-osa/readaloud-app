import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_request.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';

// Slice 1: PersistentPlaybackResolver（旧StartPlaybackUseCase DB部分の逐語移設）
void main() {
  late _FakeContentRepository contentRepo;
  late _FakePlaybackRepository playbackRepo;
  late PersistentPlaybackResolver resolver;

  setUp(() {
    contentRepo = _FakeContentRepository();
    playbackRepo = _FakePlaybackRepository();
    resolver = PersistentPlaybackResolver(
        contentRepo: contentRepo, playbackRepo: playbackRepo);
  });

  test('PlaybackStateが存在する場合はその位置・声パラメータでrequestを作る', () async {
    contentRepo.store['c1'] =
        Content(id: 'c1', title: 'T', body: '0123456789', sourceType: 'text');
    playbackRepo.store['c1'] = PlaybackState(
        contentId: 'c1',
        position: 4,
        speed: 1.5,
        pitch: 1.2,
        volume: 0.8,
        voiceId: 'v1');

    final request = await resolver.resolveForStart('c1');

    expect(request.target, isA<PersistentTarget>());
    expect((request.target as PersistentTarget).contentId, 'c1');
    expect(request.text, '0123456789');
    expect(request.title, 'T');
    expect(request.startPosition, 4);
    expect(request.voice.speed, 1.5);
    expect(request.voice.pitch, 1.2);
    expect(request.voice.volume, 0.8);
    expect(request.voice.voiceId, 'v1');
    expect(request.source, isNull);
  });

  test('PlaybackStateが無い場合は既定値（位置0・速度1.0）でrequestを作り、行は作らない', () async {
    contentRepo.store['c1'] =
        Content(id: 'c1', title: 'T', body: 'body', sourceType: 'text');

    final request = await resolver.resolveForStart('c1');

    expect(request.startPosition, 0);
    expect(request.voice.speed, 1.0);
    expect(playbackRepo.saveCount, 0);
  });

  test('開始時にContentのstatusをin_progressへ更新する（取得→既定値→status更新の順）', () async {
    contentRepo.store['c1'] =
        Content(id: 'c1', title: 'T', body: 'body', sourceType: 'text');

    await resolver.resolveForStart('c1');

    expect(contentRepo.calls, ['getById:c1', 'update:c1:in_progress']);
    expect(playbackRepo.calls, ['getByContentId:c1']);
    expect(contentRepo.store['c1']!.status, 'in_progress');
  });

  test('Contentが存在しない場合は従来どおりthrowし、status更新は行わない', () async {
    await expectLater(resolver.resolveForStart('missing'), throwsException);
    expect(contentRepo.calls, ['getById:missing']);
  });

  test('startPositionは[0, text.length]にclampされる', () {
    final over = PlaybackRequest(
        target: const TransientTarget(), text: 'abc', startPosition: 99);
    final under = PlaybackRequest(
        target: const TransientTarget(), text: 'abc', startPosition: -5);
    expect(over.startPosition, 3);
    expect(under.startPosition, 0);
    expect(over.withStartPosition(1).startPosition, 1);
  });
}

class _FakeContentRepository implements ContentRepository {
  final Map<String, Content> store = {};
  final List<String> calls = [];

  @override
  Future<Content?> getById(String id) async {
    calls.add('getById:$id');
    return store[id];
  }

  @override
  Future<void> update(Content content) async {
    calls.add('update:${content.id}:${content.status}');
    store[content.id] = content;
  }

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
  final List<String> calls = [];
  int saveCount = 0;

  @override
  Future<PlaybackState?> getByContentId(String contentId) async {
    calls.add('getByContentId:$contentId');
    return store[contentId];
  }

  @override
  Future<void> save(PlaybackState state) async {
    saveCount++;
    store[state.contentId] = state;
  }

  @override
  Future<void> resetAbRepeat(String contentId) async {}

  @override
  Future<void> resetAllAbRepeat() async {}

  @override
  Future<void> delete(String contentId) async => store.remove(contentId);
}
