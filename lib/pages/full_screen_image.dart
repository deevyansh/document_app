import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import '../constants.dart'; // for baseUrl, storage
import 'pdf_page.dart';

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
  Set<String> _favfiles = {};
  late int _currentindex;
  late final PageController _pageController;

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
        for (final row in data["results"]) row["doc_path"] as String,
      };
    });
  }

  @override
  void initState() {
    super.initState();
    _loadFavourites();
    _pageController = PageController(initialPage: widget.startIndex);
    _currentindex = widget.startIndex;
  }

  @override
  void dispose() {
    _pageController.dispose();
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
    final file = widget.files[_currentindex];

    if (_favfiles.contains(file.path)) {
      setState(() {
        _favfiles.remove(file.path);
      });
    } else {
      setState(() {
        _favfiles.add(file.path);
      });
    }
    http.post(
      Uri.parse('$baseUrl/rev-favourites'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'doc_path': file.path}),
    );
  }

  Future<void> delete(BuildContext context) async {
    final token = await storage.read(key: "token");
    if (token == null) return;

    final file = widget.files[_currentindex];
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
      body: jsonEncode({'doc_path': file.path}),
    );
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
      body: jsonEncode({'doc_path': widget.files[_currentindex].path}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      _contextcontroller.text = data['results'] ?? '';
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Label As",
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: _contextcontroller,
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
      ),
    );

    if (saved == true) {
      final response = await http.post(
        Uri.parse('$baseUrl/save-context'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'context': _contextcontroller.text,
          'doc_path': widget.files[_currentindex].path,
        }),
      );
    }
    _contextcontroller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Container(
            height:
                MediaQuery.of(context).padding.top +
                12, // status bar + small padding
            color: Colors.black,
          ),
          // ── Image / PDF area wrapped in pointer Listener ──────────────────
          Expanded(
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: PhotoViewGallery.builder(
                scrollPhysics:
                    _scrollPhysics, // Dynamically locked on multi-touch
                itemCount: widget.files.length,
                pageController: _pageController,
                onPageChanged: (i) => setState(() => _currentindex = i),
                backgroundDecoration: const BoxDecoration(color: Colors.black),
                builder: (context, i) {
                  final file = widget.files[i];

                  if (file.path.endsWith('.pdf')) {
                    return PhotoViewGalleryPageOptions.customChild(
                      child: PdfPage(file: file),
                      initialScale: PhotoViewComputedScale.contained,
                      minScale: PhotoViewComputedScale.contained,
                      maxScale: PhotoViewComputedScale.covered * 3,
                    );
                  }

                  return PhotoViewGalleryPageOptions(
                    imageProvider: FileImage(file),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 5,
                    heroAttributes: PhotoViewHeroAttributes(tag: file.path),
                  );
                },
              ),
            ),
          ),

          // ── Compact white footer ──────────────────────────────────────
          Container(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 8,
              bottom: MediaQuery.of(context).padding.bottom + 8,
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
                    onTap: () => Share.shareXFiles(
                      [XFile(widget.files[_currentindex].path)],
                      subject: "Shared via DocEzy",
                      text: caption,
                    ),
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
                          (_favfiles.contains(widget.files[_currentindex].path))
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

                Expanded(
                  child: InkWell(
                    onTap: () => _contextwindow(context),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_outlined),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
