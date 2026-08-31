import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../constants.dart';
import '../pin_service.dart';
import 'pin_setup_page.dart';
import 'pin_change_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.userEmail});
  final String userEmail;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _picker = ImagePicker();
  File? _profileimage;
  bool _pinEnabled = false;

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

  void initState() {
    super.initState();
    _loadProfileImage();
    _loadPinStatus();
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

  Widget _buildWidgetPromo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Profile")),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),

            // Profile Icon
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

            // Email
            Text(widget.userEmail, style: const TextStyle(fontSize: 18)),

            const SizedBox(height: 40),

            _buildWidgetPromo(),

            const SizedBox(height: 16),

            _buildPinSection(),

            const SizedBox(height: 24),

            // Logout Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.logout),
                label: const Text("Log Out"),
                onPressed: () {
                  Navigator.pop(context, ProfilePageAction.logout);
                },
              ),
            ),

            const SizedBox(height: 16),

            // Delete Account Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.delete),
                label: const Text("Delete Account"),
                onPressed: () async {
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
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text("Delete"),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    Navigator.pop(context, ProfilePageAction.deleteaccount);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}