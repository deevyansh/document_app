// lib/pages/favourites_page.dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import '../constants.dart';                 // storage, baseUrl
import '../widgets/document_grid.dart';      // reusable grid
import 'full_screen_image.dart';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
    List<File> _photos = [];
    bool _loading = true;

    bool _isSelectedMode = false;
    final Set<int> _selectedIndexes = {};

    @override
    void initState() {
        super.initState();
        _load();
    }

    void _showError(String message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
    }

    Future<void> _load() async {
        final dir = await getApplicationDocumentsDirectory();

        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) {
            final name = p.basename(f.path);
            if (name.startsWith('profile_')) return false;
            if (name.endsWith('.pdf')) return true;
            if (name.endsWith('profile.jpg')) return false;
            if (name.endsWith('.thumb.jpg')) return false;
            return name.endsWith('.jpg') || name.endsWith('.png');
            })
            .toList();

        files.sort((a, b) {
        final aTime = int.parse(p.basenameWithoutExtension(a.path));
        final bTime = int.parse(p.basenameWithoutExtension(b.path));
        return bTime.compareTo(aTime);
        });

        setState(() {
            _photos=files;
            _loading=false;
        });
    }

    void _handleTap(int i) async {
        if (_isSelectedMode) {
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
        await Navigator.push<bool>(
            context,
            MaterialPageRoute(
            builder: (_) => FullScreenImage(files: _photos, startIndex: i),
            ),
        );
        await _load();
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

    Future<void> delete(List<String> files) async {
        final token = await storage.read(key: "token");
        if (token == null) return;
        for (final file in files){
        await File(file).delete();
        http.post(
            Uri.parse('$baseUrl/delete-document'),
            headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'doc_path': file}),
        );
        }
    }

    PreferredSizeWidget _appBar() {
        if (!_isSelectedMode) {
        return AppBar(
            title: const Text('Browser'),
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
                final filesToShare =
                _selectedIndexes.map((i) => XFile(_photos[i].path)).toList();
                await Share.shareXFiles(
                    filesToShare, 
                    text: caption,
                    subject: "Shared via DocEzy",
                );
                setState(() {
                _selectedIndexes.clear();
                _isSelectedMode = false;
                });
            },
            ),

            IconButton(
            icon: const Icon(Icons.delete),
            tooltip: "Delete",
            onPressed: () async{
              final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete documents?'),
                content: Text(
                  'Delete ${_selectedIndexes.length} document(s)? This cannot be undone.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if(confirmed !=true){return;}
            final pathsToDelete = _selectedIndexes
                .map((i) =>  _photos[i].path)
                .toList();
            await delete(pathsToDelete); 
              _load();
            setState((){
              _selectedIndexes.clear();
              _isSelectedMode=false;
            });
            }
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
                : _photos.isEmpty
                    ? const Center(
                        child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                            Icon(Icons.favorite_border, size: 80, color: Colors.red),
                            SizedBox(height: 16),
                            Text('No Documents yet', style: TextStyle(fontSize: 18)),
                        ],
                        ),
                    )
                    : DocumentGrid(
                        files: _photos,
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