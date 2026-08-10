import 'package:document_app/pages/notes_page.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart' as picker;
import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:photo_view/photo_view.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:document_app/main.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'constants.dart';
import 'pages/profile_page.dart';
import 'pages/full_screen_image.dart';
import 'widgets/document_grid.dart';
import 'pages/favourite_page.dart';
import 'pages/browser_page.dart';
import 'pages/notes_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DocEzy',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(elevation: 0, centerTitle: true),
      ),
      home: const MyHomePage(title: 'DocEzy'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final List<TextEditingController> _otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());
  String get _otpCode => _otpControllers.map((c) => c.text).join();
  List<File> _photos = [];
  List<File> _queryphotos = [];
  final _picker = ImagePicker();
  final _recognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);
  AppStage appstage = AppStage.enterEmail;
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  bool _openedFromShare = false;
  String? _otpError;
  final _queryController = TextEditingController();
  StreamSubscription? _intentSub;
  final _enToHi = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.english,
    targetLanguage: TranslateLanguage.hindi,
  );
  final _hiToEn = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.hindi,
    targetLanguage: TranslateLanguage.english,
  );
  final _modelManager = OnDeviceTranslatorModelManager();
  DocumentTypeFilter _typefilter = DocumentTypeFilter.all;
  final FocusNode _queryFocusNode = FocusNode();
  final SpeechToText _speech = SpeechToText();
  String _querytext = "What are you looking for";
  bool _islistening = false;
  File? _profileimage;

  int _importdone = 0;
  int _importtotal = 0;
  Timer? _otpTimer;
  int _otpSecondsRemaining = 300; // 5 minutes
  bool _canResendOtp = false;

  bool _isSelectedMode = false;
  Set<int> _selectedIndexes = {};
  final ScrollController _gridController = ScrollController();

  void _showError(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red,
        content: Text(
          message,
          style: const TextStyle(
            fontSize: 16, // Increase as needed
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
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
        _showError("Server is temporarily unavailable. Please try again.");
        return null;
      }
      return res;
    } on SocketException {
      _showError("No internet connection.");
      return null;
    } on TimeoutException {
      _showError("Request timed out. Please try again.");
      return null;
    } catch (e) {
      _showError("Something went wrong.");
      return null;
    }
  }

  Future<void> _loadProfileImage() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('profile_'))
        .toList();

    if (files.isNotEmpty) {
      files.sort(
        (a, b) => b.path.compareTo(a.path),
      ); // newest last-modified name
      setState(() {
        _profileimage = files.first;
      });
    }
  }

  Future<void> _ensureHindiModel() async {
    final downloaded = await _modelManager.isModelDownloaded(
      TranslateLanguage.hindi.bcpCode,
    );
    if (!downloaded) {
      await _modelManager.downloadModel(
        TranslateLanguage.hindi.bcpCode,
        isWifiRequired: false, // let it use mobile data too
      );
    }
  }

  Future<void> _load() async {
    final dir = await getApplicationDocumentsDirectory();

    final files = dir.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      if (name.startsWith('profile_')) return false;
      if (name.endsWith('.pdf')) return true;
      if (name.endsWith('profile.jpg')) return false;
      if (name.endsWith('.thumb.jpg')) return false;
      if (name.endsWith('.json')) return true;
      return name.endsWith('.jpg') || name.endsWith('.png');
    }).toList();

    files.sort((a, b) {
      final aTime = int.parse(p.basenameWithoutExtension(a.path));
      final bTime = int.parse(p.basenameWithoutExtension(b.path));
      return bTime.compareTo(aTime);
    });

    setState(() => _photos = files);
  }

  Future<void> _otpsubmit() async {
    final res = await _safePost('/verify-otp', {
      'email': _emailController.text,
      'otp': _otpCode,
    });
    if (res == null) {
      return;
    }
    final data = jsonDecode(res.body);
    if (_otpCode.length != 6) {
      setState(() {
        _otpError = 'Please enter the complete 6-digit OTP';
      });
      return;
    }
    setState(() {
      _otpError = null;
    });
    if (data["success"] == true) {
      await storage.write(key: "token", value: data["token"]);
      await storage.write(key: "email", value: _emailController.text);
      setState(() {
        appstage = AppStage.document;
      });
    } else {
      setState(() {
        _otpError = data["reason"];
      });
    }
  }

  Future<void> _emailsubmit() async {
    final res = await _safePost('/get-otp', {'email': _emailController.text});
    if (res == null) {
      return;
    }
    final data = jsonDecode(res.body);
    setState(() {
      _startOtpTimer();
      appstage = AppStage.enterOtp;
    });
  }

  Future<void> _checktoken() async {
    final token = await storage.read(key: 'token');
    if (token == null) {
      setState(() => appstage = AppStage.enterEmail);
    } else {
      setState(() => appstage = AppStage.document);
    }
  }

  @override
  void initState() {
    super.initState();
    _initialize();
    _ensureHindiModel();
    _initSpeech();
  }

  Future<bool> _hindiReady() async {
    return await _modelManager.isModelDownloaded(
      TranslateLanguage.hindi.bcpCode,
    );
  }

  void _setupWidgetChannel() {
    methodChannel.setMethodCallHandler((call) async {
      if (call.method == "onWidgetLaunch") {
        final String action = call.arguments as String;
        if (action == "search") {
          _changeToQueryScreen();
        } else if (action == "voice_search") {
          _changeToQueryScreen();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _startListening();
          });
        }
      }
    });
  }

  Future<void> _handleShared(List<SharedMediaFile> files) async {
    setState(() {
      _importtotal = files.length;
      _importdone = 0;
    });

    for (final f in files) {
      await _importFromPath(f.path);
      setState(() {
        _importdone++;
      });
    }

    if (_openedFromShare) {
      SystemNavigator.pop();
    }
  }

  Future<void> _initialize() async {
    _setupWidgetChannel();

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      if (value.isNotEmpty) {
        if (!mounted) return;
        setState(() => _openedFromShare = true);
        _handleShared(value);
      }
    });

    final value = await ReceiveSharingIntent.instance.getInitialMedia();

    if (value.isNotEmpty) {
      if (!mounted) return;
      setState(() => _openedFromShare = true);
      _handleShared(value);
      return;
    }

    await _load();
    await _checktoken();
    await _loadProfileImage();

    final String? action = await methodChannel.invokeMethod<String>(
      "getLaunchAction",
    );
    if (action == "search") {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _changeToQueryScreen();
    } else if (action == "voice_search") {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _changeToQueryScreen();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startListening();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _otpControllers) {
      c.dispose();
    }
    for (final f in _otpFocusNodes) {
      f.dispose();
    }
    _otpTimer?.cancel();
    _enToHi.close();
    _hiToEn.close();
    _recognizer.close();
    _emailController.dispose();
    _queryController.dispose();
    _intentSub?.cancel();
    _queryFocusNode.dispose();
    _speech.cancel();
    super.dispose();
  }

  Future<String> _detectExt(String filepath) async {
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

  Future<void> _loadqueryphotos(List<dynamic> results) async {
    final files = results
        .map((r) => File(r['doc_path'] as String))
        .where((f) => f.existsSync())
        .toList();
    if (!mounted) return;
    setState(() => _queryphotos = files.take(5).toList()); // Limit to max 5
  }

  Future<void> _makePdfThumb(String pdfPath) async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(
        pdfPath,
      ).timeout(const Duration(seconds: 10));

      final page = await doc.getPage(1);
      final img = await page.render(width: page.width, height: page.height);
      await page.close();

      if (img == null || img.bytes.isEmpty) {
        _showError("PDF image is empty");
        return;
      }

      final thumbPath = '$pdfPath.thumb.jpg';
      await File(thumbPath).writeAsBytes(img.bytes);
      await FileImage(File(thumbPath)).evict(); // clear stale image cache
    } on TimeoutException {
      _showError("PDF not opened (timed out)");
    } catch (e) {
      _showError("PDF thumb failed: $e");
    } finally {
      await doc?.close();
    }
  }

  Future<String?> _transliterateToHindi(String text) async {
    if (text.trim().isEmpty) return null;
    try {
      final uri = Uri.parse(
        'https://inputtools.google.com/request'
        '?text=${Uri.encodeComponent(text)}'
        '&itc=hi-t-i0-und'
        '&num=1&cp=0&cs=1&ie=utf-8&oe=utf-8',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body);
      // Response shape: ["SUCCESS",[["transport",["ट्रांसपोर्ट","ट्रान्सपोर्ट"]]]]
      if (data[0] == "SUCCESS") {
        final suggestions = data[1][0][1] as List;
        if (suggestions.isNotEmpty) return suggestions.first as String;
      }
    } catch (e) {
      print("transliteration failed: $e");
    }
    return null;
  }

  Future<void> _queryDocument() async {
    final sw = Stopwatch()..start();
    final token = await storage.read(key: 'token');
    if (token == null) return;
    final raw = _queryController.text.trim();
    final terms = <String>{raw};

    if (await _hindiReady()) {
      final results = await Future.wait([
        _enToHi.translateText(raw),
        _hiToEn.translateText(raw),
      ]);
      terms.addAll(results);
    }

    // translit is removed because the sometimes the translit = translate and this is causing the problem a bit high
    // final translit = await _transliterateToHindi(raw);
    // if (translit != null) {
    //   print("translit $translit");
    //   terms.add(translit);
    // }

    final combined = terms.join(' ');

    String? x;
    if (_typefilter == DocumentTypeFilter.all) {
      x = "all";
    } else if (_typefilter == DocumentTypeFilter.pdf) {
      x = "pdf";
    } else {
      x = "img";
    }
    final res = await _safePost(
      "/search-document",
      {'user_query': combined, 'type_filter': x},
      extraHeaders: {'Authorization': 'Bearer $token'},
    );
    if (res == null) {
      return;
    }
    final data = jsonDecode(res.body);
    await _loadqueryphotos(data["results"]);
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

    final text = await _extractText(tmp);
    await File(tmp).delete();
    return text;
  }

  Future<String> _extractPdfText(String path) async {
    sf.PdfDocument? document;
    try {
      document = sf.PdfDocument(inputBytes: await File(path).readAsBytes());
      final text = sf.PdfTextExtractor(document).extractText();
      if (text.trim().length >= 20) return text;
    } catch (e) {
      _showError("PDF cannot be opened. $e");
    } finally {
      document?.dispose();
    }

    try {
      return await _extractPdfocrText(path);
    } catch (e) {
      _showError("PDF OCR failed, cannot read the pdf. $e");
      return "";
    }
  }

  Future<String> _extractText(String path) async {
    final input = InputImage.fromFilePath(path);
    final result = await _recognizer.processImage(input);
    print(result.text);
    return result.text;
  }

  Future<bool> _storeEmbedding(String dest, String text) async {
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

  Future<String> _buildPdfFromImages(
    List<String> imagePaths,
    String dest,
  ) async {
    final doc = sf.PdfDocument();
    doc.pageSettings.size = sf.PdfPageSize.a4; // every page identical
    doc.pageSettings.margins.all = 0;

    for (final imgPath in imagePaths) {
      final page = doc.pages.add();
      final image = sf.PdfBitmap(await File(imgPath).readAsBytes());
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

  void _startOtpTimer() {
    _otpTimer?.cancel();
    setState(() {
      _otpSecondsRemaining = 300;
      _canResendOtp = false;
    });

    _otpTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_otpSecondsRemaining > 0) {
        setState(() => _otpSecondsRemaining--);
      } else {
        timer.cancel();
        setState(() => _canResendOtp = true);
      }
    });
  }

  String get _formattedOtpTime {
    final minutes = (_otpSecondsRemaining ~/ 60).toString().padLeft(2, '0');
    final seconds = (_otpSecondsRemaining % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _resendOtp() {
    _emailsubmit();
  }

  Future<void> _importFromPath(String filepath) async {
    final ext = await _detectExt(filepath);
    final isPdf = (ext == 'pdf');
    if (ext == "unknown") {
      _showError("Import is not supported for this file");
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
        await _makePdfThumb(dest);
      } catch (e) {
        _showError("PDF thumb is not generated. $e");
      }
    }
    await _load();

    if (!isPdf) {
      final text = await _extractText(dest);
      if (!await _storeEmbedding(dest, text)) {
        await File(dest).delete();
        await _load();
        return;
      }
    } else {
      final text = await _extractPdfText(dest);
      if (!await _storeEmbedding(dest, text)) {
        await File(dest).delete();
        await _load();
        return;
      }
    }
  }

  Future<bool> _hasInternet() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<void> _pickFromGallery() async {
    if (!await _hasInternet()) {
      _showError("No internet connection.");
      return;
    }
    final List<XFile> images = await _picker.pickMultiImage(
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (images.isEmpty) return;
    for (final image in images) {
      await _importFromPath(image.path);
    }
  }

  Future<void> _pickFromFile() async {
    if (!await _hasInternet()) {
      _showError("No internet Connection");
      return;
    }
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (result == null) return;
    for (final file in result.files) {
      if (file.path == null) continue;
      await _importFromPath(file.path!);
    }
  }

  Future<void> _scanDocument() async {
    if (!await _hasInternet()) {
      _showError("No internet connection.");
      return;
    }
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg, DocumentFormat.pdf},
        mode: ScannerMode.base,
        pageLimit: 5,
        isGalleryImport: true,
      ),
    );

    final result = await scanner.scanDocument();
    final images = result.images;
    if (images == null || images.isEmpty) return;
    if (images.length == 1) {
      await _importFromPath(result.images!.first);
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final dest = p.join(
        dir.path,
        '${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await _buildPdfFromImages(images, dest);
      await _makePdfThumb(dest);
      await _load();
      final text = await _extractPdfText(dest);
      await _storeEmbedding(dest, text);
    }
    await scanner.close();
  }

  Future<void> _initSpeech() async {
    bool available = await _speech.initialize();

    setState(() {
      _speechEnabled = available;
    });
  }

  bool _speechEnabled = false;

  Future<void> _startListening() async {
    setState(() {
      _querytext = "Listening..";
      _islistening = true;
      _queryController.clear();
    });
    await _speech.listen(
      onResult: (result) {
        setState(() {
          _queryController.text = result.recognizedWords;
        });
        if (result.finalResult) {
          _stopListening();
        }
      },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() {
      _querytext = "What are you looking for";
      _islistening = false;
    });
    await _queryDocument();
  }

  Future<void> _pressmicbutton() async {
    if (_islistening) {
      await _stopListening();
    } else {
      await _startListening();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_openedFromShare) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 4),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: 220,
                child: LinearProgressIndicator(
                  value: _importtotal == 0 ? null : _importdone / _importtotal,
                ),
              ),
              const SizedBox(height: 12),

              Text(
                'Importing $_importdone of $_importtotal',
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
    if (appstage == AppStage.enterEmail) {
      return _buildEmailScreen(context);
    } else if (appstage == AppStage.enterOtp) {
      return _buildOtpScreen(context);
    } else if (appstage == AppStage.document) {
      return _buildDocument(context);
    } else {
      return _buildQueryScreen(context);
    }
  }

  Widget _buildEmailScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DocEzy')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18), // adjust this value
                child: Image.asset(
                  'assets/logo.png',
                  height: 80,
                  width: 80,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Welcome!',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in to access your documents',
                style: TextStyle(fontSize: 16, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  hintText: 'you@example.com',
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: Colors.grey[50],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _emailsubmit,
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: const Text('Send OTP', style: TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOtpScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DocEzy')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.lock_outline,
                size: 80,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 24),
              const Text(
                'Verify OTP',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter the code sent to ${_emailController.text}',
                style: const TextStyle(fontSize: 16, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              // ── Timer / Resend section ───────────────────────────────
              if (!_canResendOtp)
                Text(
                  'Resend OTP in $_formattedOtpTime',
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                )
              else
                TextButton(
                  onPressed: _resendOtp,
                  child: const Text(
                    'Resend OTP',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.deepPurple,
                    ),
                  ),
                ),

              const SizedBox(height: 32),

              // ── OTP boxes ────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(6, (index) {
                  return SizedBox(
                    width: 48,
                    height: 56,
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.backspace) {
                          if (index > 0) {
                            _otpFocusNodes[index - 1].requestFocus();
                            _otpControllers[index - 1].clear();
                          }
                          _otpControllers[index].clear();
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _otpControllers[index],
                        focusNode: _otpFocusNodes[index],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        maxLength: 1,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          counterText: '',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Colors.deepPurple,
                              width: 2,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: _otpError != null
                                  ? Colors.red
                                  : Colors.grey.shade400,
                            ),
                          ),
                          filled: true,
                          fillColor: Colors.grey[50],
                        ),
                        onChanged: (value) {
                          if (_otpError != null) {
                            setState(() => _otpError = null);
                          }

                          if (value.length == 1) {
                            if (index < 5) {
                              _otpFocusNodes[index + 1].requestFocus();
                            } else {
                              _otpFocusNodes[index].unfocus();
                              _otpsubmit();
                            }
                          }
                        },
                      ),
                    ),
                  );
                }),
              ),

              // ── Error message ────────────────────────────────────────
              if (_otpError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _otpError!,
                  style: const TextStyle(color: Colors.red, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _changeToQueryScreen() {
    setState(() {
      _typefilter = DocumentTypeFilter.all;
      appstage = AppStage.QueryScreen;
      _queryphotos.clear();
      _queryController.clear();
      _isSelectedMode = false;
      _selectedIndexes.clear();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _queryFocusNode.requestFocus();
      }
    });
  }

  Future<void> _logout() async {
    await storage.delete(key: 'token');
    await storage.delete(key: 'email');
    setState(() {
      appstage = AppStage.enterEmail;
    });
  }

  Future<void> _deleteaccount() async {
    final token = await storage.read(key: 'token');

    for (final f in _photos) {
      if (await f.exists()) {
        await f.delete();
      }
    }
    await _load();
    _showSuccess("All files are deleted");

    final result = await http.post(
      Uri.parse('$baseUrl/delete-user'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (result.statusCode == 200) {
      await storage.delete(key: 'token');
      setState(() {
        appstage = AppStage.enterEmail;
      });
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Failed to delete account")));
    }
  }

  Widget _bottomButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.black.withOpacity(0.72), size: 28),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.black.withOpacity(0.72),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> delete(List<String> files) async {
    final token = await storage.read(key: "token");
    if (token == null) return;
    for (final file in files) {
      await File(file).delete();
      http.post(
        Uri.parse('$baseUrl/delete-document'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'doc_path': file}),
      );
    }
  }

  PreferredSizeWidget _selectAppBar(String window) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Deselect all",
        onPressed: () async {
          setState(() {
            _selectedIndexes.clear();
            _isSelectedMode = false;
          });
        },
      ),
      title: Text("${_selectedIndexes.length} selected"),
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: "Share",
          onPressed: () async {
            if (window == "Document") {
              final filesToShare = _selectedIndexes
                  .map((i) => XFile(_photos[i].path))
                  .toList();
              await Share.shareXFiles(
                filesToShare,
                text: caption,
                subject: "Shared via DocEzy",
              );
            } else {
              final selectedFiles = _selectedIndexes
                  .map((i) => _queryphotos[i])
                  .toList();

              final fileShares = <XFile>[];
              final noteTexts = <String>[];

              for (final file in selectedFiles) {
                if (file.path.endsWith('.json')) {
                  final json = jsonDecode(await file.readAsString());

                  final document = Document.fromJson(
                    List<Map<String, dynamic>>.from(json["delta"]),
                  );

                  noteTexts.add(document.toPlainText());
                } else {
                  fileShares.add(XFile(file.path));
                }
              }

              final hasPdf = fileShares.any((f) => f.path.endsWith('.pdf'));
              final hasImage = fileShares.any(
                (f) =>
                    f.path.endsWith('.jpg') ||
                    f.path.endsWith('.jpeg') ||
                    f.path.endsWith('.png'),
              );

              final isMixed = hasPdf && hasImage;

              String? shareText;
              if (noteTexts.isNotEmpty) {
                shareText = noteTexts.join("\n\n--------------------\n\n");

                if (fileShares.isNotEmpty && !isMixed) {
                  shareText = "$shareText\n\n$caption";
                }
              } else {
                shareText = isMixed ? null : caption;
              }

              if (fileShares.isEmpty) {
                await Share.share(shareText!, subject: "Shared via DocEzy");
              } else {
                await SharePlus.instance.share(
                  ShareParams(
                    files: fileShares,
                    text: shareText,
                    subject: "Shared via DocEzy",
                  ),
                );
              }
            }
            setState(() {
              _selectedIndexes.clear();
              _isSelectedMode = false;
            });
          },
        ),

        IconButton(
          icon: const Icon(Icons.delete),
          tooltip: "Delete",
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete documents?'),
                content: Text(
                  'Delete ${_selectedIndexes.length} document(s)? This cannot be undone.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (confirmed != true) {
              return;
            }
            final pathsToDelete = _selectedIndexes
                .map(
                  (i) => window == "Document"
                      ? _photos[i].path
                      : _queryphotos[i].path,
                )
                .toList();
            await delete(pathsToDelete);
            if (window == "Document") {
              _load();
            } else {
              _load();
              _queryDocument();
            }
            setState(() {
              _selectedIndexes.clear();
              _isSelectedMode = false;
            });
          },
        ),
      ],
    );
  }

  void _handleGridTap(List<File> files, int i, {required VoidCallback onOpen}) {
    if (!_isSelectedMode) {
      onOpen(); // parent-specific: open fullscreen
    } else {
      if (_selectedIndexes.contains(i)) {
        setState(() {
          _selectedIndexes.remove(i);
          if (_selectedIndexes.isEmpty) _isSelectedMode = false;
        });
      } else {
        if (_selectedIndexes.length >= 5) {
          _showError("You cannot share more than 5 at once");
        } else {
          setState(() => _selectedIndexes.add(i));
        }
      }
    }
  }

  void _handleGridLongPress(int i) {
    if (!_isSelectedMode) {
      setState(() {
        _isSelectedMode = true;
        _selectedIndexes.add(i);
      });
    }
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _changeToQueryScreen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.search, color: Colors.grey.shade600, size: 24),

                const SizedBox(width: 14),

                Expanded(
                  child: Text(
                    "Search your documents",
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    _changeToQueryScreen();
                    _startListening();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.mic_none_rounded,
                      color: Colors.blue.shade700,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentRow() {
    if (_photos.isEmpty) return const SizedBox.shrink();

    // 7 recent files + 1 "show more" tile = 8 slots (2×4)
    final recent = _photos.take(7).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Text(
            'Recent',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.75,
            children: [
              // ── recent file tiles ──────────────────────────────
              ...recent.map((file) {
                final isPdf = file.path.endsWith('.pdf');
                final isNote = file.path.endsWith(
                  '.json',
                ); // or your note extension
                final realIndex = _photos.indexOf(file);

                return GestureDetector(
                  onTap: () async {
                    final deleted = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FullScreenImage(
                          files: _photos,
                          startIndex: realIndex,
                        ),
                      ),
                    );
                    if (deleted == true) await _load();
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: isPdf
                        ? Image.file(
                            File('${file.path}.thumb.jpg'),
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.shade200,
                              child: const Icon(
                                Icons.insert_drive_file,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        : !isNote
                        ? Image.file(
                            file,
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.shade200,
                              child: const Icon(
                                Icons.insert_drive_file,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        : FutureBuilder<String>(
                            future: file.readAsString(),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return const Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                );
                              }

                              if (snapshot.hasError || !snapshot.hasData) {
                                return Container(
                                  color: Colors.grey.shade100,
                                  child: const Center(
                                    child: Icon(
                                      Icons.notes_outlined,
                                      size: 36,
                                      color: Colors.grey,
                                    ),
                                  ),
                                );
                              }

                              final json = jsonDecode(snapshot.data!);
                              final preview = json["preview"] ?? "";

                              return Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(
                                      Icons.notes_outlined,
                                      size: 22,
                                      color: Colors.black54,
                                    ),
                                    const SizedBox(height: 6),
                                    Expanded(
                                      child: Text(
                                        preview,
                                        maxLines: 6,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                );
              }),

              // ── "Show more" tile (8th slot) → opens browser ─────
              GestureDetector(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BrowserPage()),
                  );
                  await _load();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.more_horiz, size: 28, color: Colors.black87),
                      SizedBox(height: 4),
                      Text(
                        'Show more',
                        style: TextStyle(fontSize: 11, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDocument(BuildContext context) {
    return Scaffold(
      appBar: (!_isSelectedMode)
          ? AppBar(
              leading: IconButton(
                icon: _profileimage == null
                    ? const Icon(Icons.person)
                    : CircleAvatar(
                        radius: 16,
                        backgroundImage: FileImage(_profileimage!),
                      ),
                tooltip: 'Your Profile',
                onPressed: () async {
                  final email = await storage.read(key: "email") ?? "";
                  final action = await Navigator.push<ProfilePageAction>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProfilePage(userEmail: email),
                    ),
                  );

                  await _loadProfileImage();

                  if (action == ProfilePageAction.deleteaccount) {
                    await _deleteaccount();
                  } else if (action == ProfilePageAction.logout) {
                    await _logout();
                  }
                },
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.favorite, size: 24, color: Colors.red),
                  tooltip: "Open Your Favourites",
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const FavouritesPage()),
                    );
                    await _load();
                  },
                ),

                IconButton(
                  icon: const Icon(Icons.folder, size: 24, color: Colors.black),
                  tooltip: "Browser",
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const BrowserPage()),
                    );
                    await _load();
                  },
                ),
              ],
            )
          : _selectAppBar("Document"),

      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSearchBar(),
            if (!_isSelectedMode && _photos.isNotEmpty) _buildRecentRow(),
            Expanded(
              child: _photos.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_open, size: 80, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'No documents yet',
                            style: TextStyle(fontSize: 18),
                          ),
                          Text(
                            'Tap Scan or Gallery below to add your first document',
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),

      bottomNavigationBar: !_isSelectedMode
          ? SafeArea(
              top: false,
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 1,
                      offset: const Offset(0, -1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _bottomButton(
                      icon: Icons.photo_library,
                      label: "Gallery",
                      onTap: _pickFromGallery,
                    ),
                    _bottomButton(
                      icon: Icons.camera_alt,
                      label: "Scan",
                      onTap: _scanDocument,
                    ),
                    _bottomButton(
                      icon: Icons.notes,
                      label: "Notes",
                      onTap: () {
                        Navigator.push<bool>(
                          context,
                          MaterialPageRoute(builder: (_) => NotesPage()),
                        );
                      },
                    ),
                    _bottomButton(
                      icon: Icons.upload_file,
                      label: "Upload",
                      onTap: _pickFromFile,
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Future<DocumentTypeFilter?> _filterSelection() async {
    DocumentTypeFilter selected = _typefilter;

    return await showDialog<DocumentTypeFilter>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Filter Documents"),

              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<DocumentTypeFilter>(
                    title: const Text("All"),
                    value: DocumentTypeFilter.all,
                    groupValue: selected,
                    onChanged: (value) {
                      setDialogState(() {
                        selected = value!;
                      });
                    },
                  ),

                  RadioListTile<DocumentTypeFilter>(
                    title: const Text("Images"),
                    value: DocumentTypeFilter.image,
                    groupValue: selected,
                    onChanged: (value) {
                      setDialogState(() {
                        selected = value!;
                      });
                    },
                  ),

                  RadioListTile<DocumentTypeFilter>(
                    title: const Text("PDFs"),
                    value: DocumentTypeFilter.pdf,
                    groupValue: selected,
                    onChanged: (value) {
                      setDialogState(() {
                        selected = value!;
                      });
                    },
                  ),
                ],
              ),

              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: const Text("Cancel"),
                ),

                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context, selected);
                  },
                  child: const Text("Apply"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildQueryScreen(BuildContext context) {
    return Scaffold(
      appBar: (!_isSelectedMode)
          ? AppBar(
              title: const Text('Search Documents'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => appstage = AppStage.document),
              ),
            )
          : _selectAppBar("Query"),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    focusNode: _queryFocusNode,
                    decoration: InputDecoration(
                      hintText: _querytext,
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => _queryController.clear(),
                          ),
                          IconButton(
                            icon: Icon(
                              _islistening ? Icons.stop_circle : Icons.mic,
                            ),
                            tooltip: 'Speak',
                            onPressed: _speechEnabled ? _pressmicbutton : null,
                          ),
                        ],
                      ),
                    ),
                    onSubmitted: (_) => _queryDocument(),
                  ),
                ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: () async {
                        final res = await _filterSelection();

                        if (res != null) {
                          setState(() {
                            _typefilter = res;
                          });

                          await _queryDocument();
                        }
                      },
                    ),

                    if (_typefilter != DocumentTypeFilter.all)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            "1",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _queryphotos.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off, size: 80, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No results found',
                          style: TextStyle(fontSize: 18),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: DocumentGrid(
                      files: _queryphotos,
                      crossAxisCount: 2,
                      childAspectRatio: 0.72,
                      isSelectionMode: _isSelectedMode,
                      selectedIndexes: _selectedIndexes,
                      onLongPress: _handleGridLongPress,
                      onTap: (i) => _handleGridTap(
                        _queryphotos,
                        i,
                        onOpen: () async {
                          final deleted = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FullScreenImage(
                                files: _queryphotos,
                                startIndex: i,
                              ),
                            ),
                          );
                          if (deleted == true) {
                            await _load();
                            await _queryDocument();
                          }
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
