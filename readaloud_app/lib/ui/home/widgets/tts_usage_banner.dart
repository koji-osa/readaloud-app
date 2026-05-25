import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repository/impl/settings_repository_impl.dart';
import '../../../usecase/tts/check_tts_limit_usecase.dart';
import '../../../viewmodel/settings_viewmodel.dart';

final settingsViewModelProvider =
    StateNotifierProvider<SettingsViewModel, SettingsState>((ref) {
  final repo = SettingsRepositoryImpl();
  return SettingsViewModel(
    settingsRepo: repo,
    checkTtsLimit: CheckTtsLimitUseCase(settingsRepo: repo),
  );
});

class TtsUsageBanner extends ConsumerWidget {
  const TtsUsageBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsViewModelProvider);
    final usageRate = state.ttsUsageRate;
    final usedChars = int.tryParse(state.ttsUsedChars) ?? 0;
    final limitChars = int.tryParse(state.ttsMonthlyLimit) ?? 1000000;
    final remaining = limitChars - usedChars;

    final color = usageRate >= 0.95
        ? const Color(0xFFF87171)
        : usageRate >= 0.8
            ? const Color(0xFFFBBF24)
            : const Color(0xFF4ADE80);

    final statusText = usageRate >= 0.95
        ? '危険'
        : usageRate >= 0.8
            ? '警告'
            : '正常';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '今月のTTS使用量',
                style: TextStyle(fontSize: 11, color: Color(0xFF8888AA)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withOpacity(0.4)),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatNumber(usedChars),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF0F0F8),
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '/ ${_formatNumber(limitChars)} 文字',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8888AA),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: usageRate.clamp(0.0, 1.0),
              backgroundColor: const Color(0xFF323248),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '残り ${_formatNumber(remaining)}文字（${(usageRate * 100).toInt()}% 使用）',
            style: const TextStyle(fontSize: 11, color: Color(0xFF8888AA)),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return n.toString();
  }
}
