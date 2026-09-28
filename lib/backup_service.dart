import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import 'constants.dart';

// ── Per-file backup encryption ──────────────────────────────────────────
//
// Every file is encrypted (AES-256-GCM) with its own random key before it
// ever leaves the device — the bucket only ever stores ciphertext. That
// key is uploaded once, wrapped, to the backend (see /backup/init in
// main.py), which stores it in Postgres and hands the unwrapped key back
// only on an authenticated /backup/download call, so this device (or any
// other device signed into the same account) can decrypt what it pulls
// down. See encryption-system-plan.md for the full design and its
// threat model (in short: this stops a leak of the bucket ALONE from
// exposing anything readable, but the backend itself can always decrypt
// — this is not a zero-knowledge/end-to-end design).
//
// Needs the `cryptography` package on pubspec.yaml (not editable from
// here — add e.g. `cryptography: ^2.7.0` and run `flutter pub get`
// before this compiles).
final _fileCipher = AesGcm.with256bits();

/// Generates a fresh random 256-bit key — a new one every time a file is
/// (re-)uploaded, never reused across files or across re-uploads of the
/// same doc_path.
Future<SecretKey> _generateFileKey() => _fileCipher.newSecretKey();

/// Encrypts [plaintext] with [key] and returns nonce ‖ ciphertext ‖ MAC as
/// one blob — this exact blob is what gets uploaded to the bucket as the
/// object, and what a later download hands back to [_decryptFile].
Future<Uint8List> _encryptFile(Uint8List plaintext, SecretKey key) async {
  final box = await _fileCipher.encrypt(plaintext, secretKey: key);
  return Uint8List.fromList(box.concatenation());
}

/// Reverses [_encryptFile]. Throws if [key] is wrong or [envelope] was
/// corrupted/tampered with (GCM's authentication check) — callers treat
/// that the same as any other single-file restore failure.
Future<Uint8List> _decryptFile(Uint8List envelope, SecretKey key) async {
  final box = SecretBox.fromConcatenation(
    envelope,
    nonceLength: 12,
    macLength: 16,
  );
  final plaintext = await _fileCipher.decrypt(box, secretKey: key);
  return Uint8List.fromList(plaintext);
}

// ── Backup: local queue + OS-scheduled uploader ────────────────────────────
//
// Scope of this file (deliberately narrow — see the comments at each piece):
//   1. registerPendingBackup(docPath) — called right after a document/note
//      is successfully created, so it's queued for backup.
//   2. markDeleted(docPath) — called right after a document is deleted, so
//      it (a) is dropped from the local queue and (b) is flagged
//      deleted_at on the backend via POST /backup/delete.
//   3. The actual upload work (queue → /backup/init → PUT bytes →
//      /backup/complete) runs as an Android WorkManager background task,
//      not on the UI thread and not tied to the screen being open.
//
// Everything else from backup-system-plan.md (restore, storage-limit UI,
// night/network gating, reconciliation) is intentionally NOT here yet.

/// Unique WorkManager task name used both for the periodic sync and for the
/// immediate one-off kicked whenever something new is queued.
const String backupSyncTaskName = 'docezy-backup-sync';

/// Unique name for the periodic registration (registerPeriodicTask needs a
/// name that's stable across app restarts so it isn't re-registered as a
/// duplicate every launch).
const String _backupPeriodicUniqueName = 'docezy-backup-periodic';

/// Unique name for the "run right now" one-off task. Kept as a single
/// constant (instead of one per doc_path), paired with
/// ExistingWorkPolicy.keep (see registerPendingBackup below) — NOT
/// .replace. .replace cancels/kills an already-*running* task with this
/// name, which was cutting a batch upload off mid-file when two imports
/// happened in quick succession (e.g. picking 2 images at once): the
/// first task would be midway through uploading the second document in
/// its queue when the second import's registerOneOffTask call replaced
/// it, truncating that upload — sometimes before the PUT to the bucket
/// finished (object never lands, row stuck 'pending'), sometimes right
/// after it finished but before /backup/complete could run (object *is*
/// in the bucket, but the row still shows 'pending' forever). With
/// .keep, a request that arrives while a sync is already
/// enqueued/running just doesn't schedule a second one — the one already
/// running (or about to) queries the local queue at execution time, not
/// at scheduling time, so it still picks up every doc queued before it
/// actually starts.
const String _backupImmediateUniqueName = 'docezy-backup-immediate';

/// Secure-storage key for the "Automatic Backup" toggle on Profile.
/// Stored as the string 'true'/'false' via the shared `storage`
/// (FlutterSecureStorage) from constants.dart — same pattern PinService
/// uses for its own on/off flags. See [BackupService.isAutoBackupEnabled]
/// for what "absent" means.
const String _kAutoBackupEnabledKey = 'auto_backup_enabled';

/// How often the OS runs the periodic sync.
///
/// TESTING (current value): Android's WorkManager enforces a hard 15-minute
/// minimum for periodic work — there's no true "run instantly, repeatedly"
/// option at the OS level, so 15 minutes is as close to "anytime" as it
/// gets for the recurring job. registerPendingBackup() below also fires an
/// immediate one-off task on top of this, so in practice a newly-created
/// document gets backed up within seconds during testing, not up to 15
/// minutes later.
///
/// PRODUCTION: change this single constant to `Duration(hours: 12)` when
/// shifting to the real schedule. Nothing else needs to change.
const Duration backupSyncInterval = Duration(minutes: 15);

/// WorkManager's top-level entry point. Must stay a top-level (or static)
/// function annotated with `@pragma('vm:entry-point')` — WorkManager runs
/// this in a separate background isolate with no access to any app state,
/// which is why BackupService only ever talks to sqflite + the network,
/// never to any widget/controller state.
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // This line firing at all in logcat (filter for "BackupService:") is
    // the proof the OS actually invoked the background task — if you
    // never see it after registering a backup, the task isn't running
    // yet (still queued by the OS, or blocked by battery/network state),
    // as opposed to running and failing silently.
    debugPrint('BackupService: WorkManager task fired ($task)');
    if (task == backupSyncTaskName) {
      try {
        if (await BackupService.isAutoBackupEnabled()) {
          await BackupService.runPendingBackups();
        } else {
          debugPrint(
            'BackupService: automatic backup is off — skipping scheduled sync',
          );
        }
      } catch (e) {
        // Swallow it — WorkManager already retries a failed task on its
        // own backoff policy, and runPendingBackups() itself marks
        // individual rows 'failed' so the next run only retries those.
        debugPrint('BackupService: runPendingBackups threw: $e');
      }
    }
    return Future.value(true);
  });
}

class BackupService {
  BackupService._();

  static Database? _database;

  static Future<Database> _db() async {
    if (_database != null) return _database!;
    final dbPath = p.join(await getDatabasesPath(), 'backup_queue.db');
    _database = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) => db.execute('''
        CREATE TABLE backup_queue (
          doc_path TEXT PRIMARY KEY,
          backup_id TEXT,
          status TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          updated_at TEXT NOT NULL
        )
      '''),
    );
    return _database!;
  }

  /// True once Workmanager().initialize() has actually completed in this
  /// process. Guards registerPendingBackup() below: the native plugin
  /// refuses registerOneOffTask()/registerPeriodicTask() calls until its
  /// own initialize() has run in the *current* process — which, notably,
  /// a hot *reload* does NOT re-trigger (only main() re-running via a full
  /// restart/relaunch does), so this flag staying false after a reload is
  /// expected, not a bug to chase.
  static bool _initialized = false;

  /// Call once at app startup (main()), before runApp(). Registers the
  /// callback dispatcher with the OS and schedules the recurring sync.
  /// existingWorkPolicy: keep means re-launching the app doesn't reset or
  /// duplicate the already-scheduled periodic job.
  ///
  /// Note: registerPeriodicTask takes ExistingPeriodicWorkPolicy, a
  /// separate enum from the ExistingWorkPolicy used by registerOneOffTask
  /// below (workmanager 0.10.x split them) — same three values
  /// (keep/replace/update), just two distinct types now.
  static Future<void> initialize() async {
    try {
      await Workmanager().initialize(backupCallbackDispatcher);
      _initialized = true;
      debugPrint('BackupService: Workmanager initialized');
      await Workmanager().registerPeriodicTask(
        _backupPeriodicUniqueName,
        backupSyncTaskName,
        frequency: backupSyncInterval,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
      debugPrint('BackupService: periodic sync registered (every $backupSyncInterval)');
    } catch (e) {
      // Never let a scheduling hiccup here block app startup — runApp()
      // must still happen. Anything queued locally via
      // registerPendingBackup() while uninitialized just waits for the
      // next successful initialize() (next full app launch) to be synced.
      debugPrint('BackupService: initialize failed: $e');
    }
  }

  // ── Automatic backup toggle (Profile → Automatic Backup) ────────────────
  //
  // A single on/off switch, persisted in the same secure storage used
  // everywhere else in this app (see constants.dart's `storage`). It only
  // gates the *automatic* path — new documents getting queued
  // (registerPendingBackup) and the periodic/immediate WorkManager sync
  // actually uploading (backupCallbackDispatcher above). It deliberately
  // does not touch explicit, user-initiated actions elsewhere (e.g.
  // "Backup All Now" on the Backup Status screen, or restore) — those are
  // a one-off request the user just made, not the automatic background
  // behaviour this switch controls.

  /// Whether automatic backup is currently turned on. Nothing stored yet
  /// (a fresh install, or an existing install that predates this toggle)
  /// is treated as enabled, so introducing this switch doesn't silently
  /// stop backing up anyone's documents — it only takes effect once a
  /// user actually flips it off.
  static Future<bool> isAutoBackupEnabled() async {
    final value = await storage.read(key: _kAutoBackupEnabledKey);
    return value != 'false';
  }

  /// Turns automatic backup on/off and persists the choice. Safe to call
  /// as often as the user flips the switch — it only ever writes this one
  /// key.
  static Future<void> setAutoBackupEnabled(bool enabled) async {
    await storage.write(
      key: _kAutoBackupEnabledKey,
      value: enabled.toString(),
    );
    debugPrint(
      'BackupService: automatic backup turned ${enabled ? 'on' : 'off'}',
    );
  }

  /// Queue doc_path for backup. Safe to call again for the same doc_path
  /// (e.g. a note that gets edited and re-saved at its existing path) —
  /// it just resets that row back to 'pending'.
  static Future<void> registerPendingBackup(String docPath) async {
    if (!await isAutoBackupEnabled()) {
      debugPrint(
        'BackupService: automatic backup is off — not queuing $docPath',
      );
      return;
    }

    final db = await _db();
    await db.insert(
      'backup_queue',
      {
        'doc_path': docPath,
        'backup_id': null,
        'status': 'pending',
        'attempts': 0,
        'last_error': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    debugPrint('BackupService: queued $docPath for backup');

    // Kick a sync off right away instead of waiting for the next periodic
    // tick — this is the "run anytime, for testing" behaviour. Requires
    // network to actually succeed, same as any upload would.
    //
    // Best-effort: registering this immediate task is purely an
    // optimization (the periodic task will pick the row up regardless),
    // so a failure here — e.g. WorkManager not yet initialized in this
    // process, see _initialized above — must never propagate up through
    // storeEmbedding()/importFromPath() and break the document import
    // itself.
    if (!_initialized) {
      debugPrint(
        'BackupService: WorkManager not initialized yet in this process — '
        '$docPath stays queued and will be picked up by the next periodic '
        'sync after a full app restart.',
      );
      return;
    }
    try {
      await Workmanager().registerOneOffTask(
        _backupImmediateUniqueName,
        backupSyncTaskName,
        // keep, not replace — see the comment on _backupImmediateUniqueName.
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
      debugPrint('BackupService: immediate sync task scheduled with the OS');
    } catch (e) {
      debugPrint('BackupService: failed to schedule immediate sync: $e');
    }
  }

  /// Call right after a document is deleted from disk. Drops it from the
  /// local queue (so the background worker never tries to back up a file
  /// that no longer exists) and tells the backend to soft-delete any
  /// backup row for it (sets deleted_at — see POST /backup/delete).
  ///
  /// Fire-and-forget on the network call, matching this app's existing
  /// /delete-document convention elsewhere in the codebase: the file is
  /// already gone from the device either way, so there's nothing to roll
  /// back to if this particular request doesn't land.
  static Future<void> markDeleted(String docPath) async {
    final db = await _db();
    await db.delete('backup_queue', where: 'doc_path = ?', whereArgs: [docPath]);

    final token = await storage.read(key: 'token');
    if (token == null) return;

    // Not awaited on purpose (fire-and-forget, matching /delete-document's
    // own convention elsewhere) — but still logged via .then/.catchError
    // so failures are visible without slowing down the delete flow.
    http
        .post(
          Uri.parse('$baseUrl/backup/delete'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'doc_path': dbPath(docPath)}),
        )
        .then((res) {
          debugPrint(
            'BackupService: backup/delete for $docPath -> ${res.statusCode}',
          );
        })
        .catchError((e) {
          debugPrint('BackupService: backup/delete for $docPath failed: $e');
        });
  }

  static String _contentTypeFor(String docPath) {
    switch (p.extension(docPath).toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }

  /// Drains everything in the local queue that isn't already uploaded:
  /// for each doc_path, POST /backup/init to get a presigned upload URL,
  /// PUT the file's bytes straight to the bucket, then POST
  /// /backup/complete to flip its status server-side. This is what the
  /// WorkManager task above actually runs.
  static Future<void> runPendingBackups() async {
    final token = await storage.read(key: 'token');
    if (token == null) {
      debugPrint('BackupService: runPendingBackups skipped — not logged in');
      return;
    }

    final db = await _db();
    // 'uploading' is included here too: a row only ever sits at
    // 'uploading' locally while a run is actively working on it (see the
    // db.update right below), so if we find one *at the start* of a run,
    // it can only mean a previous run got killed mid-upload — the OS
    // stopping the background task early (Doze, memory pressure,
    // force-stop) rather than letting it reach the try/catch's success
    // or failure branch. Without retrying those too, such a row would be
    // silently stuck forever, retried by neither 'pending' nor 'failed'.
    final rows = await db.query(
      'backup_queue',
      where: "status = 'pending' OR status = 'failed' OR status = 'uploading'",
    );
    debugPrint('BackupService: runPendingBackups — ${rows.length} row(s) to sync');

    for (final row in rows) {
      final docPath = row['doc_path'] as String;
      final file = File(docPath);

      if (!await file.exists()) {
        // Deleted without going through markDeleted (shouldn't normally
        // happen since every delete call site is wired to it) — drop it
        // rather than retrying forever against a file that's gone.
        await db.delete('backup_queue', where: 'doc_path = ?', whereArgs: [docPath]);
        continue;
      }

      try {
        await db.update(
          'backup_queue',
          {'status': 'uploading', 'updated_at': DateTime.now().toIso8601String()},
          where: 'doc_path = ?',
          whereArgs: [docPath],
        );

        final plaintextBytes = await file.readAsBytes();
        final contentType = _contentTypeFor(docPath);

        // Encrypt before any of this leaves the device — the bucket
        // never sees plaintext. Fresh key every time, including a
        // re-upload of the same doc_path (an edited note re-saved at its
        // existing path, say), so re-saving something never reuses an
        // old key.
        final fileKey = await _generateFileKey();
        final bytes = await _encryptFile(plaintextBytes, fileKey);
        final fileKeyB64 = base64Encode(await fileKey.extractBytes());

        final initRes = await http
            .post(
              Uri.parse('$baseUrl/backup/init'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({
                'doc_path': dbPath(docPath),
                'content_type': contentType,
                'size': bytes.length,
                'file_key': fileKeyB64,
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (initRes.statusCode != 200) {
          throw Exception('backup/init failed (${initRes.statusCode})');
        }
        final initData = jsonDecode(initRes.body) as Map<String, dynamic>;
        if(initData["success"] == false) {
          if (initData['reason'] == 'quota_exceeded') {
            // Account is at (or would exceed) its 20GB backup cap — this
            // file is perfectly fine, it just doesn't fit right now.
            // Unlike the orphan-file case below, never delete the local
            // file or drop the queue row over this: mark it 'failed'
            // (same status/shape as any other retryable upload problem,
            // so it's picked up again automatically once the account is
            // back under the cap — e.g. after the user deletes something
            // or a "Backup All Now" retry) and move on to the next file.
            final attempts = (row['attempts'] as int? ?? 0) + 1;
            await db.update(
              'backup_queue',
              {
                'status': 'failed',
                'attempts': attempts,
                'last_error':
                    'Storage limit reached (20GB) — free up space to resume backups.',
                'updated_at': DateTime.now().toIso8601String(),
              },
              where: 'doc_path = ?',
              whereArgs: [docPath],
            );
            debugPrint(
              'BackupService: $docPath not backed up — storage quota exceeded',
            );
            continue;
          }
          // Orphan/malicious-file guard (backup-system-plan.md §11) —
          // unchanged: this doc_path has no docs-table row at all, so the
          // file itself doesn't belong and is dropped for good.
          await db.delete('backup_queue', where: 'doc_path = ?', whereArgs: [docPath]);
          if(await File(docPath).exists()) {
            await File(docPath).delete();
          }
          continue;
        }
        final backupId = initData['backup_id'] as String;
        final uploadUrl = initData['upload_url'] as String;
        final putRes = await http
            .put(
              Uri.parse(uploadUrl),
              headers: {'Content-Type': contentType},
              body: bytes,
            )
            .timeout(const Duration(minutes: 5));

        if (putRes.statusCode < 200 || putRes.statusCode >= 300) {
          throw Exception('upload to bucket failed (${putRes.statusCode})');
        }

        final completeRes = await http
            .post(
              Uri.parse('$baseUrl/backup/complete'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({'backup_id': backupId}),
            )
            .timeout(const Duration(seconds: 30));

        if (completeRes.statusCode != 200) {
          throw Exception('backup/complete failed (${completeRes.statusCode})');
        }

        await db.update(
          'backup_queue',
          {
            'backup_id': backupId,
            'status': 'uploaded',
            'last_error': null,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'doc_path = ?',
          whereArgs: [docPath],
        );
        debugPrint('BackupService: uploaded $docPath (backup_id=$backupId)');
      } catch (e) {
        final attempts = (row['attempts'] as int? ?? 0) + 1;
        await db.update(
          'backup_queue',
          {
            'status': 'failed',
            'attempts': attempts,
            'last_error': e.toString(),
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'doc_path = ?',
          whereArgs: [docPath],
        );
        debugPrint('BackupService: FAILED to upload $docPath (attempt $attempts): $e');
      }
    }
  }

  // ── Backup status (Profile → Backup Status) ─────────────────────────────
  //
  // Lists every document file currently on this device (mirrors the same
  // file-listing filter BrowserPage/_load() uses to decide what counts as
  // a "document") and cross-checks each against the BACKEND's `backups`
  // table — not the local backup_queue — to report how many are backed
  // up.
  //
  // Deliberately not using backup_queue for this: it's a local sqflite
  // table with no server counterpart, so it's wiped by an uninstall, a
  // "clear app data", or clearLocalAccountData() on logout. A device that
  // just reinstalled the app would show 0 backed up for every file even
  // though the backend still has them all — which is exactly backwards
  // for a screen whose entire point is "can I safely lose this device".
  // The `backups` table in Postgres is the only durable record of what's
  // actually been uploaded, so that's what this queries, over the
  // network, every time. Slower than a local read, but correctness here
  // matters more than speed — a network round trip is an acceptable cost
  // for a screen the user opens deliberately, not one on a hot path.

  /// Same filter as BrowserPage._load(): every real document/note file in
  /// the documents directory, excluding profile pictures and PDF
  /// thumbnails, and requiring the numeric (millis-since-epoch) filename
  /// stem every real document/note is saved under.
  static Future<List<File>> _listDocumentFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    if (!await dir.exists()) return [];
    final numericName = RegExp(r'^\d+$');
    return dir.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path);
      if (name.startsWith('profile_')) return false;
      if (name.endsWith('.thumb.jpg')) return false;
      final stem = p.basenameWithoutExtension(name);
      if (!numericName.hasMatch(stem)) return false;
      if (name.endsWith('.pdf')) return true;
      if (name.endsWith('.json')) return true;
      return name.endsWith('.jpg') || name.endsWith('.png');
    }).toList();
  }

  /// Every filename (basename, not full doc_path — see _localRestorePath's
  /// comment on why the two can differ across devices/reinstalls even for
  /// the "same" file) this account has a status='uploaded', non-deleted
  /// row for in the backend's `backups` table right now. This is the
  /// single source of truth for "is this file backed up" — nothing local
  /// is consulted.
  static Future<Set<String>> _fetchBackedUpFilenames() async {
    final token = await storage.read(key: 'token');
    if (token == null) {
      throw Exception('Not logged in');
    }

    final res = await http
        .post(
          Uri.parse('$baseUrl/backup/list'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      throw Exception('backup/list failed (${res.statusCode})');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final rows = (data['results'] as List).cast<Map<String, dynamic>>();
    return {for (final row in rows) p.basename(row['doc_path'] as String)};
  }

  /// Scans this device's documents directory and asks the backend which
  /// of those files it already has an uploaded backup for. Read-only —
  /// doesn't touch the local queue or write anything — but it does hit
  /// the network, so it can throw (no connection, not logged in, server
  /// error); callers should show a retry state on failure rather than a
  /// stale/misleading count.
  static Future<BackupStatusSummary> getStatus() async {
    final files = await _listDocumentFiles();
    final backedUpNames = await _fetchBackedUpFilenames();
    final total = files.length;
    final backedUp = files
        .where((f) => backedUpNames.contains(p.basename(f.path)))
        .length;
    return BackupStatusSummary(
      total: total,
      backedUp: backedUp,
      notBackedUp: total - backedUp,
    );
  }

  /// This account's usage against the 20GB backup cap enforced in
  /// /backup/init (see BACKUP_QUOTA_BYTES in main.py). Powers the storage
  /// bar on the Backup Status screen. Throws the same way getStatus()
  /// does (no connection / not logged in / server error) — callers
  /// should show a retry state rather than a stale figure.
  static Future<BackupUsage> getStorageUsage() async {
    final token = await storage.read(key: 'token');
    if (token == null) {
      throw Exception('Not logged in');
    }

    final res = await http
        .post(
          Uri.parse('$baseUrl/backup/usage'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      throw Exception('backup/usage failed (${res.statusCode})');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return BackupUsage(
      usedBytes: (data['used_bytes'] as num).toInt(),
      quotaBytes: (data['quota_bytes'] as num).toInt(),
      remainingBytes: (data['remaining_bytes'] as num).toInt(),
    );
  }

  /// "Backup All Files Now" on the Backup Status screen. Three steps:
  ///
  /// 1. Ask the backend which files are already backed up (same call as
  ///    getStatus()) — this is what makes the next step correct even
  ///    right after a reinstall, when the local backup_queue is empty for
  ///    every file, backed up or not.
  /// 2. Reconciliation: any local document file that (a) isn't backed up
  ///    per the backend AND (b) has no row at all in backup_queue yet
  ///    gets backfilled as a fresh 'pending' row — exactly like a
  ///    brand-new document would be. This is the "previous version user"
  ///    case: a file imported before registerPendingBackup() existed
  ///    (its docs-table row already exists server-side, since import has
  ///    always called /send-document synchronously, but its *file* was
  ///    never queued for backup) as well as the "reinstalled the app"
  ///    case for anything that genuinely was never uploaded. A file
  ///    that's already in the queue with status 'failed' (including a
  ///    previous 'quota_exceeded' failure — see runPendingBackups above)
  ///    is left alone here rather than reset — step 3 already retries
  ///    every 'pending'/'failed'/'uploading' row, so no special-casing is
  ///    needed to give a quota-blocked file another attempt once the
  ///    user has freed up space and taps this button again.
  /// 3. Runs the upload pass synchronously (awaited in the foreground,
  ///    not scheduled as a background WorkManager task) so the caller can
  ///    show a blocking loading dialog for the duration, then re-queries
  ///    the backend once more via getStatus() so the returned summary
  ///    reflects what actually landed.
  ///
  /// This is a deliberate, explicit user action (the user tapped "Backup
  /// All Now"), so — unlike registerPendingBackup()/the scheduled sync —
  /// it always runs, whether or not the Automatic Backup switch on
  /// Profile is on.
  static Future<BackupStatusSummary> backupAllNow() async {
    final files = await _listDocumentFiles();
    final backedUpNames = await _fetchBackedUpFilenames();

    final db = await _db();
    final existingRows = await db.query('backup_queue', columns: ['doc_path']);
    final knownLocally = existingRows.map((r) => r['doc_path'] as String).toSet();

    for (final file in files) {
      if (backedUpNames.contains(p.basename(file.path))) {
        // Backend already has this one — never mind what the local queue
        // says (or doesn't say); nothing to do.
        continue;
      }
      if (knownLocally.contains(file.path)) {
        // Already tracked locally (pending/failed/uploading) —
        // runPendingBackups() below will pick it up on its own.
        continue;
      }
      await db.insert(
        'backup_queue',
        {
          'doc_path': file.path,
          'backup_id': null,
          'status': 'pending',
          'attempts': 0,
          'last_error': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      debugPrint(
        'BackupService: backfilled legacy document ${file.path} into backup_queue',
      );
    }

    await runPendingBackups();
    return getStatus();
  }

  // ── Retrieval (restore) ──────────────────────────────────────────────
  //
  // The "Retrieve Backup" row on Profile: check what's in the backend's
  // backups but missing from this device, show the user that count, and
  // — once they confirm — download and write each one back. Per
  // backup-system-plan.md §1/§4, this never has to touch the search
  // index (docs/doc_words rows were never lost — they live in Postgres,
  // independent of any device), so restoring is just "put the bytes
  // back at the right local path" plus a PDF thumbnail regen.
  //
  // This runs in the foreground, driven by an explicit user tap — unlike
  // upload, it's not a WorkManager background job.

  /// Where a restored file for [docPath] belongs *on this device*: not
  /// necessarily the literal string stored server-side (which could be a
  /// different device's absolute path, e.g. a secondary Android user
  /// profile with a different sandbox index), but that same filename
  /// rebuilt against this device's current documents directory.
  static Future<String> _localRestorePath(String docPath) async {
    final documentsDir = await getApplicationDocumentsDirectory();
    return p.join(documentsDir.path, p.basename(docPath));
  }

  /// Returns every backup row (as POST /backup/list returns them —
  /// backup_id, doc_path, content_type, size_bytes, uploaded_at, ...)
  /// whose file isn't present on this device right now. Read-only: this
  /// doesn't download anything or touch the local upload queue, just
  /// answers "what's new".
  static Future<List<Map<String, dynamic>>> checkForRestorableBackups() async {
    final token = await storage.read(key: 'token');
    if (token == null) return [];

    final res = await http
        .post(
          Uri.parse('$baseUrl/backup/list'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      throw Exception('backup/list failed (${res.statusCode})');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final rows = (data['results'] as List).cast<Map<String, dynamic>>();

    final missing = <Map<String, dynamic>>[];
    for (final row in rows) {
      final localPath = await _localRestorePath(row['doc_path'] as String);
      if (!await File(localPath).exists()) {
        missing.add(row);
      }
    }
    return missing;
  }

  /// Downloads and writes each of [rows] (from checkForRestorableBackups())
  /// back onto this device. Best-effort per row — one failure doesn't stop
  /// the rest — with the tally returned so the caller can report it.
  static Future<BackupRetrieveResult> retrieveBackups(
    List<Map<String, dynamic>> rows, {
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final token = await storage.read(key: 'token');
    if (token == null) {
      return BackupRetrieveResult(succeeded: 0, failed: rows.length);
    }

    int succeeded = 0;
    int failed = 0;

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final docPath = row['doc_path'] as String;
      final backupId = row['backup_id'] as String;
      final name = p.basename(docPath);
      onProgress?.call(i, rows.length, name);

      try {
        final downloadRes = await http
            .post(
              Uri.parse('$baseUrl/backup/download'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({'backup_id': backupId}),
            )
            .timeout(const Duration(seconds: 30));

        if (downloadRes.statusCode != 200) {
          throw Exception('backup/download failed (${downloadRes.statusCode})');
        }
        final downloadData = jsonDecode(downloadRes.body) as Map<String, dynamic>;
        final downloadUrl = downloadData['download_url'] as String;
        // Present for anything uploaded after encryption shipped; null
        // for a legacy backup uploaded before that (its bytes are
        // already plaintext — see main.py's backup_download).
        final fileKeyB64 = downloadData['file_key'] as String?;

        final fileRes = await http
            .get(Uri.parse(downloadUrl))
            .timeout(const Duration(minutes: 5));
        if (fileRes.statusCode < 200 || fileRes.statusCode >= 300) {
          throw Exception('download from bucket failed (${fileRes.statusCode})');
        }

        Uint8List fileBytes = fileRes.bodyBytes;
        if (fileKeyB64 != null) {
          final key = SecretKeyData(base64Decode(fileKeyB64));
          fileBytes = await _decryptFile(fileBytes, key);
        }

        final destPath = await _localRestorePath(docPath);
        await File(destPath).writeAsBytes(fileBytes);

        if (name.toLowerCase().endsWith('.pdf')) {
          await _restorePdfThumb(destPath);
        }

        succeeded++;
        debugPrint('BackupService: restored $destPath');
      } catch (e) {
        failed++;
        debugPrint('BackupService: failed to restore $docPath: $e');
      }
    }

    onProgress?.call(rows.length, rows.length, '');
    return BackupRetrieveResult(succeeded: succeeded, failed: failed);
  }

  /// Best-effort thumbnail regen for a restored PDF — mirrors
  /// StoreService.makePdfThumb but swallows its own errors, since a
  /// missing thumbnail just falls back to the grid's default PDF icon
  /// and must never fail the whole restore over it.
  static Future<void> _restorePdfThumb(String pdfPath) async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(
        pdfPath,
      ).timeout(const Duration(seconds: 10));
      final page = await doc.getPage(1);
      final img = await page.render(width: page.width, height: page.height);
      await page.close();
      if (img == null || img.bytes.isEmpty) return;
      await File('$pdfPath.thumb.jpg').writeAsBytes(img.bytes);
    } catch (e) {
      debugPrint('BackupService: thumbnail regen failed for $pdfPath: $e');
    } finally {
      await doc?.close();
    }
  }

  // ── Account lifecycle: logout wipe + login auto-restore ────────────────
  //
  // Neither of these is gated on the "one account per phone" invariant
  // being fully built out (see backup-system-plan.md §11) — they're the
  // two concrete pieces of it that make it safe *today*: logging out
  // clears this device's copy of the account's files (so a different
  // account signing in next can never see them), and logging in quietly
  // pulls the signed-in account's files back down in the background.

  /// Called right after login succeeds (OTP or Google) — deliberately
  /// NOT awaited by the caller, so app startup/navigation never waits on
  /// this. Runs the same check-then-download logic as "Retrieve Backup"
  /// on Profile, just automatically and silently: no confirmation dialog,
  /// no progress UI, only debugPrint logging. If it fails or misses
  /// something, Retrieve Backup remains the user-visible fallback to
  /// check and retry — this is a convenience, not the only path to a
  /// restored account.
  static Future<void> autoRestoreAfterLogin() async {
    try {
      final missing = await checkForRestorableBackups();
      if (missing.isEmpty) {
        debugPrint('BackupService: autoRestoreAfterLogin — nothing to restore');
        return;
      }
      debugPrint(
        'BackupService: autoRestoreAfterLogin — restoring ${missing.length} '
        'file(s) in the background',
      );
      final result = await retrieveBackups(missing);
      debugPrint(
        'BackupService: autoRestoreAfterLogin done — '
        '${result.succeeded} restored, ${result.failed} failed',
      );
    } catch (e) {
      debugPrint('BackupService: autoRestoreAfterLogin failed: $e');
    }
  }

  /// Called on logout. Deletes every file in this device's permanent
  /// documents directory (imported documents/notes, thumbnails, the
  /// profile picture, any leftover temp files) and clears the local
  /// upload queue — none of that is destructive server-side, since
  /// everything here was already backed up or still queued to be, and
  /// signing back into this same account (here or on another device)
  /// brings it all back via autoRestoreAfterLogin()/Retrieve Backup.
  ///
  /// This exists because the documents directory isn't namespaced per
  /// account (see backup-system-plan.md §11): at most one account's
  /// files can safely sit there at a time, and logout is the point where
  /// this device stops being "owned" by this account.
  static Future<void> clearLocalAccountData() async {
    try {
      // Close and forget the cached DB first
      try {
        await _database?.close();
      } catch (_) {}
      _database = null;

      final dir = await getApplicationDocumentsDirectory();
      final numeric = RegExp(r'^\d+$');

      for (final entry in dir.listSync().whereType<File>()) {
        final name = p.basename(entry.path);

        // Never touch sqflite files (they live in Documents on iOS)
        if (name.endsWith('.db') ||
            name.endsWith('.db-journal') ||
            name.endsWith('.db-wal') ||
            name.endsWith('.db-shm')) {
          continue;
        }

        final isProfile = name.startsWith('profile_');
        final isThumb = name.endsWith('.thumb.jpg');
        final isDoc = numeric.hasMatch(p.basenameWithoutExtension(name));
        if (!(isProfile || isThumb || isDoc)) continue;

        try {
          await entry.delete();
        } catch (e) {
          debugPrint('BackupService: failed to delete ${entry.path}: $e');
        }
      }

      final db = await _db(); // reopens cleanly
      await db.delete('backup_queue');
    } catch (e) {
      debugPrint('BackupService: clearLocalAccountData failed: $e');
    }
  }
}

/// Outcome of a retrieveBackups() call — how many of the requested files
/// actually made it back onto the device.
class BackupRetrieveResult {
  final int succeeded;
  final int failed;
  const BackupRetrieveResult({required this.succeeded, required this.failed});
}

/// Snapshot for the Backup Status screen: how many document files exist on
/// this device right now, and how many of those currently have a
/// status='uploaded' row in the local backup_queue.
class BackupStatusSummary {
  final int total;
  final int backedUp;
  final int notBackedUp;
  const BackupStatusSummary({
    required this.total,
    required this.backedUp,
    required this.notBackedUp,
  });
}

/// This account's usage against the 20GB backup cap (BACKUP_QUOTA_BYTES
/// in main.py, enforced in /backup/init and reported by /backup/usage).
class BackupUsage {
  final int usedBytes;
  final int quotaBytes;
  final int remainingBytes;
  const BackupUsage({
    required this.usedBytes,
    required this.quotaBytes,
    required this.remainingBytes,
  });

  /// 0.0–1.0, clamped — a defensive clamp against the edge case where
  /// usedBytes could momentarily read fractionally over quotaBytes (a
  /// race between two concurrent uploads finishing right at the cap)
  /// rather than ever showing a progress bar over 100%. Written as an
  /// explicit if/else rather than num.clamp() — num.clamp() returns
  /// `num`, not `double`, which doesn't satisfy this getter's return
  /// type without an extra cast.
  double get fraction {
    if (quotaBytes <= 0) return 0.0;
    final f = usedBytes / quotaBytes;
    if (f < 0.0) return 0.0;
    if (f > 1.0) return 1.0;
    return f;
  }
}