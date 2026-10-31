
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

class ImageEditPage extends StatelessWidget {
  final File file;

  const ImageEditPage({
    super.key,
    required this.file,
  });

  Future<void> _saveEditedImage(
    BuildContext context,
    List<int> bytes,
  ) async {
    try {
      final tempDir = await getTemporaryDirectory();

      final output = File(
        '${tempDir.path}/edited_image_'
        '${DateTime.now().microsecondsSinceEpoch}.jpg',
      );

      await output.writeAsBytes(bytes, flush: true);

      if (context.mounted) {
        Navigator.pop(context, output);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save image: $error'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProImageEditor.file(
      file,
      configs: ProImageEditorConfigs(
        mainEditor: MainEditorConfigs(
          tools: [
            SubEditorMode.cropRotate,
            SubEditorMode.tune,
            SubEditorMode.filter,
            SubEditorMode.blur,
            SubEditorMode.paint,
          ],
        ),
      ),
      callbacks: ProImageEditorCallbacks(
        onImageEditingComplete: (bytes) async {
          await _saveEditedImage(context, bytes);
        },
      ),
    );
  }
}
