import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'constants.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/painting.dart';
import 'backup_service.dart';

Uint8List _binarizeForOcr(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) return bytes;

  image = img.bakeOrientation(image);      // respect EXIF rotation before anything else
  image = img.grayscale(image);            // drop color, keep luminance
  image = img.normalize(image, min: 0, max: 255); // stretch contrast before thresholding

  return Uint8List.fromList(img.encodePng(image));
}

/// One file's worth of local work already done — copied into the
/// documents dir (and thumbnailed, if a PDF) and OCR'd/text-extracted —
/// waiting to be sent to the backend. Produced by
/// StoreService._prepareSingleImport, consumed by
/// StoreService._storeEmbeddingsBatch.
class _PreparedImport {
  final String destPath;
  final String text;
  const _PreparedImport(this.destPath, this.text);
}

class StoreService {
  final void Function(String message) onError;
  final Future<void> Function() onLoad;
  StoreService({required this.onError, required this.onLoad});
  final TextRecognizer _latinRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final TextRecognizer _devanagariRecognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);

  // Every imported document is named after the millisecond it was
  // imported at (see importFromPath/_prepareSingleImport below) — both
  // _load()'s sort order and the backend's upload_time (main.py parses
  // Path(doc_path).stem as int(...) / 1000) depend on that filename
  // being a bare integer. DateTime.now().millisecondsSinceEpoch alone
  // isn't safe once imports run concurrently (importMultipleFiles) since
  // two files prepared in the same millisecond would collide, so this
  // keeps every generated timestamp strictly increasing instead. It's a
  // static (class-level, not per-instance) counter because more than one
  // StoreService can exist at once (SearchPage/BrowserPage/the home page
  // each construct their own) and they all write into the same documents
  // directory, so uniqueness has to hold app-wide, not just per-instance.
  //
  // Safe without a lock: this is called synchronously (no `await`
  // anywhere inside it), and Dart's single-threaded event loop can't
  // interleave two synchronous calls, however many concurrent `async`
  // workers are calling it "at once".
  static int _lastGeneratedTimestamp = 0;

  static int _nextUniqueTimestamp() {
    var t = DateTime.now().millisecondsSinceEpoch;
    if (t <= _lastGeneratedTimestamp) {
      t = _lastGeneratedTimestamp + 1;
    }
    _lastGeneratedTimestamp = t;
    return t;
  }

  @override
  void dispose(){
    _latinRecognizer.close();
    _devanagariRecognizer.close();
  }

  Future<bool> containsQRCode(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);

    final barcodeScanner = BarcodeScanner(
      formats: [BarcodeFormat.qrCode],
    );

    try {
      final barcodes = await barcodeScanner.processImage(inputImage);

      return barcodes.isNotEmpty;
    } catch (e) {
      return false;
    } finally {
      await barcodeScanner.close();
    }
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
    await BackupService.registerPendingBackup(dest);
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
      await _evictThumbCache(thumbPath);
    } on TimeoutException {
      onError("PDF not opened (timed out)");
    } catch (e) {
      onError("PDF thumb failed: $e");
    } finally {
      await doc?.close();
    }
  }

  /// Evicts every image-cache entry that could still be serving stale bytes
  /// for this PDF's thumbnail file. Flutter's ImageCache keys a decoded
  /// image by (ImageProvider, exact configuration) — a plain FileImage(file)
  /// and an Image.file(file, cacheWidth: N) (which internally wraps the
  /// FileImage in a ResizeImage(width: N)) are each a DIFFERENT cache key,
  /// so overwriting the file on disk and evicting only one variant leaves
  /// the others still handing out the old thumbnail (the "white
  /// background"/stale-thumb bug). 200 and 500 are the two cacheWidth
  /// values actually used for PDF thumbnails today — main.dart's "Recent"
  /// row and document_grid.dart's shared grid tile, respectively — plus the
  /// unsized variant in case anything ever renders one without a
  /// cacheWidth. If another call site adds a new cacheWidth, evict it here
  /// too.
  Future<void> _evictThumbCache(String thumbPath) async {
    final file = File(thumbPath);
    await FileImage(file).evict();
    for (final width in const [200, 500]) {
      await ResizeImage(FileImage(file), width: width).evict();
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

  // ── Parallel multi-file import ─────────────────────────────────────
  //
  // importFromPath() above does everything for one file at a time:
  // copy -> thumbnail -> OCR/text-extract -> one /send-document call.
  // Call sites that import several files (gallery multi-select, the
  // file picker, document scanning) used to just loop importFromPath()
  // sequentially, so file #10 waited on files #1-9 finishing their OCR
  // and their own individual network round trip before it even started.
  //
  // importMultipleFiles() instead: (1) does every file's *local* work
  // (copy/thumbnail/OCR) concurrently, capped at [maxConcurrent] so a
  // big batch doesn't try to decode/OCR everything at once and blow
  // through device memory; then (2) sends every successfully-prepared
  // file in ONE /send-documents-batch call instead of one /send-document
  // per file — see send_documents_batch() in main.py.

  /// Does the copy/thumbnail/OCR work for one file, exactly like the
  /// first half of importFromPath() — but returns the result instead of
  /// immediately posting it, so importMultipleFiles() can run many of
  /// these concurrently and batch the network step separately. Returns
  /// null (after reporting via onError) for a file that fails to
  /// prepare — that file is simply left out of the batch.
  ///
  /// Split into two stages so the caller sees each file the moment it's
  /// actually visible on disk, instead of only after every file in the
  /// whole batch has finished (the slow part):
  ///   Stage A — copy + thumbnail (fast). Calls onLoad() itself, right
  ///   here, the instant *this one file* is ready — exactly when
  ///   importFromPath() calls onLoad() for a single file. With several
  ///   of these running concurrently (see _prepareFilesConcurrently),
  ///   this is what makes files trickle into the grid in the small
  ///   batches [maxConcurrent] actually processes them in, rather than
  ///   all appearing at once at the end.
  ///   Stage B — OCR/PDF text extraction (slow). Runs after the file is
  ///   already visible, so its latency no longer blocks the UI.
  Future<_PreparedImport?> _prepareSingleImport(String filepath) async {
    String? dest;
    bool isPdf = false;
    try {
      final ext = await detectExt(filepath);
      if (ext == "unknown") {
        onError("Import is not supported for this file: ${p.basename(filepath)}");
        return null;
      }
      isPdf = (ext == 'pdf');

      final dir = await getApplicationDocumentsDirectory();
      dest = p.join(dir.path, '${_nextUniqueTimestamp()}.$ext');
      await File(filepath).copy(dest);

      if (isPdf) {
        try {
          await makePdfThumb(dest);
        } catch (e) {
          onError("PDF thumb is not generated. $e");
        }
      }
    } catch (e) {
      onError("Couldn't import ${p.basename(filepath)}: $e");
      return null;
    }

    // Stage A done — this file is copied (and thumbnailed) on disk, so
    // it can already show up in the grid while OCR still runs for it
    // and for whatever else is mid-flight in the other worker slots.
    onLoad();

    try {
      String text = isPdf ? await extractPdfText(dest) : await extractText(dest);
      if(!isPdf){
        if (await containsQRCode(dest)) {
          text += " qr code scan scanner";
        }
      }
      else{
        if (await containsQRCode(dest+".thumb.jpg")) {
          text += " qr code scan scanner";
        }
      }
      return _PreparedImport(dest, text);
    } catch (e) {
      onError("Couldn't import ${p.basename(filepath)}: $e");
      // dest is already on disk and was already shown via the onLoad()
      // above — since this file won't make it into the batch upload
      // (and so will never get a docs-table row), it has to come back
      // off disk too, same as importFromPath() does on its own failure
      // path, so it doesn't linger as an orphaned, unsearchable file.
      try {
        await File(dest).delete();
      } catch (_) {}
      onLoad();
      return null;
    }
  }

  /// Runs _prepareSingleImport over every path in [filepaths] with at
  /// most [maxConcurrent] running at once (a simple worker-pool: each
  /// worker pulls the next unclaimed index and processes it, so as soon
  /// as one file finishes its worker immediately picks up the next
  /// rather than waiting for the whole batch to advance in lockstep).
  /// Order of [filepaths] is preserved in the returned list; a null
  /// entry marks a file that failed to prepare.
  Future<List<_PreparedImport?>> _prepareFilesConcurrently(
    List<String> filepaths, {
    required int maxConcurrent,
  }) async {
    final results = List<_PreparedImport?>.filled(filepaths.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next;
        if (i >= filepaths.length) return;
        next++;
        results[i] = await _prepareSingleImport(filepaths[i]);
      }
    }

    final workerCount = filepaths.length < maxConcurrent ? filepaths.length : maxConcurrent;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results;
  }

  /// Sends every prepared file's (doc_path, text) pair to
  /// /send-documents-batch in one request. Returns the set of destPaths
  /// the backend actually recorded.
  ///
  /// That endpoint commits every row in one transaction (executemany +
  /// a single commit, rolling back entirely on any error — see
  /// send_documents_batch() in main.py), so this is all-or-nothing: on
  /// any failure (network, timeout, non-200, a row the backend
  /// rejected) NOTHING in this batch was recorded, so an empty set is
  /// returned rather than guessing which file was the problem.
  Future<Set<String>> _storeEmbeddingsBatch(List<_PreparedImport> items) async {
    if (items.isEmpty) return {};

    final token = await storage.read(key: 'token');
    if (token == null) return {};

    final res = await _safePost(
      "/send-documents-batch",
      {
        'documents': items
            .map((item) => {'doc_path': item.destPath, 'text': item.text})
            .toList(),
      },
      extraHeaders: {'Authorization': 'Bearer $token'},
    );

    if (res == null || res.statusCode != 200) {
      return {};
    }

    try {
      final data = jsonDecode(res.body);
      if (data['success'] != true) return {};
    } catch (_) {
      return {};
    }

    return items.map((item) => item.destPath).toSet();
  }

  /// Imports every file in [filepaths] in parallel instead of one at a
  /// time — the multi-file counterpart to importFromPath(). Each file's
  /// local work (copy, PDF thumbnail, OCR/PDF text extraction) runs
  /// concurrently (bounded by [maxConcurrent]); the resulting
  /// (doc_path, text) pairs are then sent to the backend in a single
  /// batched call instead of one request per file.
  ///
  /// Mirrors importFromPath()'s failure handling: since the batch
  /// backend call is all-or-nothing (see _storeEmbeddingsBatch above),
  /// a failed batch deletes every locally-copied file in it, exactly
  /// like importFromPath() deletes a single file when its own
  /// storeEmbedding() call fails — never leaving behind a local file
  /// with no corresponding docs-table row.
  Future<void> importMultipleFiles(
    List<String> filepaths, {
    int maxConcurrent = 3,
  }) async {
    if (filepaths.isEmpty) return;

    // Each file calls onLoad() itself as soon as it's copied (and, if a
    // PDF, thumbnailed) — see _prepareSingleImport's Stage A — so files
    // trickle into the grid in roughly the [maxConcurrent]-sized batches
    // they're actually processed in, instead of only appearing once
    // every file (OCR included) has finished.
    final prepared = await _prepareFilesConcurrently(
      filepaths,
      maxConcurrent: maxConcurrent,
    );
    final ready = prepared.whereType<_PreparedImport>().toList();

    if (ready.isEmpty) return;

    final succeededPaths = await _storeEmbeddingsBatch(ready);

    final failed = ready.where((item) => !succeededPaths.contains(item.destPath));
    for (final item in failed) {
      try {
        await File(item.destPath).delete();
      } catch (_) {}
    }

    for (final item in ready) {
      if (succeededPaths.contains(item.destPath)) {
        await BackupService.registerPendingBackup(item.destPath);
      }
    }

    onLoad();
  }
}