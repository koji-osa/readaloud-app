import 'package:flutter/material.dart';

class PlaybackControls extends StatelessWidget {
  final bool isPlaying;
  final double speed;
  final String? voiceId;
  final List<String> availableVoices;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onSeekToStart;
  final VoidCallback onSeekToEnd;
  final VoidCallback onRewind;
  final VoidCallback onFastForward;
  final Function(double) onSpeedChange;
  final Function(String) onVoiceChange;

  const PlaybackControls({
    super.key,
    required this.isPlaying,
    required this.speed,
    this.voiceId,
    this.availableVoices = const [],
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onSeekToStart,
    required this.onSeekToEnd,
    required this.onRewind,
    required this.onFastForward,
    required this.onSpeedChange,
    required this.onVoiceChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: Column(
        children: [
          // 速度ボタン
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [0.75, 1.0, 1.5, 1.75, 2.0, 2.5].map((s) {
              final isSelected = (speed - s).abs() < 0.01;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => onSpeedChange(s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF7C5CBF)
                          : const Color(0xFF323248),
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF7C5CBF)
                            : const Color(0xFF3A3A55),
                      ),
                    ),
                    child: Text(
                      '${s}x',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF8888AA),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // 声の種類ボタン（高さ固定でガタつき防止）
          SizedBox(
            height: 32,
            child: availableVoices.isNotEmpty
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: availableVoices.take(4).map((v) {
                        final isSelected = voiceId == v;
                        final label = v.length > 12
                            ? v.substring(v.length - 12)
                            : v;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => onVoiceChange(v),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFF3D2B6E)
                                    : const Color(0xFF323248),
                                borderRadius: BorderRadius.circular(17),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFF9B6FE0)
                                      : const Color(0xFF3A3A55),
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isSelected
                                      ? const Color(0xFF9B6FE0)
                                      : const Color(0xFF8888AA),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 8),
          // メインコントロール
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ControlButton(
                icon: Icons.skip_previous,
                onTap: onSeekToStart,
                size: 28,
              ),
              _ControlButton(
                icon: Icons.replay_10,
                onTap: onRewind,
                size: 28,
              ),
              GestureDetector(
                onTap: isPlaying ? onPause : onPlay,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF7C5CBF),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0xFF7C5CBF).withValues(alpha: 0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
              _ControlButton(
                icon: Icons.forward_10,
                onTap: onFastForward,
                size: 28,
              ),
              _ControlButton(
                icon: Icons.skip_next,
                onTap: onSeekToEnd,
                size: 28,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 停止ボタン・A-Bリピートボタン
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ControlButton(
                icon: Icons.stop,
                onTap: onStop,
                size: 22,
                label: '停止',
              ),
              const SizedBox(width: 24),
              _ControlButton(
                icon: Icons.repeat,
                onTap: () {},
                size: 22,
                label: 'A-B',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final String? label;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    required this.size,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: label != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: const Color(0xFF8888AA), size: size),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label!,
                    style: const TextStyle(
                      color: Color(0xFF8888AA),
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          : Icon(icon, color: const Color(0xFF8888AA), size: size),
    );
  }
}
