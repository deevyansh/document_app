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
import 'package:document_app/main.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

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
import 'pin_service.dart';
import 'pages/pin_lock_page.dart';
import 'pages/pin_setup_page.dart';
import 'pages/backup_status_page.dart';
import 'store_service.dart';
import 'merge_service.dart';
import 'backup_service.dart';

int _fileVersion(File file) {
  try {
    return file.lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackupService.initialize();
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

/// The two ways a user can respond to the "some files aren't backed up
/// yet" warning shown by [MyHomePageState._confirmLogout] right before a
/// logout that would lose local-only files.
enum _LogoutChoice { logoutAnyway, goToBackupStatus }

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => MyHomePageState();
}

class MyHomePageState extends State<MyHomePage> {
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
  final _modelManager = OnDeviceTranslatorModelManager();
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
  late final TapGestureRecognizer _termsRecognizer;
  bool _pinUnlockedThisSession = false;

  // True from first build until we've figured out (from secure storage)
  // whether this launch needs the PIN lock, lands on the document screen,
  // or — for an account that has never logged in — goes straight to the
  // email screen. While true, build() shows a brief neutral splash instead
  // of guessing; this is what stops a brand-new user from ever seeing the
  // PIN lock screen, even for a moment, before landing on email entry.
  bool _bootstrapping = true;

  late final StoreService _storeService = StoreService(
    onError: _showError,
    onLoad:  _load,
  );

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

  Future<bool> _translationModelsReady() async {
    final hindiReady = await _modelManager.isModelDownloaded(
      TranslateLanguage.hindi.bcpCode,
    );
    final englishReady = await _modelManager.isModelDownloaded(
      TranslateLanguage.english.bcpCode,
    );
    return hindiReady && englishReady;
  }

  Future<void> _ensureTranslationModels() async {
    try {
      if (await _translationModelsReady()) return;

      if (!await _hasInternet()) {
        _showError("Please turn on your network to download language models.");
        return;
      }

      final hindiReady = await _modelManager.isModelDownloaded(
        TranslateLanguage.hindi.bcpCode,
      );
      final englishReady = await _modelManager.isModelDownloaded(
        TranslateLanguage.english.bcpCode,
      );

      if (!hindiReady) {
        await _modelManager.downloadModel(
          TranslateLanguage.hindi.bcpCode,
          isWifiRequired: false,
        );
      }
      if (!englishReady) {
        await _modelManager.downloadModel(
          TranslateLanguage.english.bcpCode,
          isWifiRequired: false,
        );
      }
    } catch (e) {
      debugPrint('Translation model download failed: $e');
      _showError("Please turn on your network to download language models.");
    }
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

      unawaited(BackupService.autoRestoreAfterLogin());

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
    final numericName = RegExp(r'^\d+$');

    final files = dir.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      if (name.startsWith('profile_')) return false;
      if (name.endsWith('profile.jpg')) return false;
      if (name.endsWith('.thumb.jpg')) return false;

      final stem = p.basenameWithoutExtension(f.path);
      if (!numericName.hasMatch(stem)) return false; // guards the int.parse in sort()

      if (name.endsWith('.pdf')) return true;
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
      unawaited(BackupService.autoRestoreAfterLogin());
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
      return;
    }
  }

  Future<void> _handleForgotPin() async {
    if (!await _hasInternet()) {
      _showError("Please turn on your network to reset your PIN.");
      return;
    }
    final email = await storage.read(key: 'email');
    if (email == null) {
      _showError("No account email found. Please log in again.");
      return;
    }

    final res = await _safePost('/get-otp', {'email': email});
    if (res == null) return;
    if (!mounted) return;

    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _ForgotPinOtpDialog(email: email, safePost: _safePost),
    );

    if (verified != true) return;

    await pinService.clearPin();
    if (!mounted) return;

    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const PinSetupPage(
          title: 'Set a new PIN',
          subtitle: 'Choose a new 4-digit PIN to lock DocEzy',
        ),
      ),
    );

    if (created == true) {
      _pinUnlockedThisSession = true;
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
    _termsRecognizer = TapGestureRecognizer()
      ..onTap = () async {
        final uri = Uri.parse('https://terms.docezy.in/');
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
    if (files.isEmpty) return;

    setState(() {
      _importtotal = files.length;
      _importdone = 0;
    });

    final paths = files.map((f) => f.path).toList();

    // Real work runs in the background
    final importFuture = _storeService.importMultipleFiles(paths);

    // Fake progress: 1 second per file for all but the last
    for (var i = 0; i < files.length - 1; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() => _importdone = i + 1);
    }

    // Wait for the actual import, then mark the last file done
    await importFuture;
    if (!mounted) return;
    setState(() => _importdone = files.length);

    await _load();

    if (_openedFromShare) {
      SystemNavigator.pop();
    }
  }

  /// Reads secure storage just once (or twice, at most) to decide where a
  /// brand-new launch should land, then flips [_bootstrapping] off so
  /// build() stops showing the splash and shows the *real* destination.
  ///
  /// Order matters here: token is checked first, and [pinService] is only
  /// consulted if a token actually exists — a fresh install can't possibly
  /// have a PIN set (PIN setup only happens post-login, from Profile), so
  /// there's no reason to pay for that extra secure-storage read on the
  /// path a brand-new user takes.
  Future<void> _resolveStartupDestination() async {
    final token = await storage.read(key: 'token');

    if (token == null) {
      _pinUnlockedThisSession = true;
      if (!mounted) return;
      setState(() {
        appstage = AppStage.enterEmail;
        _bootstrapping = false;
      });
      return;
    }

    if (!await pinService.isPinEnabled()) {
      _pinUnlockedThisSession = true;
    }

    if (!mounted) return;
    setState(() => _bootstrapping = false);

    if (_pinUnlockedThisSession) {
      _pinunlocked();
    }
  }

  Future<void> _initialize() async {
    _setupWidgetChannel();
    unawaited(_ensureTranslationModels());
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) async {
      if (value.isNotEmpty) {
        if (!mounted) return;
        if (!_appAlreadyRunning) {
          setState(() => _openedFromShare = true);
        }
        await _handleShared(value);
      }
    });

    // Kick both off together — neither depends on the other's result, and
    // running them one after another used to be exactly what kept a
    // brand-new user staring at the PIN lock screen for several seconds
    // before ever reaching the email screen.
    final sharedMediaFuture = ReceiveSharingIntent.instance.getInitialMedia();
    final destinationFuture = _resolveStartupDestination();

    final sharedMedia = await sharedMediaFuture;
    await destinationFuture;

    if (sharedMedia.isNotEmpty) {
      if (!mounted) return;
      setState(() => _openedFromShare = true);
      await _handleShared(sharedMedia);
      return;
    }

    await _load();
    await _loadProfileImage();
    unawaited(_checkForUpdate());

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
    _storeService.dispose();
    _sliderTimer?.cancel();
    _sliderController.dispose();
    _otpTimer?.cancel();
    _emailController.dispose();
    _intentSub?.cancel();
    _privacyPolicyRecognizer.dispose();
    _termsRecognizer.dispose();
    super.dispose();
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
    await _storeService.importMultipleFiles(
      images.map((image) => image.path).toList(),
    );
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
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;
    await _storeService.importMultipleFiles(paths);
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

    // each page becomes its own document
    await _storeService.importMultipleFiles(images);
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
    await buildPdfFromImages(images, dest);   // your existing function, unchanged
    await _storeService.makePdfThumb(dest);
    await _load();
    final text = await _storeService.extractPdfText(dest);
    await _storeService.storeEmbedding(dest, text);
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
    await buildIdCardPdf(frontPath, backPath, dest);
    await _storeService.makePdfThumb(dest);
    await _load();
    final text = await _storeService.extractPdfText(dest);
    await _storeService.storeEmbedding(dest, text);
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


  void _pinunlocked() async{
    setState((){
      appstage=AppStage.document;
    });
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
  }

  Widget _buildSplash(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
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
    if (_bootstrapping) {
      return _buildSplash(context);
    }
    if (!_pinUnlockedThisSession) {
      return PinLockPage(
        onUnlocked: () {
          _pinUnlockedThisSession = true;
          _pinunlocked();
        },
        onForgotPin: _handleForgotPin,
      );
    }
    if (appstage == AppStage.enterEmail) {
      return _buildEmailScreen(context);
    } else if (appstage == AppStage.enterOtp) {
      return _buildOtpScreen(context);
    }
    else {
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
                    const TextSpan(text: ' , '),
                    TextSpan(
                      text: 'DocEzy Terms and Conditions',
                      style: const TextStyle(
                        color: Color(0xFF1565C0),
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: _termsRecognizer,
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
    await BackupService.clearLocalAccountData();
    await storage.delete(key: 'token');
    await storage.delete(key: 'email');
    setState(() {
      appstage = AppStage.enterEmail;
      _emailController.clear();
    });
  }

  /// Gate in front of [_logout]: logging out wipes every local document
  /// (see [BackupService.clearLocalAccountData]), so anything that isn't
  /// backed up yet is gone for good the moment this runs. Checks how many
  /// local documents aren't backed up right now and, if there are any,
  /// asks the user how they want to proceed instead of silently losing
  /// files. Falls back to logging out directly if the check itself can't
  /// be completed (e.g. no connection) — there's nothing more specific to
  /// warn about in that case, and blocking logout entirely over a failed
  /// status check would be worse than just proceeding.
  Future<void> _confirmLogout() async {
    BackupStatusSummary? summary;
    try {
      summary = await BackupService.getStatus();
    } catch (_) {
      summary = null;
    }

    final notBackedUp = summary?.notBackedUp ?? 0;
    if (notBackedUp <= 0) {
      await _logout();
      return;
    }

    if (!mounted) return;
    final choice = await showDialog<_LogoutChoice>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Some files aren't backed up"),
        content: Text(
          notBackedUp == 1
              ? "1 file isn't backed up yet and will be lost from this "
                "device if you log out now."
              : "$notBackedUp files aren't backed up yet and will be lost "
                "from this device if you log out now.",
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _LogoutChoice.logoutAnyway),
            child: const Text("Log Out Anyway"),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _LogoutChoice.goToBackupStatus),
            child: const Text("Go to Backup Status"),
          ),
        ],
      ),
    );

    if (choice == _LogoutChoice.logoutAnyway) {
      await _logout();
    } else if (choice == _LogoutChoice.goToBackupStatus) {
      // Deliberately does NOT log out — this takes the user to Backup
      // Status so they can back up what's missing (or free up storage if
      // that's why it's stuck) first. They can come back and log out
      // again from Profile once ready; at that point, if nothing's left
      // unbacked-up, this dialog won't show at all.
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BackupStatusPage()),
      );
    }
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
      await BackupService.markDeleted(file);
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

    // 3 recent files + 1 "Show more" tile
    final recent = _photos.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Text(
            'Recent',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
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
              ...recent.map((file) {
                final isPdf = file.path.toLowerCase().endsWith('.pdf');
                final isNote = file.path.toLowerCase().endsWith('.json');
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

                    if (deleted == true) {
                      await _load();
                    }
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: isPdf
                        ? Builder(
                            builder: (context) {
                              final thumbFile = File(
                                '${file.path}.thumb.jpg',
                              );

                              return Image.file(
                                thumbFile,

                                // Reload thumbnail if it was regenerated
                                // at the same path.
                                key: ValueKey(
                                  '${thumbFile.path}#${_fileVersion(thumbFile)}',
                                ),

                                fit: BoxFit.cover,
                                cacheWidth: 200,

                                errorBuilder: (_, __, ___) {
                                  return Container(
                                    color: Colors.grey.shade200,
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.picture_as_pdf_rounded,
                                      color: Colors.red.shade400,
                                      size: 36,
                                    ),
                                  );
                                },
                              );
                            },
                          )
                        : !isNote
                            ? Image.file(
                                file,
                                fit: BoxFit.cover,
                                cacheWidth: 200,
                                errorBuilder: (_, __, ___) {
                                  return Container(
                                    color: Colors.grey.shade200,
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.insert_drive_file,
                                      color: Colors.grey,
                                    ),
                                  );
                                },
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

                                  if (snapshot.hasError ||
                                      !snapshot.hasData) {
                                    return Container(
                                      color: Colors.grey.shade100,
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.notes_outlined,
                                        size: 36,
                                        color: Colors.grey,
                                      ),
                                    );
                                  }

                                  try {
                                    final json =
                                        jsonDecode(snapshot.data!);
                                    final preview =
                                        json["preview"] ?? "";

                                    return Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        border: Border.all(
                                          color: Colors.grey.shade300,
                                          width: 1,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.all(8),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Icon(
                                            Icons.notes_outlined,
                                            size: 22,
                                            color: Colors.black54,
                                          ),
                                          const SizedBox(height: 6),
                                          Expanded(
                                            child: Text(
                                              preview.toString(),
                                              maxLines: 6,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  } catch (_) {
                                    return Container(
                                      color: Colors.grey.shade100,
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.notes_outlined,
                                        size: 36,
                                        color: Colors.grey,
                                      ),
                                    );
                                  }
                                },
                              ),
                  ),
                );
              }),

              // Show more
              if (_photos.length >= 4)
                GestureDetector(
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BrowserPage(),
                      ),
                    );

                    await _load();
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.grey.shade300,
                      ),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.more_horiz,
                          size: 28,
                          color: Colors.black87,
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Show more',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.black87,
                          ),
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
              await _confirmLogout();
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
            if (_photos.isNotEmpty) _buildSearchBar(),
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

/// OTP entry dialog used by the forgot-PIN flow. Reuses the same
/// /get-otp + /verify-otp endpoints the login screen uses, against the
/// account's already-registered email, so resetting the PIN doesn't need
/// a separate verification channel.
class _ForgotPinOtpDialog extends StatefulWidget {
  final String email;
  final Future<http.Response?> Function(
      String path,
      Map<String, dynamic> body, {
      Map<String, String>? extraHeaders,
      })
  safePost;

  const _ForgotPinOtpDialog({required this.email, required this.safePost});

  @override
  State<_ForgotPinOtpDialog> createState() => _ForgotPinOtpDialogState();
}

class _ForgotPinOtpDialogState extends State<_ForgotPinOtpDialog> {
  final _otpController = TextEditingController();
  String? _error;
  bool _verifying = false;

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _error = null;
    });

    final res = await widget.safePost('/verify-otp', {
      'email': widget.email,
      'otp': _otpController.text.trim(),
    });

    if (res == null) {
      if (!mounted) return;
      setState(() => _verifying = false);
      return;
    }

    final data = jsonDecode(res.body);
    if (data["success"] == true) {
      if (!mounted) return;
      Navigator.pop(context, true);
    } else {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = data["reason"] ?? "Incorrect OTP";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Verify your email'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Enter the OTP sent to ${widget.email}'),
          const SizedBox(height: 16),
          TextField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            decoration: InputDecoration(
              counterText: '',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
              : const Text('Verify'),
        ),
      ],
    );
  }
}