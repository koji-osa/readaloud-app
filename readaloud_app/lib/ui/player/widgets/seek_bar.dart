import 'package:flutter/material.dart';

class SeekBar extends StatelessWidget {
  final double progress; // 0.0〜100.0
  final int totalChars;
  final double speed;
  final Function(double) onChanged;

  const SeekBar({
    super.key,
    required this.progress,
    required this.totalChars,
    required this.speed,
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
        ],
      ),
    );
  }

  String _formatTime(double progressPct) {
    if (totalChars <= 0 || speed <= 0) return '0:00';
    const baseCharsPerSecond = 5.0;
    final charsPerSecond = baseCharsPerSecond * speed;
    final totalSeconds = totalChars / charsPerSecond;
    final currentSeconds = (totalSeconds * progressPct / 100).round();
    final m = currentSeconds ~/ 60;
    final s = currentSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
