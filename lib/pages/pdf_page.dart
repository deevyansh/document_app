import 'dart:io';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart' as pdfx;


class PdfPage extends StatefulWidget {
  final File file;
  const PdfPage({required this.file});
  @override
  State<PdfPage> createState() => _PdfPageState();
}

class _PdfPageState extends State<PdfPage> {
  pdfx.PdfControllerPinch? _controller;   // nullable — not created yet

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() {
        _controller = pdfx.PdfControllerPinch(
          document: pdfx.PdfDocument.openFile(widget.file.path),
        );
      });
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      // shown instantly while the swipe animates
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return pdfx.PdfViewPinch(controller: _controller!);
  }
}
