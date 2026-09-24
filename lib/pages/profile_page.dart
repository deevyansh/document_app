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
import 'admin_stats_page.dart';
import 'backup_status_page.dart';
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
  bool _autoBackupEnabled = true;
  bool _searchHistoryStatus = true;

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

  Future<void> _loadAutoBackupStatus() async {
    final enabled = await BackupService.isAutoBackupEnabled();
    if (!mounted) return;
    setState(() => _autoBackupEnabled = enabled);
  }

  Future<void> _loadSearchHistoryStatus() async {
    final exists = await storage.containsKey(key: 'searchhistory');
    if (!exists) {
      await storage.write(
        key: 'searchhistory',
        value: 'true',
      );
    }
    final enabled = await storage.read(key: 'searchhistory');
    if (!mounted) return;
    setState(() {
      _searchHistoryStatus = enabled == 'true';
    });
  }

  Future<void> _toggleSearchHistoryStatus(bool value) async {
    final enabled = await storage.read(key: 'searchhistory');
    if (!mounted) return;
    if (enabled == "true") {
      await storage.write(key: 'searchhistory', value: 'false');
      setState(() {
        _searchHistoryStatus = false;
      });
    } else {
      await storage.write(key: 'searchhistory', value: 'true');
      setState(() {
        _searchHistoryStatus = true;
      });
    }
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

  @override
  void initState() {
    super.initState();
    _loadProfileImage();
    _loadPinStatus();
    _loadAutoBackupStatus();
    _loadSearchHistoryStatus();
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

  /// Flips the "Automatic Backup" switch: persists the choice via
  /// BackupService, then updates the UI to match. When turned on, newly
  /// created documents/notes go back to being queued and uploaded as
  /// usual (and the next periodic sync resumes); when turned off, nothing
  /// new gets queued and the periodic sync skips itself, so no backup is
  /// taken until it's switched back on.
  Future<void> _handleAutoBackupToggle(bool value) async {
    await BackupService.setAutoBackupEnabled(value);
    if (!mounted) return;
    setState(() => _autoBackupEnabled = value);
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

  // ───────────────────────────────────────────────────────────────────────
  // UI
  // ───────────────────────────────────────────────────────────────────────

  /// Profile picture with a gradient ring, camera-edit badge, and email.
  Widget _buildProfileHeader() {
    final primary = Theme.of(context).colorScheme.primary;
    final bg = Theme.of(context).scaffoldBackgroundColor;

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: CircleAvatar(
                  radius: 50,
                  backgroundColor: primary.withAlpha(25),
                  backgroundImage: _profileimage != null
                      ? FileImage(_profileimage!)
                      : null,
                  child: _profileimage == null
                      ? Icon(Icons.person_rounded, size: 58, color: primary)
                      : null,
                ),
              ),
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: Material(
                color: primary,
                shape: CircleBorder(side: BorderSide(color: bg, width: 3)),
                elevation: 2,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _pickProfileImage,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.camera_alt_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: primary.withAlpha(20),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mail_outline_rounded, size: 16, color: primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.userEmail,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeaturesSection() {
    return _SettingsSection(
      title: 'Features',
      children: [
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.lock_rounded,
            color: Color(0xFF5E35B1),
          ),
          title: 'App Lock',
          subtitle: 'Require a PIN to open DocEzy',
          trailing: Switch.adaptive(
            value: _pinEnabled,
            onChanged: _handlePinToggle,
          ),
          onTap: () => _handlePinToggle(!_pinEnabled),
        ),
        if (_pinEnabled)
          _SettingsTile(
            leading: const _IconBadge(
              icon: Icons.password_rounded,
              color: Color(0xFF7E57C2),
            ),
            title: 'Change PIN',
            subtitle: 'Update your app lock PIN',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PinChangePage()),
              );
            },
          ),
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.backup_rounded,
            color: Color(0xFF00897B),
          ),
          title: 'Automatic Backup',
          subtitle: 'Automatically back up new documents and notes',
          trailing: Switch.adaptive(
            value: _autoBackupEnabled,
            onChanged: _handleAutoBackupToggle,
          ),
          onTap: () => _handleAutoBackupToggle(!_autoBackupEnabled),
        ),
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.manage_search_rounded,
            color: Color(0xFFF57C00),
          ),
          title: 'Remember my Searches',
          subtitle: 'Your previous searches will be used to suggest new ones',
          trailing: Switch.adaptive(
            value: _searchHistoryStatus,
            onChanged: _toggleSearchHistoryStatus,
          ),
          onTap: () => _toggleSearchHistoryStatus(!_searchHistoryStatus),
        ),
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.cloud_done_rounded,
            color: Color(0xFF1E88E5),
          ),
          title: 'Backup Status',
          subtitle: 'See what has been backed up',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BackupStatusPage()),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSocialSection() {
    return _SettingsSection(
      title: 'Social',
      children: [
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.language_rounded,
            color: Color(0xFF1565C0),
          ),
          title: 'About DocEzy',
          subtitle: 'docezy.in',
          trailingIcon: Icons.open_in_new_rounded,
          onTap: () => _openUrl(_websiteUrl),
        ),
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.star_rounded,
            color: Color(0xFFFFA000),
          ),
          title: 'Leave a Review',
          subtitle: 'Rate DocEzy on the Play Store',
          trailingIcon: Icons.open_in_new_rounded,
          onTap: () => _openUrl(_playStoreUrl),
        ),
        _SettingsTile(
          leading: const _YouTubeLogo(),
          title: 'YouTube',
          subtitle: 'Follow DocEzy on YouTube',
          trailingIcon: Icons.open_in_new_rounded,
          onTap: () => _openUrl('https://www.youtube.com/@DocEzy'),
        ),
        _SettingsTile(
          leading: const _InstagramLogo(),
          title: 'Instagram',
          subtitle: 'Follow DocEzy on Instagram',
          trailingIcon: Icons.open_in_new_rounded,
          onTap: () => _openUrl('https://www.instagram.com/docezy.app/'),
        ),
      ],
    );
  }

  Widget _buildLegalSection() {
    return _SettingsSection(
      title: 'Legal',
      children: [
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.privacy_tip_rounded,
            color: Color(0xFF546E7A),
          ),
          title: 'Privacy Policy',
          trailingIcon: Icons.open_in_new_rounded,
          onTap: () => _openUrl('https://privacy.docezy.in/'),
        ),
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.gavel_rounded,
            color: Color(0xFF546E7A),
          ),
          title: 'Terms & Conditions',
          trailingIcon: Icons.open_in_new_rounded,
          onTap: () => _openUrl('https://terms.docezy.in/'),
        ),
      ],
    );
  }

  Widget _buildAccountSection() {
    return _SettingsSection(
      title: 'Account',
      children: [
        _SettingsTile(
          leading: const _IconBadge(
            icon: Icons.logout_rounded,
            color: Color(0xFF455A64),
          ),
          title: 'Log Out',
          subtitle: 'Sign out of this device',
          onTap: () {
            Navigator.pop(context, ProfilePageAction.logout);
          },
        ),
        _SettingsTile(
          leading: _IconBadge(
            icon: Icons.delete_forever_rounded,
            color: Colors.red.shade600,
          ),
          title: 'Delete Account',
          subtitle: 'Permanently remove your account',
          destructive: true,
          onTap: _confirmDeleteAccount,
        ),
      ],
    );
  }

  Widget _buildVersionSection() {
    return Center(
      child: Text(
        'DocEzy • Version 1.0.0',
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey[500],
        ),
      ),
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            children: [
              _buildProfileHeader(),
              const SizedBox(height: 28),
              _buildWidgetPromo(),
              const SizedBox(height: 24),
              _buildFeaturesSection(),
              const SizedBox(height: 24),
              _buildSocialSection(),
              const SizedBox(height: 24),
              _buildLegalSection(),
              const SizedBox(height: 24),
              _buildAccountSection(),
              const SizedBox(height:24),
              _buildVersionSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWidgetPromo() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1565C0).withAlpha(60),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: InkWell(
            onTap: _promoAddWidget,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(46),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.search_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Search from your home screen',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Add the DocEzy search widget',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Add',
                      style: TextStyle(
                        color: Color(0xFF1565C0),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
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

// ─────────────────────────────────────────────────────────────────────────
// Reusable UI building blocks (presentation only — no logic)
// ─────────────────────────────────────────────────────────────────────────

/// A labelled group of rows rendered inside a rounded card, with inset
/// dividers between rows.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final lineColor = isDark ? Colors.white10 : Colors.grey.shade200;

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i != children.length - 1) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 70,
            endIndent: 16,
            color: lineColor,
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 10),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: lineColor),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withAlpha(10),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: rows),
          ),
        ),
      ],
    );
  }
}

/// One tappable row: leading badge, title/subtitle, and either a custom
/// trailing widget (e.g. a Switch) or a small circular arrow chip.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingIcon = Icons.chevron_right_rounded,
    this.onTap,
    this.destructive = false,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData trailingIcon;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final onSurface = theme.colorScheme.onSurface;
    final titleColor = destructive ? Colors.red.shade600 : onSurface;
    final subtitleColor =
        destructive ? Colors.red.shade300 : onSurface.withAlpha(140);
    final isChevron = trailingIcon == Icons.chevron_right_rounded;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 12.5, color: subtitleColor),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ??
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: destructive
                        ? Colors.red.withAlpha(20)
                        : (isDark ? Colors.white10 : Colors.grey.shade100),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    trailingIcon,
                    size: isChevron ? 20 : 15,
                    color: destructive
                        ? Colors.red.shade400
                        : onSurface.withAlpha(120),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// Rounded-square tinted icon badge used for row leading icons.
class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, color: color, size: 21),
    );
  }
}

/// YouTube logo: red rounded rectangle with a white play triangle,
/// on a soft red tile so it lines up with the other row badges.
class _YouTubeLogo extends StatelessWidget {
  const _YouTubeLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFFFF0000).withAlpha(24),
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: const CustomPaint(
        size: Size(26, 18),
        painter: _YouTubePainter(),
      ),
    );
  }
}

class _YouTubePainter extends CustomPainter {
  const _YouTubePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(h * 0.28)),
      Paint()..color = const Color(0xFFFF0000),
    );
    final triangle = Path()
      ..moveTo(w * 0.40, h * 0.29)
      ..lineTo(w * 0.40, h * 0.71)
      ..lineTo(w * 0.66, h * 0.50)
      ..close();
    canvas.drawPath(triangle, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Instagram logo: the yellow→orange→pink→purple gradient square with
/// the white camera glyph.
class _InstagramLogo extends StatelessWidget {
  const _InstagramLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        gradient: const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            Color(0xFFFFD600),
            Color(0xFFFF7A00),
            Color(0xFFFF0069),
            Color(0xFFD300C5),
            Color(0xFF7638FA),
          ],
          stops: [0.0, 0.25, 0.5, 0.75, 1.0],
        ),
      ),
      alignment: Alignment.center,
      child: const CustomPaint(
        size: Size(22, 22),
        painter: _InstagramGlyphPainter(),
      ),
    );
  }
}

class _InstagramGlyphPainter extends CustomPainter {
  const _InstagramGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.09;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    // Outer rounded square.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(stroke / 2, stroke / 2, s - stroke, s - stroke),
        Radius.circular(s * 0.28),
      ),
      paint,
    );

    // Lens.
    canvas.drawCircle(Offset(s / 2, s / 2), s * 0.22, paint);

    // Flash dot.
    canvas.drawCircle(
      Offset(s * 0.76, s * 0.24),
      s * 0.06,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}