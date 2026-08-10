// lib/pages/favourites_page.dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import '../constants.dart'; // storage, baseUrl
import '../widgets/document_grid.dart'; // reusable grid
import 'full_screen_image.dart';
import 'dart:async';
import 'package:flutter_quill/flutter_quill.dart';

class FavouritesPage extends StatefulWidget {
  const FavouritesPage({super.key});

  @override
  State<FavouritesPage> createState() => _FavouritesPageState();
}

class _FavouritesPageState extends State<FavouritesPage> {
  List<File> _favphotos = [];
  bool _loading = true;

  // this page's OWN selection state — independent of the home screen's
  bool _isSelectedMode = false;
  final Set<int> _selectedIndexes = {};

  @override
  void initState() {
    super.initState();
    _loadFavourites();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Future<void> _loadFavourites() async {
    setState(() => _loading = true);

    final token = await storage.read(key: "token");
    if (token == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl/send-fav'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 30));

      if (res.statusCode != 200) {
        _showError("Couldn't load favourites.");
        setState(() => _loading = false);
        return;
      }

      final data = jsonDecode(res.body);

      // backend returns [{"doc_path": "..."}]; keep only files still on device
      final files = (data["results"] as List)
          .map((r) => File(r["doc_path"] as String))
          .where((f) => f.existsSync())
          .toList();

      if (!mounted) return;
      setState(() {
        _favphotos = files;
        _loading = false;
        // reset selection whenever the list reloads (indexes may have shifted)
        _isSelectedMode = false;
        _selectedIndexes.clear();
      });
    } on SocketException {
      _showError("No internet connection.");
      setState(() => _loading = false);
    } on TimeoutException {
      _showError("Request timed out.");
      setState(() => _loading = false);
    } catch (_) {
      _showError("Something went wrong.");
      setState(() => _loading = false);
    }
  }

  void _handleTap(int i) async {
    if (_isSelectedMode) {
      // toggle selection
      if (_selectedIndexes.contains(i)) {
        setState(() {
          _selectedIndexes.remove(i);
          if (_selectedIndexes.isEmpty) _isSelectedMode = false;
        });
      } else {
        if (_selectedIndexes.length >= 5) {
          _showError("You cannot share more than 5 at once");
        } else {
          setState(() => _selectedIndexes.add(i));
        }
      }
    } else {
      // open fullscreen; on return, refresh so un-favourited/deleted items drop off
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => FullScreenImage(files: _favphotos, startIndex: i),
        ),
      );
      await _loadFavourites();
    }
  }

  void _handleLongPress(int i) {
    if (!_isSelectedMode) {
      setState(() {
        _isSelectedMode = true;
        _selectedIndexes.add(i);
      });
    }
  }

  PreferredSizeWidget _appBar() {
    if (!_isSelectedMode) {
      return AppBar(
        title: const Text('Favourites'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      );
    }
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Deselect all",
        onPressed: () => setState(() {
          _selectedIndexes.clear();
          _isSelectedMode = false;
        }),
      ),
      title: Text("${_selectedIndexes.length} selected"),
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          tooltip: "Share",
          onPressed: () async {
            final selectedFiles = _selectedIndexes
                .map((i) => _favphotos[i])
                .toList();

            final fileShares = <XFile>[];
            final noteTexts = <String>[];

            for (final file in selectedFiles) {
              if (file.path.endsWith('.json')) {
                final json = jsonDecode(await file.readAsString());
                final document = Document.fromJson(
                  List<Map<String, dynamic>>.from(json["delta"]),
                );
                noteTexts.add(document.toPlainText());
              } else {
                fileShares.add(XFile(file.path));
              }
            }

            final hasPdf = fileShares.any((f) => f.path.endsWith('.pdf'));
            final hasImage = fileShares.any(
              (f) =>
                  f.path.endsWith('.jpg') ||
                  f.path.endsWith('.jpeg') ||
                  f.path.endsWith('.png'),
            );

            final isMixed = hasPdf && hasImage;

            String? shareText;
            if (noteTexts.isNotEmpty) {
              shareText = noteTexts.join("\n\n--------------------\n\n");

              if (fileShares.isEmpty) {
                // Only notes selected
                shareText = shareText;
              } else {
                // Notes + files selected
                shareText = "$shareText\n\n$caption";
              }
            } else {
              shareText = isMixed ? null : caption;
            }

            if (fileShares.isEmpty) {
              await Share.share(shareText!, subject: "Shared via DocEzy");
            } else {
              await SharePlus.instance.share(
                ShareParams(
                  files: fileShares,
                  text: shareText,
                  subject: "Shared via DocEzy",
                ),
              );
            }

            setState(() {
              _selectedIndexes.clear();
              _isSelectedMode = false;
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _favphotos.isEmpty
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.favorite_border, size: 80, color: Colors.red),
                    SizedBox(height: 16),
                    Text('No favourites yet', style: TextStyle(fontSize: 18)),
                    Text('Mark documents as favourite to see them here'),
                  ],
                ),
              )
            : DocumentGrid(
                files: _favphotos,
                crossAxisCount: 3,
                childAspectRatio: 0.75,
                isSelectionMode: _isSelectedMode,
                selectedIndexes: _selectedIndexes,
                onTap: _handleTap,
                onLongPress: _handleLongPress,
              ),
      ),
    );
  }
}
