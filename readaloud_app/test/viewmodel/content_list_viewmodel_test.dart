import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/content.dart';
import 'package:readaloud_app/model/playback_state.dart';
import 'package:readaloud_app/repository/content_repository.dart';
import 'package:readaloud_app/repository/playback_repository.dart';
import 'package:readaloud_app/usecase/content/delete_content_usecase.dart';
import 'package:readaloud_app/usecase/content/get_all_contents_usecase.dart';
import 'package:readaloud_app/usecase/content/update_content_usecase.dart';
import 'package:readaloud_app/util/debug_logger.dart';
import 'package:readaloud_app/viewmodel/content_list_viewmodel.dart';

/// No.152: Home 初期表示の一覧不整合。
/// T1 初回 content failure / T2 playback enrichment failure / T3 stale request
/// overwrite / T4 真の empty / T5 通常 load を固定する。
Content _content(String id, {String status = 'unread'}) => Content(
      id: id,
      title: 't-$id',
      body: 'b-$id',
      sourceType: 'manual',
      status: status,
    );

class _FakeContentRepository implements ContentRepository {
  Future<List<Content>> Function() onGetAll = () async => [];
  Future<List<Content>> Function(String status) onGetByStatus =
      (_) async => [];

  @override
  Future<List<Content>> getAll() => onGetAll();

  @override
  Future<List<Content>> getByStatus(String status) => onGetByStatus(status);

  Future<Content?> Function(String id) onGetById = (_) async => null;

  @override
  Future<Content?> getById(String id) => onGetById(id);
  @override
  Future<void> save(Content content) async {}
  @override
  Future<void> update(Content content) async {}
  @override
  Future<void> delete(String id) async {}
}

class _FakePlaybackRepository implements PlaybackRepository {
  Future<PlaybackState?> Function(String contentId) onGet = (_) async => null;

  @override
  Future<PlaybackState?> getByContentId(String contentId) => onGet(contentId);

  @override
  Future<void> save(PlaybackState state) async {}
  @override
  Future<void> resetAbRepeat(String contentId) async {}
  @override
  Future<void> resetAllAbRepeat() async {}
  @override
  Future<void> delete(String contentId) async {}
}

void main() {
  late _FakeContentRepository contentRepo;
  late _FakePlaybackRepository playbackRepo;
  late List<ContentListViewModel> created;

  ContentListViewModel build() {
    final repo = contentRepo;
    final vm = ContentListViewModel(
      getAllContents: GetAllContentsUseCase(repo),
      deleteContent: DeleteContentUseCase(repo),
      updateContent: UpdateContentUseCase(repo),
      playbackRepo: playbackRepo,
    );
    created.add(vm);
    return vm;
  }

  setUp(() {
    contentRepo = _FakeContentRepository();
    playbackRepo = _FakePlaybackRepository();
    created = [];
    DebugLogger.testSink = [];
  });

  tearDown(() {
    for (final vm in created) {
      if (vm.mounted) vm.dispose();
    }
    DebugLogger.testSink = null;
  });

  group('ContentListViewModel (No.152)', () {
    test('T1 初回 content query failure は error として残り、empty と区別できる', () async {
      contentRepo.onGetAll = () async => throw StateError('db open failed');
      final vm = build();
      await pumpEventQueue();

      expect(vm.state.contents, isEmpty);
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNotNull);
      // 内部の例外文言(DB/path 等)をユーザー表示へ出さない。
      expect(vm.state.errorMessage, isNot(contains('db open failed')));
      expect(vm.state.errorMessage, isNot(contains('StateError')));
    });

    test('T2c playback lookup が pending のままでも一覧表示と isLoading=false が成立する',
        () async {
      final playback = Completer<PlaybackState?>();
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet = (id) => id == 'a'
          ? playback.future
          : Future.value(PlaybackState(contentId: id, progressPct: 0.5));
      final vm = build();
      await pumpEventQueue();

      // playback Completer 完了前。
      expect(vm.state.contents.map((c) => c.id), ['a', 'b']);
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNull);
      expect(vm.state.progressMap, isEmpty);

      playback.complete(PlaybackState(contentId: 'a', progressPct: 0.25));
      await pumpEventQueue();
      expect(vm.state.progressMap, {'a': 0.25, 'b': 0.5});
      expect(vm.state.contents.map((c) => c.id), ['a', 'b']);
      expect(vm.state.isLoading, isFalse);
    });

    test('T2d enrichment 中に新 request が来たら古い progress を commit しない', () async {
      final oldPlayback = Completer<PlaybackState?>();
      var call = 0;
      contentRepo.onGetAll = () async => [_content('a')];
      playbackRepo.onGet = (id) {
        call++;
        return call == 1
            ? oldPlayback.future
            : Future.value(PlaybackState(contentId: id, progressPct: 0.9));
      };
      final vm = build();
      await pumpEventQueue();
      await vm.loadContents(); // request 2 が最新

      oldPlayback.complete(PlaybackState(contentId: 'a', progressPct: 0.1));
      await pumpEventQueue();
      expect(vm.state.progressMap, {'a': 0.9});
    });

    test('T2e enrichment 中の dispose 後に完了しても例外にならない', () async {
      final playback = Completer<PlaybackState?>();
      contentRepo.onGetAll = () async => [_content('a')];
      playbackRepo.onGet = (_) => playback.future;
      final vm = build();
      await pumpEventQueue();
      vm.dispose();

      playback.complete(PlaybackState(contentId: 'a', progressPct: 0.3));
      await pumpEventQueue();
    });

    test('T2f playback 例外は privacy-safe な errorType event で観測できる', () async {
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet = (_) async => throw StateError('secret-detail');
      build();
      await pumpEventQueue();

      final failures = DebugLogger.testSink!
          .where((l) => l.startsWith('event=progress_enrichment_failure'))
          .toList();
      expect(failures, hasLength(2));
      expect(failures.first, contains('errorType=StateError'));
      expect(failures.first, contains('stage=playback_lookup'));
      expect(failures.first, contains('requestId='));
      for (final l in DebugLogger.testSink!) {
        expect(l.contains('secret-detail'), isFalse);
        expect(l.contains('t-a') || l.contains('b-a'), isFalse);
      }
    });

    test('T2 playback enrichment failure は取得済みの一覧を消さない', () async {
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet = (id) async {
        if (id == 'a') throw StateError('playback row corrupt');
        return PlaybackState(contentId: id, progressPct: 0.5);
      };
      final vm = build();
      await pumpEventQueue();

      expect(vm.state.contents.map((c) => c.id), ['a', 'b']);
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNull);
      expect(vm.state.progressMap, {'b': 0.5});
    });

    test('T2b enrichment 全件 failure でも一覧は commit される', () async {
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet = (_) async => throw StateError('playback db down');
      final vm = build();
      await pumpEventQueue();

      expect(vm.state.contents.map((c) => c.id), ['a', 'b']);
      expect(vm.state.progressMap, isEmpty);
      expect(vm.state.errorMessage, isNull);
    });

    test('T3 古い request が新しい filter の結果を上書きしない', () async {
      final allCompleter = Completer<List<Content>>();
      final unreadCompleter = Completer<List<Content>>();
      contentRepo.onGetAll = () => allCompleter.future;
      contentRepo.onGetByStatus = (_) => unreadCompleter.future;

      final vm = build(); // request 1: all (遅延)
      final change = vm.changeFilter('unread'); // request 2: unread

      unreadCompleter.complete([_content('u1')]);
      await change;
      expect(vm.state.contents.map((c) => c.id), ['u1']);

      // 古い request(all) が後から完了しても無視される。
      allCompleter.complete([_content('x1'), _content('x2')]);
      await pumpEventQueue();

      expect(vm.state.selectedFilter, 'unread');
      expect(vm.state.contents.map((c) => c.id), ['u1']);
      expect(vm.state.isLoading, isFalse);
    });

    test('T3b 古い request の failure が新しい結果へ error を書き戻さない', () async {
      final allCompleter = Completer<List<Content>>();
      contentRepo.onGetAll = () => allCompleter.future;
      contentRepo.onGetByStatus = (_) async => [_content('u1')];

      final vm = build();
      await vm.changeFilter('unread');
      allCompleter.completeError(StateError('late failure'));
      await pumpEventQueue();

      expect(vm.state.contents.map((c) => c.id), ['u1']);
      expect(vm.state.errorMessage, isNull);
      expect(vm.state.isLoading, isFalse);
    });

    test('T3c 古い request が loading を解除して新 request の spinner を消さない', () async {
      final allCompleter = Completer<List<Content>>();
      final unreadCompleter = Completer<List<Content>>();
      contentRepo.onGetAll = () => allCompleter.future;
      contentRepo.onGetByStatus = (_) => unreadCompleter.future;

      final vm = build();
      final change = vm.changeFilter('unread');
      allCompleter.complete([_content('x1')]);
      await pumpEventQueue();

      expect(vm.state.isLoading, isTrue);
      expect(vm.state.contents, isEmpty);

      unreadCompleter.complete([_content('u1')]);
      await change;
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.contents.map((c) => c.id), ['u1']);
    });

    test('T4 正常な空 list は error なしの真の empty', () async {
      contentRepo.onGetAll = () async => [];
      final vm = build();
      await pumpEventQueue();

      expect(vm.state.contents, isEmpty);
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNull);
    });

    test('T5 初回 load 成功で保存済み Content が state に入り progress も付く', () async {
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet = (id) async =>
          id == 'a' ? PlaybackState(contentId: id, progressPct: 0.25) : null;
      final vm = build();
      expect(vm.state.isLoading, isTrue);
      await pumpEventQueue();

      expect(vm.state.contents.map((c) => c.id), ['a', 'b']);
      expect(vm.state.progressMap, {'a': 0.25});
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNull);
    });

    test('失敗後の再試行(loadContents)で復帰できる', () async {
      var fail = true;
      contentRepo.onGetAll =
          () async => fail ? throw StateError('boom') : [_content('a')];
      final vm = build();
      await pumpEventQueue();
      expect(vm.state.errorMessage, isNotNull);

      fail = false;
      await vm.loadContents();
      expect(vm.state.errorMessage, isNull);
      expect(vm.state.contents.map((c) => c.id), ['a']);
    });

    test('load 中の dispose 後に完了しても例外にならない', () async {
      final completer = Completer<List<Content>>();
      contentRepo.onGetAll = () => completer.future;
      final vm = build();
      vm.dispose();

      completer.complete([_content('a')]);
      await pumpEventQueue(); // dispose 後の state 書き込みで throw しない
    });

    test('完了 commit は 1 回で、中間の空 state を commit しない', () async {
      final completer = Completer<List<Content>>();
      contentRepo.onGetAll = () => completer.future;
      final committed = <ContentListState>[];
      final vm = build();
      vm.addListener(committed.add, fireImmediately: false);

      completer.complete([_content('a')]);
      await pumpEventQueue();

      expect(committed, hasLength(1));
      expect(committed.single.isLoading, isFalse);
      expect(committed.single.contents, hasLength(1));
    });

    test('T6a filter 変更後の query 失敗で旧 filter の一覧/progress を残さない', () async {
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet =
          (id) async => PlaybackState(contentId: id, progressPct: 0.4);
      contentRepo.onGetByStatus = (_) async => throw StateError('unread down');
      final vm = build();
      await pumpEventQueue();
      expect(vm.state.progressMap, isNotEmpty);

      await vm.changeFilter('unread');

      expect(vm.state.selectedFilter, 'unread');
      expect(vm.state.contents, isEmpty);
      expect(vm.state.progressMap, isEmpty);
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNotNull);
    });

    test('T6b same-filter refresh の query 失敗は既存の一覧/progress を保持する', () async {
      var fail = false;
      contentRepo.onGetAll = () async =>
          fail ? throw StateError('refresh down') : [_content('a')];
      playbackRepo.onGet =
          (id) async => PlaybackState(contentId: id, progressPct: 0.4);
      final vm = build();
      await pumpEventQueue();

      fail = true;
      await vm.changeFilter('all');

      expect(vm.state.selectedFilter, 'all');
      expect(vm.state.contents.map((c) => c.id), ['a']);
      expect(vm.state.progressMap, {'a': 0.4});
      expect(vm.state.isLoading, isFalse);
      expect(vm.state.errorMessage, isNotNull);
    });

    test('T7 enrichment 失敗でも前回取得済みの progress を 0 へ後退させない', () async {
      var failLookup = false;
      contentRepo.onGetAll = () async => [_content('a'), _content('b')];
      playbackRepo.onGet = (id) async {
        if (failLookup && id == 'a') throw StateError('transient');
        return PlaybackState(contentId: id, progressPct: id == 'a' ? 0.4 : 0.7);
      };
      final vm = build();
      await pumpEventQueue();
      expect(vm.state.progressMap, {'a': 0.4, 'b': 0.7});
      DebugLogger.testSink!.clear();

      failLookup = true;
      await vm.loadContents();

      expect(vm.state.contents.map((c) => c.id), ['a', 'b']);
      expect(vm.state.progressMap, {'a': 0.4, 'b': 0.7});
      final failures = DebugLogger.testSink!
          .where((l) => l.startsWith('event=progress_enrichment_failure'));
      expect(failures, hasLength(1));
      expect(failures.single, contains('errorType=StateError'));
      expect(failures.single.contains('transient'), isFalse);
    });

    test('T7b lookup 成功時は新しい progress で更新する', () async {
      var value = 0.4;
      contentRepo.onGetAll = () async => [_content('a')];
      playbackRepo.onGet =
          (id) async => PlaybackState(contentId: id, progressPct: value);
      final vm = build();
      await pumpEventQueue();

      value = 0.8;
      await vm.loadContents();
      expect(vm.state.progressMap, {'a': 0.8});
    });

    test('T8 delete/updateTitle の user message に内部例外を含めない', () async {
      contentRepo.onGetAll = () async => [_content('a')];
      contentRepo.onGetById = (_) async => throw StateError('secret-detail');
      final vm = build();
      await pumpEventQueue();

      await vm.deleteContent('a');
      final deleteMsg = vm.state.errorMessage;
      expect(deleteMsg, isNotNull);
      expect(deleteMsg, isNot(contains('secret-detail')));
      expect(deleteMsg, isNot(contains('StateError')));

      await vm.updateTitle('a', 'new');
      final updateMsg = vm.state.errorMessage;
      expect(updateMsg, isNotNull);
      expect(updateMsg, isNot(contains('secret-detail')));
      expect(updateMsg, isNot(contains('StateError')));
      for (final l in DebugLogger.testSink!) {
        expect(l.contains('secret-detail'), isFalse);
      }
    });

    test('Observability: 本文/タイトルを含まない構造化 event を出す', () async {
      contentRepo.onGetAll = () async => [_content('a')];
      build();
      await pumpEventQueue();

      final lines = DebugLogger.testSink!;
      expect(lines.any((l) => l.startsWith('event=content_list_load_start')),
          isTrue);
      expect(lines.any((l) => l.startsWith('event=content_query_done')),
          isTrue);
      expect(lines.any((l) => l.startsWith('event=content_list_load_commit')),
          isTrue);
      expect(lines.any((l) => l.contains('t-a') || l.contains('b-a')), isFalse);
    });
  });
}
