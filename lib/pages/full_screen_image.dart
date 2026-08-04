import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import '../constants.dart';        // for baseUrl, storage
import 'pdf_page.dart';

class FullScreenImage extends StatefulWidget {
  final List<File> files;
  final int startIndex;
  const FullScreenImage({super.key, required this.files, required this.startIndex});

  @override
  State<FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<FullScreenImage> {
  late int _currentindex;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.startIndex);
    _currentindex=widget.startIndex;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Container(
            height: MediaQuery.of(context).padding.top + 12, // status bar + small padding
            color: Colors.black,
          ),
          // ── Image / PDF area (takes all remaining space) ──────────────
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.files.length,
              onPageChanged: (i) => setState(() => _currentindex = i),
              itemBuilder: (context, i) {
                final file = widget.files[i];

                if (file.path.endsWith('.pdf')) {
                  return PdfPage(file: file);
                }

                return Center(
                  child: InteractiveViewer(
                    panEnabled: true,
                    minScale: 0.8,
                    maxScale: 4.0,
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
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
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.72),
                  blurRadius: 8,
                  offset: Offset(0, -2),
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
                    child:  Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline, size: 24, color: Colors.black.withOpacity(0.72)),
                          SizedBox(height: 2),
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
                    ),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.share_outlined, size: 24, color: Colors.black.withOpacity(0.72)),
                          SizedBox(height: 2),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
