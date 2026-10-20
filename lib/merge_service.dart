import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_quill/flutter_quill.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// Merges a mix of PDF, image (.jpg/.jpeg/.png), and DocEzy note (.json,
/// the flutter_quill Delta format notes are saved in) files — in the
/// order given — into a single new PDF file.
///
/// Builds one destination [sf.PdfDocument] and appends to it directly:
/// - Existing PDFs contribute all of their pages, copied via
///   `PdfPage.createTemplate()` at their original size (this avoids
///   relying on `PdfDocument.merge`, which isn't available in every
///   version of syncfusion_flutter_pdf).
/// - Each image becomes one fitted, centered A4 page.
/// - Each note is rendered as auto-paginated plain text.
///
/// Returns the merged PDF as a new [File]. Throws [ArgumentError] if
/// [paths] is empty, [FileSystemException] if a path doesn't exist, or
/// [UnsupportedError] for any other file type.
///
/// If [outputName] is omitted, the file is named `<timestamp>.pdf` — a
/// bare number, like every other document this app writes — so it's
/// picked up by the home/browser screens' file listing.


  Future<String> buildPdfFromImages(
    List<String> imagePaths,
    String dest,
  ) async {
    final doc = sf.PdfDocument();
    doc.pageSettings.size = sf.PdfPageSize.a4; // every page identical
    doc.pageSettings.margins.all = 0;

    for (final imgPath in imagePaths) {
      final page = doc.pages.add();
      final bytes = await File(imgPath).readAsBytes();
      final image = sf.PdfBitmap(bytes);
      final pageSize = page.getClientSize();

      // fit the image inside the A4 page, preserving aspect ratio
      final scale =
          (pageSize.width / image.width) < (pageSize.height / image.height)
          ? pageSize.width / image.width
          : pageSize.height / image.height;
      final w = image.width * scale;
      final h = image.height * scale;
      final x = (pageSize.width - w) / 2;
      final y = (pageSize.height - h) / 2;

      page.graphics.drawImage(image, Rect.fromLTWH(x, y, w, h));
    }

    await File(dest).writeAsBytes(await doc.save());
    doc.dispose();
    return dest;
  }






Future<File> mergeFilesToPdf(List<String> paths, {String? outputName}) async {
  if (paths.isEmpty) {
    throw ArgumentError('mergeFilesToPdf: paths must not be empty');
  }

  final destination = sf.PdfDocument();
  final openSourceDocs = <sf.PdfDocument>[];

  try {
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('File not found', path);
      }

      final ext = p.extension(path).toLowerCase();

      if (ext == '.pdf') {
        final source = sf.PdfDocument(inputBytes: await file.readAsBytes());
        openSourceDocs.add(source);
        _appendPdfPages(destination, source);
      } else if (ext == '.jpg' || ext == '.jpeg' || ext == '.png') {
        await _appendImagePage(destination, file);
      } else if (ext == '.json') {
        await _appendNotePages(destination, file);
      } else {
        throw UnsupportedError('Unsupported file type: $path');
      }
    }

    final bytes = await destination.save();

    final dir = await getApplicationDocumentsDirectory();
    final name = 'temp_file.pdf';
    final outFile = File(p.join(dir.path, name));
    await outFile.writeAsBytes(bytes);
    return outFile;
  } finally {
    destination.dispose();
    for (final doc in openSourceDocs) {
      doc.dispose();
    }
  }
}

/// Copies every page of [source] onto the end of [destination], each at
/// its own original size — deliberately not using `PdfDocument.merge`.
void _appendPdfPages(sf.PdfDocument destination, sf.PdfDocument source) {
  // Fix the page size ONCE for the whole document, instead of re-sizing
  // per source page — this is what keeps every page in the final PDF
  // the same size, regardless of what size the source pages were.
  destination.pageSettings.size = sf.PdfPageSize.a4;
  destination.pageSettings.margins.all = 0;

  for (int i = 0; i < source.pages.count; i++) {
    final sourcePage = source.pages[i];
    final template = sourcePage.createTemplate();
    final srcSize = sourcePage.size;

    final newPage = destination.pages.add();
    final pageSize = newPage.getClientSize();

    // Fit the source page inside the fixed page, preserving its aspect
    // ratio and centering it — same approach already used for images.
    final scale = (pageSize.width / srcSize.width) < (pageSize.height / srcSize.height)
        ? pageSize.width / srcSize.width
        : pageSize.height / srcSize.height;
    final w = srcSize.width * scale;
    final h = srcSize.height * scale;
    final x = (pageSize.width - w) / 2;
    final y = (pageSize.height - h) / 2;
    newPage.graphics.drawPdfTemplate(template, Offset(x, y), Size(w, h));
  }
}

Future<void> _appendImagePage(sf.PdfDocument destination, File imageFile) async {
  destination.pageSettings.size = sf.PdfPageSize.a4;
  destination.pageSettings.margins.all = 0;

  final page = destination.pages.add();
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
}

Future<void> _appendNotePages(sf.PdfDocument destination, File noteFile) async {
  final json = jsonDecode(await noteFile.readAsString());
  final document = Document.fromJson(
    List<Map<String, dynamic>>.from(json['delta']),
  );
  final text = document.toPlainText();

  destination.pageSettings.size = sf.PdfPageSize.a4;
  destination.pageSettings.margins.all = 40;

  final page = destination.pages.add();
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
}

Future<String> buildIdCardPdf(
    String frontPath,
    String? backPath,
    String dest,
  ) async {
    final doc = sf.PdfDocument();
    doc.pageSettings.size = sf.PdfPageSize.a4;
    doc.pageSettings.margins.all = 20;
    final page = doc.pages.add();
    final pageSize = page.getClientSize();

    final frontImage = sf.PdfBitmap(await File(frontPath).readAsBytes());

    const topGap = 50.0;
    const middleGap = 200.0;
    const bottomGap = 50.0;

    // Fixed height every ID image box will use, regardless of source resolution.
    const fixedImageHeight = 210.0;

    final maxAllowedWidth = pageSize.width * 0.75;

    void drawInBox(
      sf.PdfBitmap img,
      double boxTop,
      double boxWidth,
      double boxHeight,
    ) {
      // Fit the image inside the box (preserving its own aspect ratio),
      // then center it within that fixed-size box.
      final widthScale = boxWidth / img.width;
      final heightScale = boxHeight / img.height;
      final scale = widthScale < heightScale ? widthScale : heightScale;

      final drawW = img.width * scale;
      final drawH = img.height * scale;
      final x = (pageSize.width - drawW) / 2;
      final y = boxTop + (boxHeight - drawH) / 2;

      page.graphics.drawImage(img, Rect.fromLTWH(x, y, drawW, drawH));
    }

    if (backPath == null) {
      // Single image: box width = its natural width at fixedImageHeight,
      // capped at 75% of the page.
      final naturalWidth =
          (frontImage.width / frontImage.height) * fixedImageHeight;
      final boxWidth =
          naturalWidth < maxAllowedWidth ? naturalWidth : maxAllowedWidth;

      drawInBox(frontImage, topGap, boxWidth, fixedImageHeight);
    } else {
      final backImage = sf.PdfBitmap(await File(backPath).readAsBytes());

      // Each image's natural width at the fixed height.
      final frontNaturalWidth =
          (frontImage.width / frontImage.height) * fixedImageHeight;
      final backNaturalWidth =
          (backImage.width / backImage.height) * fixedImageHeight;

      // Shared width for BOTH images: the larger of the two natural widths
      // (so neither gets unnecessarily shrunk below its own natural size),
      // but never exceeding 75% of the page width.
      var commonWidth = frontNaturalWidth > backNaturalWidth
          ? frontNaturalWidth
          : backNaturalWidth;
      if (commonWidth > maxAllowedWidth) {
        commonWidth = maxAllowedWidth;
      }

      final frontTop = topGap;
      final backTop = topGap + fixedImageHeight + middleGap;

      drawInBox(frontImage, frontTop, commonWidth, fixedImageHeight);
      drawInBox(backImage, backTop, commonWidth, fixedImageHeight);
    }

    await File(dest).writeAsBytes(await doc.save());
    doc.dispose();
    return dest;
  }

