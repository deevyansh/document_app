import 'package:document_app/pages/notes_page.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
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
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'constants.dart';
import 'pages/profile_page.dart';
import 'pages/full_screen_image.dart';
import 'widgets/document_grid.dart';
import 'pages/favourite_page.dart';
import 'pages/browser_page.dart';
import 'pages/notes_page.dart';
import 'pages/search_page.dart';

void main() async {
  await GoogleSignIn.instance.initialize(
    serverClientId: '302452809509-lbkt373gqmjlvs71hb9hp4av0dtm4fn3.apps.googleusercontent.com',
  );
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
  final PageController _sliderController = PageController();
  Timer? _sliderTimer;
  int _currentSlide = 0;
  final List<String> _sliderImages = [
    'assets/slides/slide1.png',
    'assets/slides/slide2.png',
    'assets/slides/slide3.png',
    'assets/slides/slide4.png',
    'assets/slides/slide5.png',
    'assets/slides/slide6.png',
  ];

  bool _appAlreadyRunning = false;
  final List<TextEditingController> _otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());
  String get _otpCode => _otpControllers.map((c) => c.text).join();
  List<File> _photos = [];
  final _picker = picker.ImagePicker();
  final _recognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);
  AppStage appstage = AppStage.enterEmail;
  final _emailController = TextEditingController();
  bool _openedFromShare = false;
  String? _otpError;
  StreamSubscription? _intentSub;
  File? _profileimage;
  int _importdone = 0;
  int _importtotal = 0;
  Timer? _otpTimer;
  int _otpSecondsRemaining = 300; // 5 minutes
  bool _canResendOtp = false;
  final ScrollController _gridController = ScrollController();
  bool _googleLoading = false;
  late final TapGestureRecognizer _privacyPolicyRecognizer;

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


  Future<File?> _downloadProfileImage(String imageUrl) async {
    final response = await http.get(Uri.parse(imageUrl));
    if (response.statusCode != 200) {
      return null;
    }
    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join( dir.path, 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg', );
    final file = File(dest);
    await file.writeAsBytes(response.bodyBytes);
    await _loadProfileImage();
    return file;
  }

  Future<void> _googleSignIn() async {
    setState(() => _googleLoading = true);
    try {
      final GoogleSignInAccount account = await GoogleSignIn.instance.authenticate();

      final idToken = account.authentication.idToken;
      if (idToken == null) {
        _showError("Google sign-in failed: No ID token returned");
        return;
      }

      final res = await http.post(
        Uri.parse('$baseUrl/auth/google'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': idToken}),
      );

      if (res.statusCode != 200) {
        _showError("Google sign-in failed: ${res.body}");
        return;
      }

      final data = jsonDecode(res.body);
      await storage.write(key: "token", value: data["access_token"]);
      await storage.write(key: "email", value: data["email"]);
      
      final dir = await getApplicationDocumentsDirectory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('profile_'))
          .toList();

      if(files.isEmpty && data["picture"] != null) {
        await _downloadProfileImage(data["picture"]);
      }

      setState(() => appstage = AppStage.document);


    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        _showError("Google sign-in failed: ${e.description ?? e.code}");
      }
      // user backed out of the account picker on purpose — no error needed
    } catch (e) {
      _showError("Google sign-in failed: $e");
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
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

  Future<void> _checkForUpdate() async {
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.updateAvailable) {
        if (info.immediateUpdateAllowed) {
          await InAppUpdate.performImmediateUpdate();
        } else if (info.flexibleUpdateAllowed) {
          await InAppUpdate.startFlexibleUpdate();
        }
      }
    } catch (e) {
      print("Update check failed: $e");
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
    if(_emailController.text.isEmpty || !_emailController.text.contains('@')){
      _showError("Please enter a valid email address.");
      return;
    }
    final res = await _safePost('/get-otp', {'email': _emailController.text});
    if (res == null) {
      return;
    }
    final data = jsonDecode(res.body);
    setState(() {
      _startOtpTimer();
      appstage = AppStage.enterOtp;
      for (final c in _otpControllers){
        c.clear();
      }
      _otpFocusNodes[0].requestFocus();
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
    _sliderTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) {
        if (!_sliderController.hasClients) return;

        _currentSlide =
            (_currentSlide + 1) % _sliderImages.length;

        _sliderController.animateToPage(
          _currentSlide,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
        );
      },
    );
    _privacyPolicyRecognizer = TapGestureRecognizer()
      ..onTap = () async {
        final uri = Uri.parse('https://sites.google.com/view/docezy-privacy-policy');
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not open the privacy policy link.')),
            );
          }
        }
      };
    _initialize();
    
  }

  

  void _setupWidgetChannel() {
    methodChannel.setMethodCallHandler((call) async {
      if (call.method == "onWidgetLaunch") {
        final String action = call.arguments as String;
        if (action == "search") {
          Navigator.of(context).popUntil((route) => route.isFirst);  
          _changeToQueryScreen();
        } else if (action == "voice_search") {
          Navigator.of(context).popUntil((route) => route.isFirst);  
          _changeToQueryScreen(startListening: true);
        }
        else if(action == "camera"){
          Navigator.of(context).popUntil((route) => route.isFirst);  
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scanDocument();
          });
        }
        else if(action == "notes"){
          Navigator.of(context).popUntil((route) => route.isFirst);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _openNotes();
          });
        }
      }
    });
  }

  Future<void> _openNotes() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const NotesPage(),
      ),
    );
    await _load();
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
    await _load();

    if (_openedFromShare) {
      SystemNavigator.pop();
    }
  }

  Future<void> _initialize() async {
    _setupWidgetChannel();

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) async {
      if (value.isNotEmpty) {
        if (!mounted) return;
        if (!_appAlreadyRunning) {
          setState(() => _openedFromShare = true);
        }
        await _handleShared(value);
      }
    });

    final value = await ReceiveSharingIntent.instance.getInitialMedia();

    if (value.isNotEmpty) {
      if (!mounted) return;
      setState(() => _openedFromShare = true);
      await _handleShared(value);
      return;
    }

    await _load();
    await _checktoken();
    await _loadProfileImage();
    await _checkForUpdate(); 

    final String? action = await methodChannel.invokeMethod<String>(
      "getLaunchAction",
    );
    if (action == "search") {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _changeToQueryScreen();
    } else if (action == "voice_search") {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _changeToQueryScreen(startListening: true);
    }
    else if(action == "camera"){
      Navigator.of(context).popUntil((route) => route.isFirst);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scanDocument();
      });
    }
    else if(action == "notes"){
      Navigator.of(context).popUntil((route) => route.isFirst);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openNotes();
      });
    }
    _appAlreadyRunning = true;
  }

  @override
  void dispose() {
    for (final c in _otpControllers) {
      c.dispose();
    }
    for (final f in _otpFocusNodes) {
      f.dispose();
    }
    _sliderTimer?.cancel();
    _sliderController.dispose();
    _otpTimer?.cancel();
    _recognizer.close();
    _emailController.dispose();
    _intentSub?.cancel();
    _privacyPolicyRecognizer.dispose();
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
    final processedPath = await _preprocessForOcr(path);
    final input = InputImage.fromFilePath(processedPath);
    final result = await _recognizer.processImage(input);

    unawaited(File(processedPath).delete().catchError((_) => File(processedPath)));

    return result.text;
  }

  Future<String> _preprocessForOcr(String path) async {
    final bytes = await File(path).readAsBytes();
    final processedBytes = await compute(_binarizeForOcr, bytes);

    final tempDir = await getTemporaryDirectory();
    final outPath = '${tempDir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.png';
    await File(outPath).writeAsBytes(processedBytes);
    return outPath;
  }

  // Must be top-level (or static) since compute() runs it on a background isolate.
  Uint8List _binarizeForOcr(Uint8List bytes) {
    var image = img.decodeImage(bytes);
    if (image == null) return bytes;

    image = img.bakeOrientation(image);      // respect EXIF rotation before anything else
    image = img.grayscale(image);            // drop color, keep luminance
    image = img.normalize(image, min: 0, max: 255); // stretch contrast before thresholding

    final threshold = _otsuThreshold(image); // pick a good cutoff automatically per-image

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final v = image.getPixel(x, y).r.toInt();
        final bw = v >= threshold ? 255 : 0;
        image.setPixelRgb(x, y, bw, bw, bw);
      }
    }

    return Uint8List.fromList(img.encodePng(image));
  }

  int _otsuThreshold(img.Image image) {
    final histogram = List<int>.filled(256, 0);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        histogram[image.getPixel(x, y).r.toInt()]++;
      }
    }

    final total = image.width * image.height;
    var sum = 0.0;
    for (var i = 0; i < 256; i++) sum += i * histogram[i];

    var sumB = 0.0, wB = 0, maxVariance = 0.0, threshold = 0;
    for (var t = 0; t < 256; t++) {
      wB += histogram[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;

      sumB += t * histogram[t];
      final mB = sumB / wB;
      final mF = (sum - sumB) / wF;
      final variance = wB * wF * (mB - mF) * (mB - mF);

      if (variance > maxVariance) {
        maxVariance = variance;
        threshold = t;
      }
    }
    return threshold;
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
    final mode = await _showScanModePicker();
    if (mode == null) return;

    switch (mode) {
      case ScanMode.images:
        await _scanImages();
        break;
      case ScanMode.pdf:
        await _scanPdf();
        break;
      case ScanMode.idCard:
        await _scanIdCard();
        break;
    }
  }

  Future<ScanMode?> _showScanModePicker() async {
    return showModalBottomSheet<ScanMode>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                _scanModeTile(
                  context,
                  icon: Icons.photo_library_outlined,
                  title: "Images",
                  subtitle: "Save each page as its own image",
                  mode: ScanMode.images,
                  accent: const Color(0xFF3B82F6),
                ),
                const SizedBox(height: 12),
                _scanModeTile(
                  context,
                  icon: Icons.picture_as_pdf_outlined,
                  title: "PDF",
                  subtitle: "Combine all pages into one PDF",
                  mode: ScanMode.pdf,
                  accent: const Color(0xFFEF4444),
                ),
                const SizedBox(height: 12),
                _scanModeTile(
                  context,
                  icon: Icons.badge_outlined,
                  title: "ID Card",
                  subtitle: "Front & back on a single page",
                  mode: ScanMode.idCard,
                  accent: const Color(0xFF14B8A6),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _scanModeTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required ScanMode mode,
    required Color accent,
  }) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.15),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(icon, size: 28, color: accent),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
  Future<void> _scanImages() async {
    if (!await _hasInternet()) {
      _showError("No internet connection.");
      return;
    }
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        mode: ScannerMode.base,
        pageLimit: 10,
        isGalleryImport: true,
      ),
    );
    final result = await scanner.scanDocument();
    final images = result.images;
    await scanner.close();
    if (images == null || images.isEmpty) return;

    for (final img in images) {
      await _importFromPath(img);   // each page becomes its own document
    }
  }

  Future<void> _scanPdf() async {
    if (!await _hasInternet()) {
      _showError("No internet connection.");
      return;
    }
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        mode: ScannerMode.base,
        pageLimit: 10,
        isGalleryImport: true,
      ),
    );
    final result = await scanner.scanDocument();
    final images = result.images;
    await scanner.close();
    if (images == null || images.isEmpty) return;

    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}.pdf');
    await _buildPdfFromImages(images, dest);   // your existing function, unchanged
    await _makePdfThumb(dest);
    await _load();
    final text = await _extractPdfText(dest);
    await _storeEmbedding(dest, text);
  }


  Future<void> _scanIdCard() async {
    if (!await _hasInternet()) {
      _showError("No internet connection.");
      return;
    }

    // ── Front ──
    final frontScanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        mode: ScannerMode.base,
        pageLimit: 1,
        isGalleryImport: true,
      ),
    );
    final frontResult = await frontScanner.scanDocument();
    await frontScanner.close();
    final frontImages = frontResult.images;
    if (frontImages == null || frontImages.isEmpty) return;
    final frontPath = frontImages.first;

    // ── Back (optional, with skip) ──
    final wantsBack = await _confirmScanBack();
    String? backPath;
    if (wantsBack) {
      final backScanner = DocumentScanner(
        options: DocumentScannerOptions(
          documentFormats: const {DocumentFormat.jpeg},
          mode: ScannerMode.base,
          pageLimit: 1,
          isGalleryImport: true,
        ),
      );
      final backResult = await backScanner.scanDocument();
      await backScanner.close();
      final backImages = backResult.images;
      if (backImages != null && backImages.isNotEmpty) {
        backPath = backImages.first;
      }
    }

    final dir = await getApplicationDocumentsDirectory();
    final dest = p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}.pdf');
    await _buildIdCardPdf(frontPath, backPath, dest);
    await _makePdfThumb(dest);
    await _load();
    final text = await _extractPdfText(dest);
    await _storeEmbedding(dest, text);
  }

  Future<String> _buildIdCardPdf(
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

  Future<bool> _confirmScanBack() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Scan the back?"),
        content: const Text("Add the back side of the card to the same document?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Skip"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Scan back"),
          ),
        ],
      ),
    );
    return result ?? false;
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
    } else {
      return _buildDocument(context);
    } 
  }

  Widget _buildEmailScreen(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.asset(
                                'assets/logo.png',
                                height: 80,
                                width: 80,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Welcome to DocEzy!',
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
                              inputFormatters: [
                                TextInputFormatter.withFunction((oldValue, newValue) {
                                  return newValue.copyWith(text: newValue.text.toLowerCase());
                                }),
                              ],
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
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                const Expanded(child: Divider()),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text('or', style: TextStyle(color: Colors.grey[600])),
                                ),
                                const Expanded(child: Divider()),
                              ],
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: Material(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                elevation: 0,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: _googleLoading ? null : _googleSignIn,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.grey.shade300),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.05),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        _googleLoading
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(strokeWidth: 2.5),
                                              )
                                            : Image.asset(
                                                'assets/google_logo.png',
                                                height: 20,
                                                width: 20,
                                              ),
                                        const SizedBox(width: 12),
                                        Text(
                                          _googleLoading ? 'Signing in...' : 'Continue with Google',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    height: 1.4,
                  ),
                  children: [
                    const TextSpan(text: 'By continuing, you agree to the '),
                    TextSpan(
                      text: 'DocEzy Privacy Policy',
                      style: const TextStyle(
                        color: Color(0xFF1565C0),
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: _privacyPolicyRecognizer,
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  

  Widget _buildOtpScreen(BuildContext context) {
    return  PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        setState(() {
          appstage = AppStage.enterEmail;
          _otpError = null;
        });
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('DocEzy')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 80, color: Colors.blue),
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
                        color: Colors.blue,
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
      ),
    );
  }

  void _changeToQueryScreen({bool startListening = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(autoStartListening: startListening),
      ),
    );
    await _load(); // refresh in case docs were deleted/shared from search page
  }

  Future<void> _logout() async {
    await storage.delete(key: 'token');
    await storage.delete(key: 'email');
    setState(() {
      appstage = AppStage.enterEmail;
      _emailController.clear();
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
                    _changeToQueryScreen(startListening: true);
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
    final recent = _photos.take(3).toList();

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
        const SizedBox(height: 5),
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
              if (_photos.length >= 4)
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

  Widget _buildPromoSlider() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: MediaQuery.of(context).size.width * 0.93,
          height: MediaQuery.of(context).size.width * 0.93,
          child: PageView.builder(
            controller: _sliderController,
            itemCount: _sliderImages.length,

            onPageChanged: (index) {
              setState(() {
                _currentSlide = index;
              });
            },

            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    _sliderImages[index],
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 8),

        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            _sliderImages.length,
            (index) {
              final isActive = index == _currentSlide;

              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: isActive ? 20 : 5,
                height: 5,
                decoration: BoxDecoration(
                  color: isActive
                      ? Colors.blue
                      : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildDocument(BuildContext context) {
    return Scaffold(
      appBar:AppBar(
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
            ),

      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSearchBar(),
            if (_photos.isNotEmpty) _buildRecentRow(),
            const SizedBox(height: 35),
            _buildPromoSlider(),
            Expanded(
              child:const SizedBox.shrink(),
            ),
          ],
        ),
      ),

      bottomNavigationBar: SafeArea(
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
                      icon: Icons.notes,
                      label: "Notes",
                      onTap: () async {
                        await Navigator.push<void>(
                          context,
                          MaterialPageRoute(builder: (_) => const NotesPage()),
                        );
                        await _load();
                      },
                    ),

                    _bottomButton(
                      icon: Icons.camera_alt,
                      label: "Scan",
                      onTap: _scanDocument,
                    ),

                    _bottomButton(
                      icon: Icons.photo_library,
                      label: "Gallery",
                      onTap: _pickFromGallery,
                    ),

                    _bottomButton(
                      icon: Icons.upload_file,
                      label: "Upload",
                      onTap: _pickFromFile,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  

}
