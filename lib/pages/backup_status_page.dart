// lib/pages/backup_status_page.dart
import 'package:flutter/material.dart';
import '../backup_service.dart';
import '../widgets/loading_dialog.dart';

/// Reached from Profile → "Backup Status". Shows how many of this
/// device's documents are backed up right now, how much of the account's
/// 20GB backup storage cap is used, and lets the user force an immediate
/// backup via [BackupService.backupAllNow] — which also backfills any
/// pre-existing document that predates the backup_queue table entirely
/// (see the comment on backupAllNow()).
class BackupStatusPage extends StatefulWidget {
  const BackupStatusPage({super.key});

  @override
  State<BackupStatusPage> createState() => _BackupStatusPageState();
}

class _BackupStatusPageState extends State<BackupStatusPage> {
  bool _loading = true;
  bool _runningBackup = false;
  String? _error;
  BackupStatusSummary? _summary;
  BackupUsage? _usage;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // Fetched independently, not via Future.wait: the storage-usage call
    // is a nice-to-have on this screen (it just hides the storage bar if
    // it fails), and must never turn into a full error state for a
    // screen whose main job — the backed-up/not-backed-up counts — could
    // otherwise have loaded fine.
    BackupStatusSummary? summary;
    String? error;
    try {
      summary = await BackupService.getStatus();
    } catch (e) {
      error = "Couldn't load backup status.";
    }

    BackupUsage? usage;
    try {
      usage = await BackupService.getStorageUsage();
    } catch (_) {
      // Non-fatal — the storage section just doesn't render this time.
    }

    if (!mounted) return;
    setState(() {
      _summary = summary;
      _usage = usage;
      _loading = false;
      _error = summary == null ? error : null;
    });
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> _backupAllNow() async {
    final before = _summary;
    setState(() => _runningBackup = true);
    showLoadingDialog(context, message: "Backing up your documents…");

    try {
      final summary = await BackupService.backupAllNow();

      // Best-effort refresh — a failure here shouldn't stop the summary
      // above from being shown; the storage bar just keeps its last known
      // value until the next successful load.
      BackupUsage? usage;
      try {
        usage = await BackupService.getStorageUsage();
      } catch (_) {}

      if (!mounted) return;
      hideLoadingDialog(context);
      setState(() {
        _summary = summary;
        if (usage != null) _usage = usage;
        _runningBackup = false;
      });

      if (summary.total == 0) {
        _showMessage("You don't have any documents yet.");
      } else if (summary.notBackedUp == 0) {
        _showMessage("All ${summary.total} document(s) are backed up.");
      } else {
        final justNow = before == null
            ? summary.backedUp
            : (summary.backedUp - before.backedUp).clamp(0, summary.total);
        final quotaFull = usage != null && usage.remainingBytes <= 0;
        final advice = quotaFull
            ? "You've reached your 20GB backup limit. Delete some files to "
                "free up space and try again."
            : "Check your connection and try again.";
        _showMessage(
          "${summary.backedUp} of ${summary.total} document(s) backed up"
          "${justNow > 0 ? ' ($justNow just now)' : ''} — "
          "${summary.notBackedUp} couldn't be backed up right now. $advice",
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      hideLoadingDialog(context);
      setState(() => _runningBackup = false);
      _showMessage("Backup failed. Please try again.", isError: true);
    }
  }

  Widget _buildDonut(BackupStatusSummary summary) {
    final fraction = summary.total == 0 ? 0.0 : summary.backedUp / summary.total;
    final isComplete = summary.total > 0 && summary.notBackedUp == 0;
    final ringColor = isComplete
        ? Colors.green
        : Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: 180,
      height: 180,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 180,
            height: 180,
            child: CircularProgressIndicator(
              value: fraction,
              strokeWidth: 14,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(ringColor),
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                summary.total == 0 ? "—" : "${(fraction * 100).round()}%",
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isComplete ? "All backed up" : "backed up",
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Human-readable size, e.g. "1.2 GB" / "340 MB" / "512 KB" / "0 B".
  static String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// Storage-cap bar: how much of the account's 20GB is used, and how
  /// much is left. Backed by the same figures /backup/init enforces
  /// against (BACKUP_QUOTA_BYTES in main.py), so this never shows a
  /// number the backend isn't actually acting on.
  Widget _buildStorageSection(BackupUsage usage) {
    final full = usage.remainingBytes <= 0;
    final nearlyFull = !full && usage.fraction >= 0.9;
    final barColor = full
        ? Colors.red
        : nearlyFull
            ? Colors.orange
            : Theme.of(context).colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Storage",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              Text(
                "${_formatBytes(usage.usedBytes)} of ${_formatBytes(usage.quotaBytes)}",
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: usage.fraction,
              minHeight: 10,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            full
                ? "Storage full — delete some files to back up more."
                : "${_formatBytes(usage.remainingBytes)} remaining",
            style: TextStyle(
              fontSize: 12,
              color: full ? Colors.red.shade700 : Colors.grey.shade600,
              fontWeight: full ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile({
    required String label,
    required int value,
    required IconData icon,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 8),
            Text(
              "$value",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade400, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text("Retry"),
                onPressed: _loadStatus,
              ),
            ],
          ),
        ),
      );
    }

    final summary = _summary!;
    final usage = _usage;

    return RefreshIndicator(
      onRefresh: _loadStatus,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          Center(child: _buildDonut(summary)),
          const SizedBox(height: 28),
          Row(
            children: [
              _statTile(
                label: "Total",
                value: summary.total,
                icon: Icons.description_outlined,
                color: Colors.blueGrey,
              ),
              const SizedBox(width: 10),
              _statTile(
                label: "Backed Up",
                value: summary.backedUp,
                icon: Icons.cloud_done_outlined,
                color: Colors.green,
              ),
              const SizedBox(width: 10),
              _statTile(
                label: "Not Backed Up",
                value: summary.notBackedUp,
                icon: Icons.cloud_off_outlined,
                color: summary.notBackedUp > 0 ? Colors.orange : Colors.grey,
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (usage != null) _buildStorageSection(usage),
          if (summary.notBackedUp > 0)
            Container(
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade100),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: Colors.orange.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "${summary.notBackedUp} document(s) aren't backed up "
                      "yet. Tap below to back them up now.",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _runningBackup
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(
                _runningBackup ? "Backing up…" : "Backup All Files Now",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: _runningBackup ? null : _backupAllNow,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "Documents already backed up are skipped automatically — this "
            "only uploads what's missing.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Backup Status"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh",
            onPressed: _loading ? null : _loadStatus,
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }
}