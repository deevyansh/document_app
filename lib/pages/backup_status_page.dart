// lib/pages/backup_status_page.dart
import 'package:flutter/material.dart';
import '../backup_service.dart';
import '../widgets/loading_dialog.dart';

/// Reached from Profile → "Backup Status". Shows how many of this
/// device's documents are backed up right now, and lets the user force an
/// immediate backup via [BackupService.backupAllNow] — which also
/// backfills any pre-existing document that predates the backup_queue
/// table entirely (see the comment on backupAllNow()).
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
    try {
      final summary = await BackupService.getStatus();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load backup status.";
      });
    }
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
      if (!mounted) return;
      hideLoadingDialog(context);
      setState(() {
        _summary = summary;
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
        _showMessage(
          "${summary.backedUp} of ${summary.total} document(s) backed up"
          "${justNow > 0 ? ' ($justNow just now)' : ''} — "
          "${summary.notBackedUp} couldn't be backed up right now. "
          "Check your connection and try again.",
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
          const SizedBox(height: 32),
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
