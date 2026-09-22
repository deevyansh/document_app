import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:convert';

class DocumentGrid extends StatelessWidget {
  final List<File> files;
  final int crossAxisCount;
  final double childAspectRatio;
  final ScrollController? controller;

  final bool isSelectionMode;
  final Set<int> selectedIndexes;

  final void Function(int index) onTap;
  final void Function(int index) onLongPress;

  const DocumentGrid({
    super.key,
    required this.files,
    required this.isSelectionMode,
    required this.selectedIndexes,
    required this.onTap,
    required this.onLongPress,
    this.controller,
    this.crossAxisCount = 3,
    this.childAspectRatio = 0.75,
  });

  /// Best-effort "version" for a file on disk — its last-modified time in
  /// milliseconds, or 0 if the file doesn't exist (yet). Folding this into
  /// an Image.file's widget `key` means a thumbnail regenerated at the same
  /// path (a PDF's `<path>.thumb.jpg` is always rewritten in place) is
  /// treated as a brand-new image instead of Flutter silently reusing
  /// whatever it already has cached for that exact file path + size.
  static int _fileVersion(File file) {
    try {
      return file.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  static Widget buildTile({
    required File file,
    required bool isSelectionMode,
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    final isPdf = file.path.endsWith('.pdf');
    final isNote = file.path.endsWith('.json');
    final thumbFile = isPdf ? File('${file.path}.thumb.jpg') : null;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: isPdf
                  ? Image.file(
                      thumbFile!,
                      // Ties this widget (and Flutter's resolve of its
                      // image) to the thumbnail's current mtime, so a
                      // regenerated thumb at the same path is loaded fresh
                      // instead of showing whatever was cached before.
                      key: ValueKey(
                        '${thumbFile.path}#${_fileVersion(thumbFile)}',
                      ),
                      fit: BoxFit.cover,
                      cacheWidth: 500,
                    )
                  : (!isNote)
                  ? Image.file(file, fit: BoxFit.cover, cacheWidth: 500)
                  : FutureBuilder<String>(
                      future: file.readAsString(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        }

                        if (snapshot.hasError || !snapshot.hasData) {
                          return const Center(
                            child: Icon(Icons.notes_outlined, size: 48),
                          );
                        }

                        final json = jsonDecode(snapshot.data!);
                        final preview = json["preview"] ?? "";

                        return Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.notes_outlined, size: 28),
                                const SizedBox(height: 8),
                                Text(
                                  preview,
                                  maxLines: 5,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),

          if (isSelectionMode && isSelected) ...[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const Positioned(
              top: 8,
              right: 8,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: Colors.blue,
                child: Icon(Icons.check, size: 16, color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.builder(
        controller: controller,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: childAspectRatio,
        ),
        itemCount: files.length,
        itemBuilder: (context, i) {
          return buildTile(
            file: files[i],
            isSelectionMode: isSelectionMode,
            isSelected: selectedIndexes.contains(i),
            onTap: () => onTap(i),
            onLongPress: () => onLongPress(i),
          );
        },
      ),
    );
  }
}