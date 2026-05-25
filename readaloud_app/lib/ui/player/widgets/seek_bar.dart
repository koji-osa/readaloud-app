import 'package:flutter/material.dart';

class SeekBar extends StatelessWidget {
  final double progress; // 0.0〜100.0
  final Function(double) onChanged;

  const SeekBar({
    super.key,
    required this.progress,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF9B6FE0),
              inactiveTrackColor: const Color(0xFF323248),
              thumbColor: const Color(0xFF9B6FE0),
              overlayColor: const Color(0x299B6FE0),
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: progress.clamp(0.0, 100.0),
              min: 0,
              max: 100,
              onChanged: onChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatTime(progress),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8888AA),
                  ),
                ),
                Text(
                  _formatTime(100),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8888AA),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(double progress) {
    // 仮の時間表示（実際はコンテンツの文字数と速度から計算）
    final seconds = (progress * 1.2).round();
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
