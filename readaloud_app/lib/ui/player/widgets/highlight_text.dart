import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class HighlightText extends StatefulWidget {
  final String text;
  final int highlightPosition;
  final Function(int)? onTap; // REQ-001: タップで再生位置変更

  const HighlightText({
    super.key,
    required this.text,
    required this.highlightPosition,
    this.onTap,
  });

  @override
  State<HighlightText> createState() => _HighlightTextState();
}

class _HighlightTextState extends State<HighlightText> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _richTextKey = GlobalKey(); // REQ-001
  bool _userScrolled = false; // 手動スクロールフラグ（FIX-039）

  @override
  void didUpdateWidget(HighlightText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlightPosition != widget.highlightPosition) {
      _scrollToHighlight();
    }
  }

  void _scrollToHighlight() {
    if (!_scrollController.hasClients) return;
    if (widget.text.isEmpty) return;

    final ratio = widget.highlightPosition / widget.text.length;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetScroll = (maxScroll * ratio - viewportHeight * 0.5)
        .clamp(0.0, maxScroll);
    final currentScroll = _scrollController.offset;

    // 手動スクロール中の場合（FIX-039）
    if (_userScrolled) {
      // ハイライトが現在のビューポート内に入ったら自動スクロール再開
      final highlightInView = (targetScroll - currentScroll).abs() < viewportHeight;
      if (highlightInView) {
        _userScrolled = false;
      } else {
        return; // まだ範囲外なのでスキップ
      }
    }

    if ((targetScroll - currentScroll).abs() > 50) {
      _scrollController.animateTo(
        targetScroll,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  // REQ-001: タップ位置から文字インデックスを取得
  void _handleTap(TapUpDetails details) {
    if (widget.onTap == null) return;
    final renderObject = _richTextKey.currentContext?.findRenderObject();
    if (renderObject is! RenderParagraph) return;

    // タップのローカル座標にスクロール量を加算して補正
    // GestureDetectorはContainer内側にあるためpaddingの補正は不要
    final scrollOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final localOffset = Offset(
      details.localPosition.dx,
      details.localPosition.dy + scrollOffset,
    );

    final textPosition = renderObject.getPositionForOffset(localOffset);
    widget.onTap!(textPosition.offset);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(30, 16, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: GestureDetector(
        onTapUp: widget.onTap != null ? _handleTap : null,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // UserScrollNotificationはユーザー操作のみ発火（animateToでは発火しない）
            if (notification is UserScrollNotification) {
              _userScrolled = true; // 手動スクロールを検知（FIX-039）
            }
            return false;
          },
          child: SingleChildScrollView(
            controller: _scrollController,
            child: RichText(
            key: _richTextKey,
            text: TextSpan(
              children: _buildTextSpans(),
            ),
          ),
          ),
        ),
      ),
    );
  }

  List<TextSpan> _buildTextSpans() {
    if (widget.text.isEmpty) return [];

    final pos = widget.highlightPosition.clamp(0, widget.text.length);

    const beforeStyle = TextStyle(
      color: Color(0xFF8888AA),
      fontSize: 14,
      height: 2.0,
    );

    const highlightStyle = TextStyle(
      color: Color(0xFFF0F0F8),
      fontSize: 14,
      height: 2.0,
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x449B6FE0),
    );

    if (pos == 0) {
      final firstSentenceEnd = _findSentenceEnd(widget.text, 0);
      return [
        TextSpan(
          text: widget.text.substring(0, firstSentenceEnd),
          style: highlightStyle,
        ),
        TextSpan(
          text: widget.text.substring(firstSentenceEnd),
          style: beforeStyle,
        ),
      ];
    }

    final highlightEnd = _findSentenceEnd(widget.text, pos);

    return [
      TextSpan(
        text: widget.text.substring(0, pos),
        style: beforeStyle,
      ),
      TextSpan(
        text: widget.text.substring(pos, highlightEnd),
        style: highlightStyle,
      ),
      TextSpan(
        text: widget.text.substring(highlightEnd),
        style: beforeStyle,
      ),
    ];
  }

  int _findSentenceEnd(String text, int start) {
    final endChars = ['。', '！', '？', '\n', '.', '!', '?'];
    for (int i = start; i < text.length; i++) {
      if (endChars.contains(text[i])) {
        return (i + 1).clamp(0, text.length);
      }
    }
    return (start + 50).clamp(0, text.length);
  }
}
