import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const storage = FlutterSecureStorage();   // renamed from _storage (no underscore)
const baseUrl = "https://document-backend-302452809509.asia-south1.run.app";

enum AppStage { enterEmail, enterOtp, document, QueryScreen }
enum ProfilePageAction { deleteaccount, logout }
enum DocumentTypeFilter { all, image, pdf }

const caption = '''
This document is smartly shared from 𝐃𝐨𝐜𝐄𝐳𝐲.
''';