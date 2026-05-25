import 'package:flutter/material.dart';
import '../../../model/bookmark.dart';

class BookmarkPanel extends StatelessWidget {
  final List<Bookmark> bookmarks;
  final VoidCallback onAdd;
  final Function(String) onDelete;

  const BookmarkPanel({
    super.key,
    required this.bookmarks,
    required this.onAdd,
    required this.onDelete,
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'BOOKMARK',
                style: TextStyle(
                  fontSize: 10,
                  color: Color(0xFF8888AA),
                  letterSpacing: 1.2,
                ),
              ),
              GestureDetector(
                onTap: onAdd,
                child: const Text(
                  '+ 追加',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF9B6FE0),
                  ),
                ),
              ),
            ],
          ),
          if (bookmarks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'ブックマークはありません',
                style: TextStyle(fontSize: 12, color: Color(0xFF44445A)),
              ),
            )
          else
            ...bookmarks.map(
              (b) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Text('🔖', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        b.label ?? '位置 ${b.position}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFF0F0F8),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => onDelete(b.id),
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Color(0xFF44445A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
