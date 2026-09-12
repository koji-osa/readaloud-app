import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/model/normal_player_session.dart';
import 'package:readaloud_app/model/setting.dart';
import 'package:readaloud_app/repository/settings_repository.dart';
import 'package:readaloud_app/usecase/tts/check_tts_limit_usecase.dart';
import 'package:readaloud_app/usecase/tts/count_tts_usage_usecase.dart';

// CountTtsUsageUseCase の owner-aware / concurrency-safe contract test
// （Canonical Design v0.4.1 D2/D13, RA-NPD-P04 CB-3/CI-1）。
void main() {
  late _FakeSettingsRepository settingsRepo;
  late CountTtsUsageUseCase usage;

  setUp(() {
    settingsRepo = _FakeSettingsRepository();
    usage = CountTtsUsageUseCase(
      settingsRepo: settingsRepo,
      checkLimit: CheckTtsLimitUseCase(settingsRepo: settingsRepo),
    );
  });

  group('owner-aware stopCounting（D13）', () {
    test('owner不一致のstopCountingは完全no-op（他ownerのtimerも触らない）', () async {
      final ownerA = PlaybackOwnerKey.normalPlayer('a');
      final ownerB = PlaybackOwnerKey.normalPlayer('b');
      usage.startCounting(owner: ownerA, totalChars: 1000, startPosition: 0);
      usage.updatePosition(50);

      // Bが自分のownerでstopしようとしてもAのtimer/positionには影響しない。
      await usage.stopCounting(ownerB);

      expect(settingsRepo.setCalls, isEmpty, reason: '別ownerのstopは永続化を一切行わない');

      // Aは引き続き有効なままflushできる。
      await usage.stopCounting(ownerA);
      expect(settingsRepo.get(SettingKeys.ttsUsedChars), completion('50'));
    });

    test('同一contentIdでも別ownerなら、Aの遅延stopがBのcounterを破壊しない（CB-3 / T41）',
        () async {
      final ownerA = PlaybackOwnerKey.normalPlayer('session-a');
      final ownerB = PlaybackOwnerKey.normalPlayer('session-b');

      usage.startCounting(owner: ownerA, totalChars: 1000, startPosition: 0);
      usage.updatePosition(300); // Aが300まで進んだ

      // Bが同じcontentを新しいsessionとして開始（INV-11: 別session）。
      usage.startCounting(owner: ownerB, totalChars: 1000, startPosition: 0);
      usage.updatePosition(10); // Bはまだ10しか進んでいない

      // Aの遅延stopが今ごろ届く（stale continuation）。
      await usage.stopCounting(ownerA);

      expect(settingsRepo.setCalls, isEmpty,
          reason: 'owner不一致のためAの遅延stopはBのcounterへ何も書き込まない');

      // Bのstopは正しくB自身の進捗(10)だけを計上する。
      await usage.stopCounting(ownerB);
      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '10',
          reason: 'Aの停止がBの_lastPosition/_currentPositionを書き潰していない');
    });
  });

  group('queued write failure handling（CI-1）', () {
    test('永続書込みの失敗は呼び出し元へ観測可能で、chars は次回flushで再試行される', () async {
      settingsRepo.failNextSet = 1;
      final owner = PlaybackOwnerKey.normalPlayer('s1');
      usage.startCounting(owner: owner, totalChars: 1000, startPosition: 0);
      usage.updatePosition(40);

      await expectLater(usage.stopCounting(owner), throwsException,
          reason: '失敗を黙って成功扱いにしない（呼び出し元がエラーを観測できる）');
      expect(settingsRepo.get(SettingKeys.ttsUsedChars), completion(isNull));

      // 直列化tailは生きたまま。次のセッションのflushで先の40charsも再試行される。
      usage.startCounting(owner: owner, totalChars: 1000, startPosition: 40);
      usage.updatePosition(40); // 変化なし。ただし_pendingUnflushedの40が残っている
      await usage.stopCounting(owner);

      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '40',
          reason: '失敗したchars(40)が次回flushで正しく再計上される（黙って消えない）');
    });

    test('timer起点の失敗はunhandled async errorにならず、次回で再試行される', () async {
      settingsRepo.failNextSet = 1;
      final owner = PlaybackOwnerKey.normalPlayer('s1');
      final errors = <Object>[];
      await runZonedGuarded(() async {
        usage.startCounting(owner: owner, totalChars: 1000, startPosition: 0);
        usage.updatePosition(20);
        // stopCountingを経由せず、timer相当の失敗パスだけを検証する代わりに
        // 同じ直列化tailを共有するstopCountingで失敗させ、以後のflushが
        // 生きていることを確認する（timer自体はfake不可のため、内部tailの
        // 生存性を別経路から検証する）。
        await usage.stopCounting(owner).catchError((_) {});
        usage.startCounting(owner: owner, totalChars: 1000, startPosition: 20);
        usage.updatePosition(25);
        await usage.stopCounting(owner);
      }, (error, stack) {
        errors.add(error);
      });

      expect(errors, isEmpty,
          reason: '内部tail自体はcatchされ、Zoneへ漏れるunhandled errorを作らない');
      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '25',
          reason: '1回目の失敗分(20)は_pendingUnflushedへ戻り、2回目のflush(5)と合算されて計上される');
    });
  });

  group('timer/stop interleave（既存CB2-a/bの回帰防止）', () {
    test('stopCountingは同期claimのため、同じownerからの2回目呼び出しは二重加算しない', () async {
      final owner = PlaybackOwnerKey.normalPlayer('s1');
      usage.startCounting(owner: owner, totalChars: 1000, startPosition: 0);
      usage.updatePosition(60);

      await usage.stopCounting(owner);
      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '60');

      // 同じownerで再度stopCountingを呼んでも(position不変のため)何も加算しない。
      await usage.stopCounting(owner);
      expect(await settingsRepo.get(SettingKeys.ttsUsedChars), '60');
    });
  });
}

class _FakeSettingsRepository implements SettingsRepository {
  final Map<String, String> _store = {};
  final List<String> setCalls = [];
  int failNextSet = 0;

  @override
  Future<String?> get(String key) async => _store[key];

  @override
  Future<void> set(String key, String value) async {
    if (failNextSet > 0) {
      failNextSet--;
      throw Exception('settings write failed (test)');
    }
    setCalls.add(key);
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, String>> getAll() async => Map.of(_store);
}
