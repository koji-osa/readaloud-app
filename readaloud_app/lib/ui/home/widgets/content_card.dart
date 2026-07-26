import 'package:flutter/material.dart';
import '../../../model/content.dart';

class ContentCard extends StatelessWidget {
  final Content content;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Function(String) onEditTitle;
  final double progressPct;
  final bool isSelectMode;
  final bool isSelected;
  final VoidCallback? onLongPress;

  const ContentCard({
    super.key,
    required this.content,
    required this.onTap,
    required this.onDelete,
    required this.onEditTitle,
    this.progressPct = 0.0,
    this.isSelectMode = false,
    this.isSelected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF3D2B6E) : const Color(0xFF2A2A3E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? const Color(0xFF9B6FE0) : const Color(0xFF3A3A55),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isSelectMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: isSelected ? const Color(0xFF9B6FE0) : const Color(0xFF44445A),
                      size: 22,
                    ),
                  ),
                Expanded(
                  child: GestureDetector(
                    onTap: isSelectMode ? null : () => onEditTitle(content.title),
                    child: Text(
                      content.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: isSelectMode ? const Color(0xFF8888AA) : const Color(0xFFF0F0F8),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (!isSelectMode)
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Color(0xFF44445A), size: 20),
                    onPressed: onDelete,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // プログレスバー
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _progressValue,
                backgroundColor: const Color(0xFF323248),
                valueColor: AlwaysStoppedAnimation<Color>(_progressColor),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_progressPercent.toInt()}% 完了',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8888AA),
                  ),
                ),
                Row(
                  children: [
                    _SourceBadge(sourceType: content.sourceType),
                    const SizedBox(width: 8),
                    Text(
                      _formatDate(content.createdAt),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8888AA),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double get _progressValue {
    if (content.status == 'completed') return 1.0;
    if (content.status == 'unread') return 0.0;
    return progressPct / 100; // playback_state.progressPctから取得
  }

  double get _progressPercent {
    if (content.status == 'completed') return 100.0;
    if (content.status == 'unread') return 0.0;
    return progressPct;
  }

  Color get _progressColor {
    if (content.status == 'completed') return const Color(0xFF4ADE80);
    return const Color(0xFF9B6FE0);
  }

  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.month}/${date.day}';
  }
}

class _SourceBadge extends StatelessWidget {
  final String sourceType;

  const _SourceBadge({required this.sourceType});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (sourceType) {
      'url' => ('URL', const Color(0xFF60A5FA)),
      'file' => ('PDF', const Color(0xFFFBBF24)),
      'share' => ('共有', const Color(0xFF4ADE80)),
      'obsidian' => ('Obsidian', const Color(0xFF7C3AED)),
      _ => ('テキスト', const Color(0xFF9B6FE0)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}
