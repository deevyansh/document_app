import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_quill/flutter_quill.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// Merges a mix of PDF, image (.jpg/.jpeg/.png), and DocEzy note (.json,
/// the flutter_quill Delta format notes are saved in) files — in the
/// order given — into a single new PDF file.
///
/// - Existing PDFs contribute all of their pages, unchanged.
/// - Each image becomes one fitted, centered A4 page (same layout
///   `_buildPdfFromImages` already uses for scans).
/// - Each note is converted to plain text and auto-paginated across as
///   many pages as it needs.
///
/// Returns the merged PDF as a new [File]. Throws [ArgumentError] if
/// [paths] is empty, [FileSystemException] if a path doesn't exist, or
/// [UnsupportedError] for any other file type.
///
/// If [outputName] is omitted, the file is named `<timestamp>.pdf` — a
/// bare number, like every other document this app writes — so it's
/// picked up by the home/browser screens' file listing. Passing a
/// non-numeric [outputName] still works, but the result won't show up
/// there (it'll still be a valid file you can share directly).
Future<File> mergeFilesToPdf(List<String> paths, {String? outputName}) async {
  if (paths.isEmpty) {
    throw ArgumentError('mergeFilesToPdf: paths must not be empty');
  }

  final docsToMerge = <sf.PdfDocument>[];

  try {
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('File not found', path);
      }

      final ext = p.extension(path).toLowerCase();

      if (ext == '.pdf') {
        docsToMerge.add(sf.PdfDocument(inputBytes: await file.readAsBytes()));
      } else if (ext == '.jpg' || ext == '.jpeg' || ext == '.png') {
        docsToMerge.add(await _imageToPdfDocument(file));
      } else if (ext == '.json') {
        docsToMerge.add(await _noteToPdfDocument(file));
      } else {
        throw UnsupportedError('Unsupported file type: $path');
      }
    }

    final mergedBytes = sf.PdfDocument.merge(docsToMerge);

    final dir = await getApplicationDocumentsDirectory();
    final name = outputName ?? '${DateTime.now().millisecondsSinceEpoch}.pdf';
    final outFile = File(p.join(dir.path, name));
    await outFile.writeAsBytes(mergedBytes);
    return outFile;
  } finally {
    for (final doc in docsToMerge) {
      doc.dispose();
    }
  }
}

/// One A4 page with [imageFile] fitted and centered — same math as the
/// existing `_buildPdfFromImages` in `main.dart`.
Future<sf.PdfDocument> _imageToPdfDocument(File imageFile) async {
  final doc = sf.PdfDocument();
  doc.pageSettings.size = sf.PdfPageSize.a4;
  doc.pageSettings.margins.all = 0;

  final page = doc.pages.add();
  final image = sf.PdfBitmap(await imageFile.readAsBytes());
  final pageSize = page.getClientSize();

  final scale = (pageSize.width / image.width) < (pageSize.height / image.height)
      ? pageSize.width / image.width
      : pageSize.height / image.height;
  final w = image.width * scale;
  final h = image.height * scale;
  final x = (pageSize.width - w) / 2;
  final y = (pageSize.height - h) / 2;

  page.graphics.drawImage(image, Rect.fromLTWH(x, y, w, h));
  return doc;
}

/// Renders a note's plain text (extracted the same way the share flow
/// does — `Document.fromJson(json['delta']).toPlainText()`) across as
/// many auto-paginated pages as it needs.
Future<sf.PdfDocument> _noteToPdfDocument(File noteFile) async {
  final json = jsonDecode(await noteFile.readAsString());
  final document = Document.fromJson(
    List<Map<String, dynamic>>.from(json['delta']),
  );
  final text = document.toPlainText();

  final doc = sf.PdfDocument();
  doc.pageSettings.size = sf.PdfPageSize.a4;
  doc.pageSettings.margins.all = 40;

  final page = doc.pages.add();
  final pageSize = page.getClientSize();

  final textElement = sf.PdfTextElement(
    text: text.isEmpty ? ' ' : text,
    font: sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12),
  );

  textElement.draw(
    page: page,
    bounds: Rect.fromLTWH(0, 0, pageSize.width, pageSize.height),
    format: sf.PdfLayoutFormat(layoutType: sf.PdfLayoutType.paginate),
  );

  return doc;
}