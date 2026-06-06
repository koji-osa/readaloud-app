import 'package:flutter/material.dart';
import '../../../model/bookmark.dart';

class BookmarkPanel extends StatefulWidget {
  final List<Bookmark> bookmarks;
  final VoidCallback onAdd;
  final Function(String) onDelete;
  final Function(int) onJump;
  final VoidCallback? onAnalyze; // REQ-011

  const BookmarkPanel({
    super.key,
    required this.bookmarks,
    required this.onAdd,
    required this.onDelete,
    required this.onJump,
    this.onAnalyze,
  });

  @override
  State<BookmarkPanel> createState() => _BookmarkPanelState();
}

class _BookmarkPanelState extends State<BookmarkPanel> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー行
          Row(
            children: [
              const Text('🔖', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              const Text(
                'BOOKMARK',
                style: TextStyle(
                  fontSize: 10,
                  color: Color(0xFF8888AA),
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '(\${widget.bookmarks.length})',
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF8888AA),
                ),
              ),
              const Spacer(),
              // 開閉ボタン
              GestureDetector(
                onTap: () => setState(() => _isExpanded = !_isExpanded),
                child: Icon(
                  _isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: const Color(0xFF8888AA),
                ),
              ),
              const SizedBox(width: 4),
              // 自動分析ボタン（REQ-011）
              if (widget.onAnalyze != null)
                GestureDetector(
                  onTap: widget.onAnalyze,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('🤖', style: TextStyle(fontSize: 16)),
                  ),
                ),
              // 追加ボタン（常に表示・タップ領域を広く）
              GestureDetector(
                onTap: widget.onAdd,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.add,
                    size: 22,
                    color: Color(0xFF9B6FE0),
                  ),
                ),
              ),
            ],
          ),
          // 展開時のみブックマーク一覧を表示
          if (_isExpanded) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: Color(0xFF3A3A55)),
            if (widget.bookmarks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12, bottom: 4),
                child: Text(
                  'ブックマークはありません',
                  style: TextStyle(fontSize: 12, color: Color(0xFF44445A)),
                ),
              )
            else
              ...widget.bookmarks.map(
                (b) => GestureDetector(
                  onTap: () => widget.onJump(b.position),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            b.label ?? '位置 ${b.position}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFF0F0F8),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => widget.onDelete(b.id),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 18,
                              color: Color(0xFF44445A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
