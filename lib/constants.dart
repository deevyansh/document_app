import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

const storage = FlutterSecureStorage(); // renamed from _storage (no underscore)
const baseUrl = "https://document-backend-302452809509.asia-south1.run.app";

enum AppStage { enterEmail, enterOtp, document, QueryScreen }

enum ProfilePageAction { deleteaccount, logout }

enum DocumentTypeFilter { all, image, pdf }
enum ScanMode { images, pdf, idCard }

const caption = '''
This document is smartly shared from 𝐃𝐨𝐜𝐄𝐳𝐲.
''';

const MethodChannel methodChannel = MethodChannel('document_app/widget');
