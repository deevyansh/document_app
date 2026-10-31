import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import '../constants.dart'; // for baseUrl, storage
import 'pdf_page.dart';
import 'note_read_page.dart';
import 'package:flutter_quill/flutter_quill.dart';
import '../backup_service.dart';
import 'package:path/path.dart' as p;
import '../store_service.dart';
import 'notes_page.dart';
import 'image_edit_page.dart';

class FullScreenImage extends StatefulWidget {
  final List<File> files;
  final int startIndex;
  const FullScreenImage({
    super.key,
    required this.files,
    required this.startIndex,
  });

  @override
  State<FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<FullScreenImage> {
  late final List<File> _files;
  late final StoreService _storeService;
  Set<String> _favfiles = {};
  late int _currentindex;
  late final PageController _pageController;
  final FocusNode _labelFocusNode = FocusNode();
  bool _isBottomBarVisible = true;

  // ── Dynamic Gesture Lock State ──────────────────────────────────────────────
  final Set<int> _activePointers = {};
  ScrollPhysics _scrollPhysics = const BouncingScrollPhysics();

  Future<void> _loadFavourites() async {
    final token = await storage.read(key: "token");
    if (token == null) return;

    final response = await http.post(
      Uri.parse('$baseUrl/send-fav'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode != 200) return;

    final data = jsonDecode(response.body);

    setState(() {
      _favfiles = {
        for (final row in data["results"])
          p.basename(row["doc_path"] as String),
      };
    });
  }

  void _toggleBottomBar() {
    setState(() {
      _isBottomBarVisible = !_isBottomBarVisible;
    });
  }

  @override
  void initState() {
    super.initState();
    _files = List<File>.of(widget.files);
    _storeService = StoreService(
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.red, content: Text(message)),
        );
      },
      onLoad: () async {},
    );
    _loadFavourites();
    _pageController = PageController(initialPage: widget.startIndex);
    _currentindex = widget.startIndex;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _labelFocusNode.dispose();
    _storeService.dispose();
    super.dispose();
  }

  // ── Pointer Handlers to Lock/Unlock Swiping ────────────────────────────────
  void _onPointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    _updatePhysics();
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    _updatePhysics();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _updatePhysics();
  }

  void _updatePhysics() {
    final bool isMultiTouch = _activePointers.length >= 2;
    final ScrollPhysics targetPhysics = isMultiTouch
        ? const NeverScrollableScrollPhysics()
        : const BouncingScrollPhysics();

    if (_scrollPhysics.runtimeType != targetPhysics.runtimeType) {
      setState(() {
        _scrollPhysics = targetPhysics;
      });
    }
  }

  Future<void> _rev_favourites() async {
    final token = await storage.read(key: "token");
    if (token == null) return;
    final file = _files[_currentindex];

    final name = p.basename(file.path);
    if (_favfiles.contains(name)) {
      setState(() => _favfiles.remove(name));
    } else {
      setState(() => _favfiles.add(name));
    }
    http.post(
      Uri.parse('$baseUrl/rev-favourites'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'doc_path': dbPath(file.path)}),
    );
  }

  Future<void> delete(BuildContext context) async {
    final token = await storage.read(key: "token");
    if (token == null) return;

    final file = _files[_currentindex];
    await file.delete();

    if (context.mounted) {
      Navigator.pop(context, true);
    }

    http.post(
      Uri.parse('$baseUrl/delete-document'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'doc_path': dbPath(file.path)}),
    );
  }

  Future<void> _editCurrentFile() async {
    final source = _files[_currentindex];
    final route = MaterialPageRoute<File?>(
      builder: (_) {
        if (source.path.toLowerCase().endsWith('.json')) {
          return NotesPage(editingFile: source);
        }
        return ImageEditPage(file: source);
      },
    );

    final temporaryEditedFile = await Navigator.push<File?>(context, route);
    if (temporaryEditedFile == null || !mounted) return;

    final type = source.path.toLowerCase().endsWith('.pdf')
        ? 'PDF'
        : source.path.toLowerCase().endsWith('.json')
        ? 'note'
        : 'image';
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Saving edited $type…'),
          duration: const Duration(minutes: 1),
        ),
      );

    File? savedFile;
    try {
      savedFile = await _storeService.importFromPath(temporaryEditedFile.path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save edited document: $error')),
        );
      }
    } finally {
      try {
        if (await temporaryEditedFile.exists()) {
          await temporaryEditedFile.delete();
        }
      } catch (_) {}
    }

    final importedFile = savedFile;
    if (!mounted) return;
    if (importedFile == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Could not save the edited $type. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      return;
    }

    final newIndex = _currentindex + 1;
    setState(() {
      _files.insert(newIndex, importedFile);
      _currentindex = newIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(newIndex);
      }
    });

    messenger.hideCurrentSnackBar();
    if (type == 'image') {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline, color: Colors.green),
          title: const Text('Image saved'),
          content: const Text('A new edited image has been saved.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('New $type saved.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: const Text(
          'Are you sure you want to delete this document? This action cannot be undone.',
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

    if (confirmed == true) {
      if (!mounted) return;
      await delete(context);
    }
  }

  Future<void> _contextwindow(BuildContext context) async {
    final _contextcontroller = TextEditingController();
    final token = await storage.read(key: "token");

    final response = await http.post(
      Uri.parse('$baseUrl/get-context'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'doc_path': dbPath(_files[_currentindex].path)}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      _contextcontroller.text = data['results'] ?? '';
    }

    if (!mounted) {
      _contextcontroller.dispose();
      return;
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            _labelFocusNode.requestFocus();
          }
        });
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            "Label As",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: _contextcontroller,
              focusNode: _labelFocusNode,
              maxLines: 3,
              minLines: 2,
              maxLength: 150,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                alignLabelWithHint: true,
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text("Save"),
            ),
          ],
        );
      },
    );

    if (!mounted) {
      _contextcontroller.dispose();
      return;
    }

    if (saved == true) {
      await http.post(
        Uri.parse('$baseUrl/save-context'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'context': _contextcontroller.text,
          'doc_path': dbPath(_files[_currentindex].path),
        }),
      );
      await BackupService.markDeleted(_files[_currentindex].path);
    }
    _contextcontroller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Fixed image viewer
          Positioned.fill(
            child: Column(
              children: [
                SizedBox(
                  height: MediaQuery.of(context).padding.top + 12,
                ),
                Expanded(
                  child: Listener(
                    onPointerDown: _onPointerDown,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleBottomBar,
                      child: PhotoViewGallery.builder(
                        scrollPhysics: _scrollPhysics,
                        itemCount: _files.length,
                        pageController: _pageController,
                        onPageChanged: (i) {
                          setState(() => _currentindex = i);
                        },
                        backgroundDecoration:
                            const BoxDecoration(color: Colors.black),
                        builder: (context, i) {
                          final file = _files[i];

                          if (file.path.endsWith('.pdf')) {
                            return PhotoViewGalleryPageOptions.customChild(
                              child: PdfPage(file: file),
                              initialScale:
                                  PhotoViewComputedScale.contained,
                              minScale:
                                  PhotoViewComputedScale.contained,
                              maxScale:
                                  PhotoViewComputedScale.covered * 3,
                            );
                          }

                          if (file.path.endsWith('.json')) {
                            return PhotoViewGalleryPageOptions.customChild(
                              child: NoteReadPage(file: file),
                              initialScale:
                                  PhotoViewComputedScale.contained,
                              minScale:
                                  PhotoViewComputedScale.contained,
                              maxScale:
                                  PhotoViewComputedScale.covered * 3,
                            );
                          }

                          return PhotoViewGalleryPageOptions(
                            imageProvider: FileImage(file),
                            minScale:
                                PhotoViewComputedScale.contained,
                            maxScale:
                                PhotoViewComputedScale.covered * 5,
                            heroAttributes:
                                PhotoViewHeroAttributes(tag: file.path),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Animated bottom action bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_isBottomBarVisible,
              child: AnimatedSlide(
                offset: _isBottomBarVisible
                    ? Offset.zero
                    : const Offset(0, 1),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOutCubic,
                child: AnimatedOpacity(
                  opacity: _isBottomBarVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    padding: EdgeInsets.only(
                      left: 20,
                      right: 20,
                      top: 8,
                      bottom: bottomPadding + 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.72),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Delete
                        Expanded(
                          child: InkWell(
                            onTap: () => _confirmDelete(context),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.delete_outline,
                                    size: 24,
                                    color: Colors.black.withOpacity(0.72),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Delete',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black.withOpacity(0.72),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Share
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final file = _files[_currentindex];

                              if (file.path.endsWith('.json')) {
                                final data =
                                    jsonDecode(await file.readAsString());
                                final delta = data["delta"];

                                final document = Document.fromJson(
                                  List<Map<String, dynamic>>.from(delta),
                                );

                                await Share.share(
                                  document.toPlainText(),
                                  subject: "Shared via DocEzy",
                                );
                              } else {
                                await Share.shareXFiles(
                                  [XFile(file.path)],
                                  subject: "Shared via DocEzy",
                                  text: caption,
                                );
                              }
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.share_outlined,
                                    size: 24,
                                    color: Colors.black.withOpacity(0.72),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Share',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black.withOpacity(0.72),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Favourites
                        Expanded(
                          child: InkWell(
                            onTap: () => _rev_favourites(),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _favfiles.contains(
                                    p.basename(_files[_currentindex].path),
                                  )
                                      ? const Icon(
                                          Icons.favorite,
                                          size: 24,
                                          color: Colors.red,
                                        )
                                      : Icon(
                                          Icons.favorite_border,
                                          size: 24,
                                          color: Colors.black.withOpacity(0.72),
                                        ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Favourites',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black.withOpacity(0.72),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Label
                        Expanded(
                          child: InkWell(
                            onTap: () => _contextwindow(context),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.label_outline),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Label',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black.withOpacity(0.72),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Edit (not shown for PDFs)
                        if (!_files[_currentindex]
                            .path
                            .toLowerCase()
                            .endsWith('.pdf'))
                          Expanded(
                            child: InkWell(
                              onTap: _editCurrentFile,
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.edit_outlined,
                                      size: 24,
                                      color: Colors.black.withOpacity(0.72),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Edit',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.black.withOpacity(0.72),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
