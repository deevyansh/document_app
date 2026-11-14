import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const storage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
  ),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
    synchronizable: false, // very important
  ),
);

const baseUrl = "https://container-service-1.tz0d7y44qkv7e.ap-south-1.cs.amazonlightsail.com";

enum AppStage { enterEmail, enterOtp, document, QueryScreen}

enum ProfilePageAction { deleteaccount, logout }

const adminEmail = "devkhadria@gmail.com";

enum DocumentTypeFilter { all, image, pdf }
enum ScanMode { images, pdf, idCard }

const caption = '''
This document is smartly shared from 𝐃𝐨𝐜𝐄𝐳𝐲.
''';

const MethodChannel methodChannel = MethodChannel('document_app/widget');

/// What we store in the server DB for a local file.
/// Android: full path (unchanged). iOS: filename only, because the
/// container UUID in the full path changes on reinstall/restore.
String dbPath(String localPath) =>
    Platform.isIOS ? p.basename(localPath) : localPath;

/// Turns a server-stored doc_path back into a real local File.
/// Android: used as-is (unchanged). iOS: filename joined onto the
/// current Documents dir, which also fixes old full-path rows.
Future<File> localDoc(String serverPath) async {
  if (!Platform.isIOS) return File(serverPath);
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, p.basename(serverPath)));
}