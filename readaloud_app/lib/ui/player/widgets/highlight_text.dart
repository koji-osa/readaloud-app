import 'package:flutter/material.dart';

class HighlightText extends StatefulWidget {
  final String text;
  final int highlightPosition;

  const HighlightText({
    super.key,
    required this.text,
    required this.highlightPosition,
  });

  @override
  State<HighlightText> createState() => _HighlightTextState();
}

class _HighlightTextState extends State<HighlightText> {
  final ScrollController _scrollController = ScrollController();

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
    // ハイライト位置が画面の上から30%に来るよう調整（FIX-020）
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetScroll = (maxScroll * ratio - viewportHeight * 0.3)
        .clamp(0.0, maxScroll);

    // 現在のスクロール位置から大きくずれている場合のみスクロール
    final currentScroll = _scrollController.offset;
    if ((targetScroll - currentScroll).abs() > 50) {
      _scrollController.animateTo(
        targetScroll,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: SingleChildScrollView(
        controller: _scrollController,
        child: RichText(
          text: TextSpan(
            children: _buildTextSpans(),
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
      // 再生開始時は最初の一文をハイライト表示
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
