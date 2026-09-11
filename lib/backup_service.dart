import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import 'constants.dart';

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
        await BackupService.runPendingBackups();
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

  /// Queue doc_path for backup. Safe to call again for the same doc_path
  /// (e.g. a note that gets edited and re-saved at its existing path) —
  /// it just resets that row back to 'pending'.
  static Future<void> registerPendingBackup(String docPath) async {
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
      body: jsonEncode({'doc_path': docPath}),
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

        final bytes = await file.readAsBytes();
        final contentType = _contentTypeFor(docPath);

        final initRes = await http
            .post(
          Uri.parse('$baseUrl/backup/init'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'doc_path': docPath,
            'content_type': contentType,
            'size': bytes.length,
          }),
        )
            .timeout(const Duration(seconds: 30));

        if (initRes.statusCode != 200) {
          throw Exception('backup/init failed (${initRes.statusCode})');
        }
        final initData = jsonDecode(initRes.body) as Map<String, dynamic>;
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
        final downloadUrl =
        (jsonDecode(downloadRes.body) as Map<String, dynamic>)['download_url']
        as String;

        final fileRes = await http
            .get(Uri.parse(downloadUrl))
            .timeout(const Duration(minutes: 5));
        if (fileRes.statusCode < 200 || fileRes.statusCode >= 300) {
          throw Exception('download from bucket failed (${fileRes.statusCode})');
        }

        final destPath = await _localRestorePath(docPath);
        await File(destPath).writeAsBytes(fileRes.bodyBytes);

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
}

/// Outcome of a retrieveBackups() call — how many of the requested files
/// actually made it back onto the device.
class BackupRetrieveResult {
  final int succeeded;
  final int failed;
  const BackupRetrieveResult({required this.succeeded, required this.failed});
}