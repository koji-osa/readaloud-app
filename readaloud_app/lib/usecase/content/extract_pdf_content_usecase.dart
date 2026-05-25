import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';

class ExtractPdfContentUseCase {
  Future<ExtractPdfResult> execute(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final document = PdfDocument(inputBytes: bytes);

      final extractor = PdfTextExtractor(document);
      final text = extractor.extractText();
      document.dispose();

      // ファイル名からタイトルを生成（拡張子除く）
      final fileName = filePath.split('/').last;
      final dotIndex = fileName.lastIndexOf('.');
      final title = dotIndex >= 0
          ? fileName.substring(0, dotIndex)
          : fileName;

      return ExtractPdfResult(title: title, body: text.trim());
    } catch (e) {
      throw Exception('PDFの読み込みに失敗しました: $e');
    }
  }
}

class ExtractPdfResult {
  final String title;
  final String body;

  ExtractPdfResult({required this.title, required this.body});
}
