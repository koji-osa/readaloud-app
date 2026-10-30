// W2-R-03 / Human Decision A: replay of a finished (or out-of-range) position
// must restart from 0. Resolver unit tests over in-memory fakes.
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/usecase/playback/persistent_playback_resolver.dart';

import '../../integration_wt02/it_harness.dart';

void main() {
  late ItContentRepository contentRepo;
  late ItPlaybackRepository playbackRepo;
  late PersistentPlaybackResolver resolver;

  setUp(() {
    contentRepo = ItContentRepository();
    playbackRepo = ItPlaybackRepository();
    resolver = PersistentPlaybackResolver(
        contentRepo: contentRepo, playbackRepo: playbackRepo);
  });

  void seed({required int len, required int? pos, String status = 'unread'}) {
    contentRepo.store['c1'] = Content(
        id: 'c1',
        title: 't',
        body: 'x' * len,
        sourceType: 'text',
        status: status);
    if (pos != null) {
      playbackRepo.store['c1'] = PlaybackState(contentId: 'c1', position: pos);
    }
  }

  test('AC-W2-01/02 position == body length -> startPosition 0', () async {
    seed(len: 1000, pos: 1000, status: 'completed');
    final req = await resolver.resolveForStart('c1');
    expect(req.startPosition, 0);
    expect(req.text.length, 1000);
  });

  test('AC-W2-02 position > body length (legacy data) -> 0', () async {
    seed(len: 1000, pos: 1500);
    expect((await resolver.resolveForStart('c1')).startPosition, 0);
  });

  test('AC-W2-02 negative position (-5) -> 0', () async {
    seed(len: 1000, pos: -5);
    expect((await resolver.resolveForStart('c1')).startPosition, 0);
  });

  test('AC-W2-03 mid position p keeps p', () async {
    seed(len: 1000, pos: 300);
    expect((await resolver.resolveForStart('c1')).startPosition, 300);
  });

  test('AC-W2-03 last valid index (len-1) keeps len-1', () async {
    seed(len: 1000, pos: 999);
    expect((await resolver.resolveForStart('c1')).startPosition, 999);
  });

  test('AC-W2-03 position 0 -> 0, and no saved state -> 0', () async {
    seed(len: 1000, pos: 0);
    expect((await resolver.resolveForStart('c1')).startPosition, 0);
    playbackRepo.store.clear();
    expect((await resolver.resolveForStart('c1')).startPosition, 0);
  });

  test('AC-W2-05 empty body -> 0 (no throw)', () async {
    seed(len: 0, pos: 0);
    final req = await resolver.resolveForStart('c1');
    expect(req.startPosition, 0);
    expect(req.text, '');
    seed(len: 0, pos: 7);
    expect((await resolver.resolveForStart('c1')).startPosition, 0);
  });

  test('AC-W2-05 missing content throws and writes nothing', () async {
    await expectLater(resolver.resolveForStart('nope'), throwsException);
    expect(playbackRepo.saveCalls, 0);
    expect(contentRepo.store, isEmpty);
  });

  test('status becomes in_progress; playback_state is not written', () async {
    seed(len: 1000, pos: 1000, status: 'completed');
    await resolver.resolveForStart('c1');
    expect(contentRepo.store['c1']!.status, 'in_progress');
    expect(playbackRepo.saveCalls, 0, reason: 'D-CONT-02: start does not save');
    expect(playbackRepo.store['c1']!.position, 1000);
  });
}
