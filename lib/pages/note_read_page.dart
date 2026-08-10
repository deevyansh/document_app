import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class NoteReadPage extends StatefulWidget {
  final File file;

  const NoteReadPage({super.key, required this.file});

  @override
  State<NoteReadPage> createState() => _NoteReadPageState();
}

class _NoteReadPageState extends State<NoteReadPage> {
  QuillController? _controller;

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  Future<void> _loadNote() async {
    final jsonString = await widget.file.readAsString();
    final json = jsonDecode(jsonString);

    final document = Document.fromJson(
      List<Map<String, dynamic>>.from(json["delta"]),
    );

    _controller = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
      readOnly: true,
    );

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: QuillEditor.basic(
          controller: _controller!,
          config: const QuillEditorConfig(padding: EdgeInsets.all(16)),
        ),
      ),
    );
  }
}
