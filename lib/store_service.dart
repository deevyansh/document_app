import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'constants.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/painting.dart';

Uint8List _binarizeForOcr(Uint8List bytes) {
    var image = img.decodeImage(bytes);
    if (image == null) return bytes;

    image = img.bakeOrientation(image);      // respect EXIF rotation before anything else
    image = img.grayscale(image);            // drop color, keep luminance
    image = img.normalize(image, min: 0, max: 255); // stretch contrast before thresholding

    return Uint8List.fromList(img.encodePng(image));
}

class StoreService {
    final void Function(String message) onError;
    final Future<void> Function() onLoad;
    StoreService({required this.onError, required this.onLoad});
    final TextRecognizer _latinRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final TextRecognizer _devanagariRecognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);


    @override
    void dispose(){
        _latinRecognizer.close();
        _devanagariRecognizer.close();
    }

    Future<String> _extractPdfocrText(String path) async {
        final doc = await pdfx.PdfDocument.openFile(path);
        final page = await doc.getPage(1);
        final img = await page.render(
          width: page.width * 2,
          height: page.height * 2,
        );
        await page.close();
        await doc.close();

        final dir = await getApplicationDocumentsDirectory();
        final tmp = p.join(
          dir.path,
          'tmp_ocr_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await File(tmp).writeAsBytes(img!.bytes);

        final text = await extractText(tmp);
        await File(tmp).delete();
        return text;
    }

    Future<String> _preprocessForOcr(String path) async {
        final bytes = await File(path).readAsBytes();
        final processedBytes = await compute(_binarizeForOcr, bytes);

        final tempDir = await getTemporaryDirectory();
        final outPath = '${tempDir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.png';
        await File(outPath).writeAsBytes(processedBytes);
        return outPath;
    }

    Future<String> extractPdfText(String path) async {
        sf.PdfDocument? document;
        try {
          document = sf.PdfDocument(inputBytes: await File(path).readAsBytes());
          final text = sf.PdfTextExtractor(document).extractText();
          if (text.trim().length >= 20) return text;
        } catch (e) {
          onError("PDF cannot be opened. $e");
        } finally {
          document?.dispose();
        }

        try {
          return await _extractPdfocrText(path);
        } catch (e) {
          onError("PDF OCR failed, cannot read the pdf. $e");
          return "";
        }
    }


    String _mergeOcrResults(RecognizedText latin, RecognizedText devanagari) {
        int nonWhitespaceCount(RecognizedText r) =>
            r.text.replaceAll(RegExp(r'\s'), '').length;

        final latinChars = nonWhitespaceCount(latin);
        final devanagariChars = nonWhitespaceCount(devanagari);

        // One script clearly dominates — the other pass was just noise on
        // glyphs it can't read, so discard it.
        if (latinChars > devanagariChars * 2) return latin.text;
        if (devanagariChars > latinChars * 2) return devanagari.text;

        // Comparable output from both → likely a genuinely mixed-script page
        // (an Aadhaar/PAN card is the classic case). Merge blocks from both,
        // ordered by vertical position so reading order roughly follows layout.
        final blocks = [
          ...latin.blocks.map((b) => (top: b.boundingBox.top, text: b.text)),
          ...devanagari.blocks.map((b) => (top: b.boundingBox.top, text: b.text)),
        ]..sort((a, b) => a.top.compareTo(b.top));

        return blocks.map((b) => b.text).join('\n');
    }

    Future<String> extractText(String path) async {
        final processedPath = await _preprocessForOcr(path);
        final input = InputImage.fromFilePath(processedPath);

        final latinResult = await _latinRecognizer.processImage(input);
        final devanagariResult = await _devanagariRecognizer.processImage(input);

        unawaited(File(processedPath).delete().catchError((_) => File(processedPath)));

        return _mergeOcrResults(latinResult, devanagariResult);
    }

    Future<http.Response?> _safePost(
        String path,
        Map<String, dynamic> body, {
        Map<String, String>? extraHeaders,
      }) async {
        try {
          final res = await http
              .post(
                Uri.parse('$baseUrl$path'),
                headers: {'Content-Type': 'application/json', ...?extraHeaders},
                body: jsonEncode(body),
              )
              .timeout(const Duration(seconds: 30));

          if (res.statusCode >= 500) {
            onError("Server is temporarily unavailable. Please try again.");
            return null;
          }
          return res;
        } on SocketException {
          onError("No internet connection.");
          return null;
        } on TimeoutException {
          onError("Request timed out. Please try again.");
          return null;
        } catch (e) {
          onError("Something went wrong.");
          return null;
        }
    }


    Future<bool> storeEmbedding(String dest, String text) async {
        final token = await storage.read(key: 'token');
        if (token == null) return false;
        final res = await _safePost(
          "/send-document",
          {'doc_path': dest, 'text': text},
          extraHeaders: {'Authorization': 'Bearer $token'},
        );
        if (res == null) {
          return false;
        }
        return true;
    }

    Future<void> makePdfThumb(String pdfPath) async {
        pdfx.PdfDocument? doc;
        try {
          doc = await pdfx.PdfDocument.openFile(
            pdfPath,
          ).timeout(const Duration(seconds: 10));

          final page = await doc.getPage(1);
          final img = await page.render(width: page.width, height: page.height);
          await page.close();

          if (img == null || img.bytes.isEmpty) {
            onError("PDF image is empty");
            return;
          }

          final thumbPath = '$pdfPath.thumb.jpg';
          await File(thumbPath).writeAsBytes(img.bytes);
          await FileImage(File(thumbPath)).evict(); // clear stale image cache
        } on TimeoutException {
          onError("PDF not opened (timed out)");
        } catch (e) {
          onError("PDF thumb failed: $e");
        } finally {
          await doc?.close();
        }
    }

    Future<String> detectExt(String filepath) async {
        final bytes = await File(filepath).openRead(0, 12).first;
        // PDF: %PDF
        if (bytes.length >= 4 &&
            bytes[0] == 0x25 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x44 &&
            bytes[3] == 0x46)
          return 'pdf';
        // JPEG: FF D8 FF
        if (bytes.length >= 3 &&
            bytes[0] == 0xFF &&
            bytes[1] == 0xD8 &&
            bytes[2] == 0xFF)
          return 'jpg';
        // PNG: 89 50 4E 47
        if (bytes.length >= 4 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47)
          return 'png';
        return 'unknown';
    }

    Future<void> importFromPath(String filepath) async {
      final ext = await detectExt(filepath);
      final isPdf = (ext == 'pdf');
      if (ext == "unknown") {
        onError("Import is not supported for this file");
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final dest = p.join(
        dir.path,
        '${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await File(filepath).copy(dest);
      if (isPdf) {
        try {
          await makePdfThumb(dest);
        } catch (e) {
          onError("PDF thumb is not generated. $e");
        }
      }
      onLoad();

      if (!isPdf) {
        final text = await extractText(dest);
        if (!await storeEmbedding(dest, text)) {
          await File(dest).delete();
          onLoad();
          return;
        }
      } else {
        final text = await extractPdfText(dest);
        if (!await storeEmbedding(dest, text)) {
          await File(dest).delete();
          onLoad();
          return;
        }
      }
  }
}