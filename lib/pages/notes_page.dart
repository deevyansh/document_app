import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import 'package:http/http.dart' as http;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import '../backup_service.dart';

enum _ToolSection { text, color, formatting }

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final QuillController _controller = QuillController.basic();
  final FocusNode _editorFocusNode = FocusNode();
  final ScrollController _editorScrollController = ScrollController();

  _ToolSection? _expandedSection;

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
    await BackupService.registerPendingBackup(file.path);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _editorFocusNode.requestFocus();
    });
  }

  void _toggleSection(_ToolSection section) {
    setState(() {
      _expandedSection = _expandedSection == section ? null : section;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _editorFocusNode.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final barColor = isDark ? Colors.grey.shade900 : Colors.white;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Notes"),
        actions: [
          IconButton(
            icon: const Icon(Icons.check, size: 30),
            tooltip: "Save the Note",
            onPressed: () async {
              await _saveNote();
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text("Saved")));
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: QuillEditor(
              focusNode: _editorFocusNode,
              scrollController: _editorScrollController,
              controller: _controller,
              config: QuillEditorConfig(
                placeholder: 'Start writing your note...',
                padding: const EdgeInsets.all(16),
                customStyles: DefaultStyles(
                  paragraph: DefaultTextBlockStyle(
                    TextStyle(
                      fontSize: 22,
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
                      fontSize: 22,
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

          // ── Custom bottom toolbar (sits above keyboard automatically) ──
          Container(
            decoration: BoxDecoration(
              color: barColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 4,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeInOut,
                    child: _expandedSection == null
                        ? const SizedBox(width: double.infinity, height: 0)
                        : _buildSubToolsRow(isDark),
                  ),
                  _buildCategoryRow(isDark),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Main row: 3 category buttons (left) + Undo/Redo (right) ──
  Widget _buildCategoryRow(bool isDark) {
    return SizedBox(
      height: 65,
      child: Row(
        children: [
          _categoryButton(
            icon: Icons.text_fields,
            label: "Text",
            section: _ToolSection.text,
          ),
          _categoryButton(
            icon: Icons.palette_outlined,
            label: "Color",
            section: _ToolSection.color,
          ),
          _categoryButton(
            icon: Icons.format_list_bulleted,
            label: "Format",
            section: _ToolSection.formatting,
          ),
          const Spacer(),
          QuillToolbarHistoryButton(
            controller: _controller,
            options: const QuillToolbarHistoryButtonOptions(),
            isUndo: true,
          ),
          QuillToolbarHistoryButton(
            controller: _controller,
            options: const QuillToolbarHistoryButtonOptions(),
            isUndo: false,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _categoryButton({
    required IconData icon,
    required String label,
    required _ToolSection section,
  }) {
    final isActive = _expandedSection == section;
    return InkWell(
      onTap: () => _toggleSection(section),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        color: isActive
            ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
            : Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 27,
              color: isActive ? Theme.of(context).colorScheme.primary : null,
            ),
          ],
        ),
      ),
    );
  }

  // ── Sub-tools strip, shown above the category row ──
  Widget _buildSubToolsRow(bool isDark) {
    switch (_expandedSection) {
      case _ToolSection.text:
        return _subToolsContainer(_textTools());
      case _ToolSection.color:
        return _subToolsContainer(_colorTools());
      case _ToolSection.formatting:
        return _subToolsContainer(_formattingTools());
      case null:
        return const SizedBox.shrink();
    }
  }

  Widget _subToolsContainer(List<Widget> tools) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey.withOpacity(0.2)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: tools),
      ),
    );
  }

  // ── Section 1: Text ──
  List<Widget> _textTools() {
    return [
      QuillToolbarFontFamilyButton(controller: _controller),
      QuillToolbarFontSizeButton(controller: _controller),
      const VerticalDivider(width: 12),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.bold,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.italic,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.underline,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.strikeThrough,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.subscript,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.superscript,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      const VerticalDivider(width: 12),
      QuillToolbarSelectHeaderStyleDropdownButton(controller: _controller),
    ];
  }

  // ── Section 2: Color Palette ──
  List<Widget> _colorTools() {
    return [
      QuillToolbarColorButton(
        controller: _controller,
        isBackground: false,
        options: const QuillToolbarColorButtonOptions(),
      ),
      QuillToolbarColorButton(
        controller: _controller,
        isBackground: true,
        options: const QuillToolbarColorButtonOptions(),
      ),
      const VerticalDivider(width: 12),
      QuillToolbarClearFormatButton(controller: _controller),
    ];
  }

  // ── Section 3: Formatting ──
  List<Widget> _formattingTools() {
    return [
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.ol,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.ul,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleCheckListButton(
        controller: _controller,
        options: const QuillToolbarToggleCheckListButtonOptions(),
      ),
      const VerticalDivider(width: 12),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.codeBlock,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      QuillToolbarToggleStyleButton(
        controller: _controller,
        attribute: Attribute.blockQuote,
        options: const QuillToolbarToggleStyleButtonOptions(),
      ),
      const VerticalDivider(width: 12),
      QuillToolbarIndentButton(
        controller: _controller,
        isIncrease: true,
        options: const QuillToolbarIndentButtonOptions(),
      ),
      QuillToolbarIndentButton(
        controller: _controller,
        isIncrease: false,
        options: const QuillToolbarIndentButtonOptions(),
      ),
    ];
  }
}