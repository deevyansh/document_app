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
  pdfx.PdfControllerPinch? _controller;   
  int _currentPage = 1;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 200), () {
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
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        pdfx.PdfViewPinch(
          controller: _controller!,
          onDocumentLoaded: (document) {
            setState(() {
              _totalPages = document.pagesCount;
            });
          },
          onPageChanged: (page) {
            setState(() {
              _currentPage = page;
            });
          },
        ),
        Positioned(
          bottom: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$_currentPage / $_totalPages',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }
}
