import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import 'package:http/http.dart' as http;
import 'dart:math';

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  late final QuillController _controller;
  final FocusNode _editorFocusNode = FocusNode();
  final ScrollController _editorScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = QuillController.basic();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _editorFocusNode.requestFocus();
    });
  }

  Future<void> _saveNote() async {
    final dir = await getApplicationDocumentsDirectory();

    final file = File(
      "${dir.path}/${DateTime.now().millisecondsSinceEpoch}.json",
    );

    final delta = _controller.document.toDelta().toJson();
    final plainText = _controller.document.toPlainText();
    final preview = plainText.substring(0, min(150, plainText.length));

    final token = await storage.read(key: 'token');

    final json = jsonEncode({"preview": preview, "delta": delta});
    await file.writeAsString(json);

    await http.post(
      Uri.parse("$baseUrl/send-document"),
      headers: {
        "Authorization": "Bearer $token",
        "Content-Type": "application/json",
      },
      body: jsonEncode({"doc_path": file.path, "text": plainText}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text("Notes")),
      body: Column(
        children: [
          QuillSimpleToolbar(
            controller: _controller,
            config: const QuillSimpleToolbarConfig(),
          ),
          Expanded(
            child: QuillEditor(
              focusNode: _editorFocusNode,
              scrollController: _editorScrollController,
              controller: _controller,
              config: QuillEditorConfig(
                placeholder: 'Start writing your note...',
                padding: const EdgeInsets.all(16),
                // This forces correct text color in both light & dark themes
                customStyles: DefaultStyles(
                  paragraph: DefaultTextBlockStyle(
                    TextStyle(
                      fontSize: 16,
                      color: isDark ? Colors.white : Colors.black87,
                      height: 1.4,
                    ),
                    const HorizontalSpacing(0, 0),
                    const VerticalSpacing(0, 6),
                    const VerticalSpacing(0, 0),
                    null,
                  ),
                  placeHolder: DefaultTextBlockStyle(
                    TextStyle(
                      fontSize: 16,
                      color: isDark
                          ? Colors.grey.shade500
                          : Colors.grey.shade600,
                    ),
                    const HorizontalSpacing(0, 0),
                    const VerticalSpacing(0, 0),
                    const VerticalSpacing(0, 0),
                    null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: "save_note",
        onPressed: () async {
          await _saveNote();
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text("Saved")));
          }
        },
        tooltip: "Save",
        child: const Icon(Icons.save_outlined),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _editorFocusNode.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }
}
