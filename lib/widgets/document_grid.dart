import 'dart:io';
import 'package:flutter/material.dart';

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

  /// NEW: renders a single document thumbnail.
  static Widget buildTile({
    required File file,
    required bool isSelectionMode,
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    final isPdf = file.path.endsWith('.pdf');

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
                      File('${file.path}.thumb.jpg'),
                      fit: BoxFit.cover,
                      cacheWidth: 500,
                    )
                  : Image.file(
                      file,
                      fit: BoxFit.cover,
                      cacheWidth: 500,
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
                child: Icon(
                  Icons.check,
                  size: 16,
                  color: Colors.white,
                ),
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