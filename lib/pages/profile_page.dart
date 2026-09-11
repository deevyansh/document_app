import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../constants.dart';
import '../pin_service.dart';
import '../backup_service.dart';
import '../widgets/loading_dialog.dart';
import 'admin_stats_page.dart';
import 'pin_setup_page.dart';
import 'pin_change_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.userEmail});
  final String userEmail;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const _websiteUrl = 'https://docezy.in';
  static const _playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.deevyansh.docezy';

  final _picker = ImagePicker();
  File? _profileimage;
  bool _pinEnabled = false;
  bool _checkingBackup = false;

  // Hidden admin entry point: tapping the "Profile" app bar title 3 times
  // within [_adminTapWindow] opens AdminStatsPage — but only for
  // [adminEmail]. Anyone else tapping it 3 times sees nothing happen, so
  // the existence of the admin screen stays invisible to regular users.
  static const _adminTapWindow = Duration(seconds: 2);
  int _adminTapCount = 0;
  Timer? _adminTapResetTimer;

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

  Future<void> _loadPinStatus() async {
    final enabled = await pinService.isPinEnabled();
    if (!mounted) return;
    setState(() => _pinEnabled = enabled);
  }

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

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    _loadProfileImage();
    _loadPinStatus();
  }

  @override
  void dispose() {
    _adminTapResetTimer?.cancel();
    super.dispose();
  }

  /// Counts taps on the "Profile" title. On the 3rd tap inside the window,
  /// resets the counter and — only for [adminEmail] — opens AdminStatsPage.
  void _handleTitleTap() {
    _adminTapResetTimer?.cancel();
    _adminTapCount++;

    if (_adminTapCount >= 3) {
      _adminTapCount = 0;
      if (widget.userEmail.toLowerCase() == adminEmail.toLowerCase()) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AdminStatsPage()),
        );
      }
      return;
    }

    _adminTapResetTimer = Timer(_adminTapWindow, () {
      _adminTapCount = 0;
    });
  }

  Future<void> _pickProfileImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (image == null) return;
    final dir = await getApplicationDocumentsDirectory();
    if (_profileimage != null && await _profileimage!.exists()) {
      await _profileimage!.delete();
    }
    final dest = p.join(
      dir.path,
      'profile_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    final file = File(image.path);
    final newFile = await file.copy(dest);
    setState(() {
      _profileimage = newFile;
    });
  }

  /// Opens [url] in the device's browser / Play Store app. Used by the
  /// "About DocEzy" and "Leave a Review" rows.
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _showError("Couldn't open the link.");
      }
    } catch (_) {
      _showError("Couldn't open the link.");
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.json')) return Icons.notes_outlined;
    return Icons.image_outlined;
  }

  /// "N file(s) in your backup aren't on this device" confirmation, with
  /// a scrollable preview of what's about to be retrieved.
  Future<bool?> _confirmRetrieve(List<Map<String, dynamic>> missing) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retrieve from backup?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${missing.length} file(s) in your backup ${missing.length == 1 ? "isn't" : "aren't"} on this device yet.',
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: missing.length,
                  itemBuilder: (context, i) {
                    final row = missing[i];
                    final name = p.basename(row['doc_path'] as String);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _iconFor(name),
                            size: 18,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Text(
                            _formatSize(row['size_bytes'] as int?),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Retrieve'),
          ),
        ],
      ),
    );
  }

  /// "Retrieve Backup" row's whole flow: check what's missing → confirm
  /// with the user → download + write each one back, with progress.
  Future<void> _retrieveBackup() async {
    if (_checkingBackup) return;
    setState(() => _checkingBackup = true);

    List<Map<String, dynamic>> missing;
    try {
      missing = await BackupService.checkForRestorableBackups();
    } catch (e) {
      if (mounted) setState(() => _checkingBackup = false);
      _showError("Couldn't check your backup right now.");
      return;
    }

    if (!mounted) return;
    setState(() => _checkingBackup = false);

    if (missing.isEmpty) {
      _showMessage("You're all caught up — nothing new to retrieve.");
      return;
    }

    final confirmed = await _confirmRetrieve(missing);
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<String>(
      'Retrieving 1 of ${missing.length}…',
    );

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (_, value, __) => Text(value),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final result = await BackupService.retrieveBackups(
      missing,
      onProgress: (done, total, name) {
        progress.value = done >= total
            ? 'Finishing up…'
            : 'Retrieving ${done + 1} of $total\n$name';
      },
    );

    if (!mounted) return;
    hideLoadingDialog(context);

    _showMessage(
      result.failed == 0
          ? 'Retrieved ${result.succeeded} file(s).'
          : 'Retrieved ${result.succeeded} file(s) — ${result.failed} couldn\'t be downloaded. Try again later.',
    );
  }

  Future<bool> _confirmCurrentPin() async {
    final controller = TextEditingController();
    String? error;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Confirm your PIN'),
              content: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                autofocus: true,
                decoration: InputDecoration(
                  counterText: '',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final ok = await pinService.verifyPin(
                      controller.text.trim(),
                    );
                    if (!context.mounted) return;
                    if (ok) {
                      Navigator.pop(context, true);
                    } else {
                      setDialogState(() => error = 'Incorrect PIN');
                    }
                  },
                  child: const Text('Confirm'),
                ),
              ],
            );
          },
        );
      },
    );

    return result ?? false;
  }

  Future<void> _handlePinToggle(bool value) async {
    if (value) {
      final created = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const PinSetupPage()),
      );
      if (created == true) {
        setState(() => _pinEnabled = true);
      }
    } else {
      final confirmed = await _confirmCurrentPin();
      if (confirmed) {
        await pinService.disablePin();
        setState(() => _pinEnabled = false);
      }
    }
  }

  Future<void> _confirmDeleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Account"),
        content: const Text(
          "This action cannot be undone.\n\nAre you sure you want to delete your account?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      Navigator.pop(context, ProfilePageAction.deleteaccount);
    }
  }

  /// Profile picture, camera-edit badge, and the account email.
  Widget _buildProfileHeader() {
    return Column(
      children: [
        Stack(
          children: [
            CircleAvatar(
              radius: 50,
              backgroundColor: Colors.grey.shade200,
              backgroundImage: _profileimage != null
                  ? FileImage(_profileimage!)
                  : null,
              child: _profileimage == null
                  ? const Icon(Icons.person, size: 60)
                  : null,
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: _pickProfileImage,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(
                    Icons.camera_alt,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(widget.userEmail, style: const TextStyle(fontSize: 18)),
      ],
    );
  }

  /// App-lock toggle + change-PIN row.
  Widget _buildPinSection() {
    return Column(
      children: [
        SwitchListTile(
          title: const Text('App Lock'),
          subtitle: const Text('Require a PIN to open DocEzy'),
          value: _pinEnabled,
          onChanged: _handlePinToggle,
        ),
        if (_pinEnabled)
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('Change PIN'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PinChangePage()),
              );
            },
          ),
      ],
    );
  }

  /// Retrieve Backup / About / Leave a review rows.
  Widget _buildMoreSection() {
    return Column(
      children: [
        ListTile(
          leading: _checkingBackup
              ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
              : const Icon(Icons.cloud_download_outlined),
          title: const Text('Retrieve Backup'),
          subtitle: const Text('Restore files backed up from another device'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _checkingBackup ? null : _retrieveBackup,
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('About DocEzy'),
          subtitle: const Text('docezy.in'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openUrl(_websiteUrl),
        ),
        ListTile(
          leading: const Icon(Icons.star_border),
          title: const Text('Leave a Review'),
          subtitle: const Text('Rate DocEzy on the Play Store'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openUrl(_playStoreUrl),
        ),
      ],
    );
  }

  /// Groups App Lock / Change PIN / Retrieve Backup / About / Leave a
  /// Review into one card so the settings rows read as a single cohesive
  /// block.
  Widget _buildSettingsCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildPinSection(),
          const Divider(height: 1),
          _buildMoreSection(),
        ],
      ),
    );
  }

  /// Logout / Delete Account, pinned to the bottom of the page.
  Widget _buildAccountActions() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              side: BorderSide(color: Colors.grey.shade400),
              foregroundColor: Colors.grey.shade800,
            ),
            icon: const Icon(Icons.logout),
            label: const Text(
              "Log Out",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            onPressed: () {
              Navigator.pop(context, ProfilePageAction.logout);
            },
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              side: BorderSide(color: Colors.red.shade200),
              foregroundColor: Colors.red.shade700,
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text(
              "Delete Account",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            onPressed: _confirmDeleteAccount,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _handleTitleTap,
          behavior: HitTestBehavior.opaque,
          child: const Text("Profile"),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // Scrollable content — avoids overflow on small screens while
              // still letting the account actions sit at the very bottom.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      _buildProfileHeader(),
                      const SizedBox(height: 40),
                      _buildWidgetPromo(),
                      const SizedBox(height: 16),
                      _buildSettingsCard(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildAccountActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWidgetPromo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _promoAddWidget,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Search from your home screen',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Add the DocEzy search widget',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.add_circle, color: Colors.white, size: 26),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _promoAddWidget() async {
    try {
      final supported =
          await methodChannel.invokeMethod<bool>('isPinWidgetSupported') ??
              false;
      if (!supported) {
        _showError(
          "Your device doesn't support adding widgets this way. "
              "Long-press your home screen to add it manually.",
        );
        return;
      }
      await methodChannel.invokeMethod('requestPinWidget');
    } catch (e) {
      _showError("Couldn't add the widget.");
    }
  }
}