import 'dart:async';                          // TimeoutException
import 'dart:convert';                        // jsonDecode
import 'dart:io';                             // File, SocketException

import 'package:flutter/material.dart';       // Scaffold, AppBar, TextField, etc.
import 'package:flutter/services.dart';       // PlatformException

import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart';   // XFile
import 'package:flutter_quill/flutter_quill.dart';  // Document.fromJson / toPlainText

import '../constants.dart';                   // baseUrl, storage, caption, DocumentTypeFilter, methodChannel — check exact source below
import '../widgets/document_grid.dart';        // DocumentGrid
import 'full_screen_image.dart';               // FullScreenImage (adjust relative path to your actual folder)

class SearchPage extends StatefulWidget {
  final bool autoStartListening;

  const SearchPage({super.key, this.autoStartListening = false});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
    bool _isSearching=false;
    bool _hasSearched=false;
    bool _isSelectedMode = false;
    Set<int> _selectedIndexes = {};
    bool _islistening = false;
    String _querytext = "What are you looking for";
    List<File> _queryphotos = [];
    List<File> _querylimitphotos=[];

    bool _loadMore=false;

    final FocusNode _queryFocusNode = FocusNode();
    final _enToHi = OnDeviceTranslator(
        sourceLanguage: TranslateLanguage.english,
        targetLanguage: TranslateLanguage.hindi,
    );
    final _queryController = TextEditingController();
    final _hiToEn = OnDeviceTranslator(
        sourceLanguage: TranslateLanguage.hindi,
        targetLanguage: TranslateLanguage.english,
    );
    final _modelManager = OnDeviceTranslatorModelManager();
    DocumentTypeFilter _typefilter = DocumentTypeFilter.all;

    Future<bool> _hindiReady() async {
        return await _modelManager.isModelDownloaded(
        TranslateLanguage.hindi.bcpCode,
        );
    }

    Future<void> delete(List<String> files) async {
        final token = await storage.read(key: "token");
        if (token == null) return;
        for (final file in files) {
        await File(file).delete();
        http.post(
            Uri.parse('$baseUrl/delete-document'),
            headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'doc_path': file}),
        );
        }
    }

    @override
    void initState(){
        super.initState();
        _ensureHindiModel();
        WidgetsBinding.instance.addPostFrameCallback((_) {
            _queryFocusNode.requestFocus();
            if (widget.autoStartListening) {
            _startListening();
            }
        });
    }


    @override
    void dispose(){
        _enToHi.close();
        _hiToEn.close();
        _queryController.dispose();
        _queryFocusNode.dispose();
        super.dispose();
    }

    void _handleGridTap(List<File> files, int i, {required VoidCallback onOpen}) {
        if (!_isSelectedMode) {
        onOpen(); // parent-specific: open fullscreen
        } else {
        if (_selectedIndexes.contains(i)) {
            setState(() {
            _selectedIndexes.remove(i);
            if (_selectedIndexes.isEmpty) _isSelectedMode = false;
            });
        } else {
            if (_selectedIndexes.length >= 5) {
            _showError("You cannot share more than 5 at once");
            } else {
            setState(() => _selectedIndexes.add(i));
            }
        }
        }
    }

    Future<void> _ensureHindiModel() async {
        final downloaded = await _modelManager.isModelDownloaded(
        TranslateLanguage.hindi.bcpCode,
        );
        if (!downloaded) {
        await _modelManager.downloadModel(
            TranslateLanguage.hindi.bcpCode,
            isWifiRequired: false, // let it use mobile data too
        );
        }
    }

    void _showError(String message) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: Colors.red,
            content: Text(
            message,
            style: const TextStyle(
                fontSize: 16, // Increase as needed
                color: Colors.white,
                fontWeight: FontWeight.w500,
            ),
            ),
        ),
        );
    }

    Future<http.Response?> _safePost(
        String path,
        Map<String, dynamic> body, {
        Map<String, String>? extraHeaders,
    }) async {
        try {
        final res = await http
            .post(
                Uri.parse('$baseUrl$path'),
                headers: {'Content-Type': 'application/json', ...?extraHeaders},
                body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 30));

        if (res.statusCode >= 500) {
            _showError("Server is temporarily unavailable. Please try again.");
            return null;
        }
        return res;
        } on SocketException {
        _showError("No internet connection.");
        return null;
        } on TimeoutException {
        _showError("Request timed out. Please try again.");
        return null;
        } catch (e) {
        _showError("Something went wrong.");
        return null;
        }
    }


    Future<bool> _hasInternet() async {
        final result = await Connectivity().checkConnectivity();
        return !result.contains(ConnectivityResult.none);
    }

    Future<void> _loadqueryphotos(List<dynamic> results) async {
        final files = results
            .map((r) => File(r['doc_path'] as String))
            .where((f) => f.existsSync())
            .toList();
        if (!mounted) return;
        setState((){
            _queryphotos = files.toList();
            _querylimitphotos=files.take(5).toList();
        }); // Limit to max 5
    }

    Future<String?> _transliterateToHindi(String text) async {
        if (text.trim().isEmpty) return null;
        try {
        final uri = Uri.parse(
            'https://inputtools.google.com/request'
            '?text=${Uri.encodeComponent(text)}'
            '&itc=hi-t-i0-und'
            '&num=1&cp=0&cs=1&ie=utf-8&oe=utf-8',
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 3));
        if (res.statusCode != 200) return null;

        final data = jsonDecode(res.body);
        // Response shape: ["SUCCESS",[["transport",["ट्रांसपोर्ट","ट्रान्सपोर्ट"]]]]
        if (data[0] == "SUCCESS") {
            final suggestions = data[1][0][1] as List;
            if (suggestions.isNotEmpty) return suggestions.first as String;
        }
        } catch (e) {
        print("transliteration failed: $e");
        }
        return null;
    }

    void _toggleLoadMore() {
        setState(() {
            _loadMore = !_loadMore;
            _selectedIndexes.clear();
            _isSelectedMode = false;
        });
    }

    Future<void> _queryDocument() async {
        setState((){
            _isSearching=true;
            _loadMore=false;
        });
        final sw = Stopwatch()..start();
        final token = await storage.read(key: 'token');
        if (token == null) return;
        final raw = _queryController.text.trim();
        final terms = <String>{raw};

        if (await _hindiReady()) {
        final results = await Future.wait([
            _enToHi.translateText(raw),
            _hiToEn.translateText(raw),
        ]);
        terms.addAll(results);
        }

        // translit is removed because the sometimes the translit = translate and this is causing the problem a bit high
        // final translit = await _transliterateToHindi(raw);
        // if (translit != null) {
        //   print("translit $translit");
        //   terms.add(translit);
        // }

        final combined = terms.join(' ');

        String? x;
        if (_typefilter == DocumentTypeFilter.all) {
            x = "all";
        } else if (_typefilter == DocumentTypeFilter.pdf) {
            x = "pdf";
        } else {
            x = "img";
        }
        final res = await _safePost(
            "/search-document",
            {'user_query': combined, 'type_filter': x},
            extraHeaders: {'Authorization': 'Bearer $token'},
        );
        if (res == null) {
            return;
        }
        final data = jsonDecode(res.body);
            await _loadqueryphotos(data["results"]);
        setState((){
            _isSearching=false;
            _hasSearched=true;
        });
    }

    Future<void> _startListening() async {
        setState(() {
        _querytext = "Listening..";
        _islistening = true;
        });

        try {
        final String? spokenText = await methodChannel.invokeMethod<String>(
            'startSpeechRecognition',
        );

        if (spokenText != null && spokenText.trim().isNotEmpty) {
            _queryController.text = spokenText;
            await _queryDocument();
        }
        } on PlatformException catch (e) {
        _showError("Voice search unavailable: ${e.message}");
        } finally {
        if (mounted) {
            setState(() {
            _querytext = "What are you looking for";
            _islistening = false;
            });
        }
        }
    }

    Future<void> _pressmicbutton() async {
        await _startListening();
    }

    PreferredSizeWidget _selectAppBar(String window) {
        return AppBar(
        leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: "Deselect all",
            onPressed: () async {
            setState(() {
                _selectedIndexes.clear();
                _isSelectedMode = false;
            });
            },
        ),
        title: Text("${_selectedIndexes.length} selected"),
        actions: [
            IconButton(
            icon: const Icon(Icons.share),
            tooltip: "Share",
            onPressed: () async {
                final selectedFiles = _selectedIndexes
                    .map((i) => _loadMore ? _queryphotos[i]: _querylimitphotos[i])
                    .toList();

                final fileShares = <XFile>[];
                final noteTexts = <String>[];

                for (final file in selectedFiles) {
                    if (file.path.endsWith('.json')) {
                    final json = jsonDecode(await file.readAsString());

                    final document = Document.fromJson(
                        List<Map<String, dynamic>>.from(json["delta"]),
                    );

                    noteTexts.add(document.toPlainText());
                    } else {
                    fileShares.add(XFile(file.path));
                    }
                }

                final hasPdf = fileShares.any((f) => f.path.endsWith('.pdf'));
                final hasImage = fileShares.any(
                    (f) =>
                        f.path.endsWith('.jpg') ||
                        f.path.endsWith('.jpeg') ||
                        f.path.endsWith('.png'),
                );

                final isMixed = hasPdf && hasImage;

                String? shareText;
                if (noteTexts.isNotEmpty) {
                    shareText = noteTexts.join("\n\n--------------------\n\n");

                    if (fileShares.isNotEmpty && !isMixed) {
                    shareText = "$shareText\n\n$caption";
                    }
                } else {
                    shareText = isMixed ? null : caption;
                }

                if (fileShares.isEmpty) {
                    await Share.share(shareText!, subject: "Shared via DocEzy");
                } else {
                    await SharePlus.instance.share(
                    ShareParams(
                        files: fileShares,
                        text: shareText,
                        subject: "Shared via DocEzy",
                    ),
                    );
                }
                setState(() {
                _selectedIndexes.clear();
                _isSelectedMode = false;
                });
            },
            ),

            IconButton(
            icon: const Icon(Icons.delete),
            tooltip: "Delete",
            onPressed: () async {
                final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                    title: const Text('Delete documents?'),
                    content: Text(
                    'Delete ${_selectedIndexes.length} document(s)? This cannot be undone.',
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
                if (confirmed != true) {
                return;
                }
                final pathsToDelete = _selectedIndexes
                    .map(
                    (i) =>  _loadMore ? _queryphotos[i].path: _querylimitphotos[i].path,
                    )
                    .toList();
                await delete(pathsToDelete);
                _queryDocument();
                setState(() {
                _selectedIndexes.clear();
                _isSelectedMode = false;
                });
            },
            ),
        ],
        );
    }

    void _handleGridLongPress(int i) {
        if (!_isSelectedMode) {
        setState(() {
            _isSelectedMode = true;
            _selectedIndexes.add(i);
        });
        }
    }

    @override
    Widget build(BuildContext context) {
        return Scaffold(
        appBar: (!_isSelectedMode)
            ? AppBar(
                title: const Text('Search Documents'),
                leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: (){
                        Navigator.pop(context);
                    },
                ),
                )
            : _selectAppBar("Query"),
        body: SafeArea(
            child: Column(
                children: [
                Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                    children: [
                    Expanded(
                    child: TextField(
                        controller: _queryController,
                        focusNode: _queryFocusNode,
                        decoration: InputDecoration(
                        hintText: _querytext,
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                        ),
                        suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                            IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () => _queryController.clear(),
                            ),
                            IconButton(
                                icon: Icon(
                                _islistening ? Icons.stop_circle : Icons.mic,
                                ),
                                tooltip: 'Speak',
                                onPressed: _pressmicbutton,
                            ),
                            ],
                        ),
                        ),
                        onSubmitted: (_) => _queryDocument(),
                    ),
                    ),
                    Stack(
                    clipBehavior: Clip.none,
                    children: [
                        IconButton(
                        icon: const Icon(Icons.tune_rounded),
                        onPressed: () async {
                            final res = await _filterSelection();

                            if (res != null) {
                            setState(() {
                                _typefilter = res;
                            });

                            await _queryDocument();
                            }
                        },
                        ),

                        if (_typefilter != DocumentTypeFilter.all)
                        Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                                "1",
                                style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                ),
                            ),
                            ),
                        ),
                    ],
                    ),
                ],
                ),
            ),
            Expanded(
                child: _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : !_hasSearched
                        ? const Center(
                            child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                                Icon(Icons.search, size: 80, color: Colors.grey),
                                SizedBox(height: 16),
                                Text(
                                'Search your documents',
                                style: TextStyle(fontSize: 18),
                                ),
                                SizedBox(height: 4),
                                Text(
                                'Type a keyword or tap the mic to search by voice',
                                style: TextStyle(fontSize: 13, color: Colors.grey),
                                ),
                            ],
                            ),
                        )
                        : _queryphotos.isEmpty
                            ? const Center(
                                child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                    Icon(Icons.search_off, size: 80, color: Colors.grey),
                                    SizedBox(height: 16),
                                    Text('No results found', style: TextStyle(fontSize: 18)),
                                ],
                                ),
                            )
                            : Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                child: Column(
                                children: [
                                    Expanded(
                                    child: DocumentGrid(
                                        files: _loadMore ? _queryphotos : _querylimitphotos,
                                        crossAxisCount: 2,
                                        childAspectRatio: 0.72,
                                        isSelectionMode: _isSelectedMode,
                                        selectedIndexes: _selectedIndexes,
                                        onLongPress: _handleGridLongPress,
                                        onTap: (i) => _handleGridTap(
                                        _loadMore ? _queryphotos : _querylimitphotos,
                                        i,
                                        onOpen: () async {
                                            final deleted = await Navigator.push<bool>(
                                            context,
                                            MaterialPageRoute(
                                                builder: (_) => FullScreenImage(
                                                files: _loadMore ? _queryphotos : _querylimitphotos,
                                                startIndex: i,
                                                ),
                                            ),
                                            );
                                            if (deleted == true) {
                                            await _queryDocument();
                                            }
                                        },
                                        ),
                                    ),
                                    ),

                                    if (!_loadMore && _queryphotos.length > 5)
                                    Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 12.0),
                                        child: TextButton(
                                        onPressed: _toggleLoadMore,
                                        child: Text(
                                            "Load more (${_queryphotos.length - 5} more)",
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                        ),
                                    ),
                                ],
                                ),
                            ),
                            
            ),
            ],
        ),
        ),
        );
    }

    Future<DocumentTypeFilter?> _filterSelection() async {
        DocumentTypeFilter selected = _typefilter;

        return await showDialog<DocumentTypeFilter>(
        context: context,
        builder: (context) {
            return StatefulBuilder(
            builder: (context, setDialogState) {
                return AlertDialog(
                title: const Text("Filter Documents"),

                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    RadioListTile<DocumentTypeFilter>(
                        title: const Text("All"),
                        value: DocumentTypeFilter.all,
                        groupValue: selected,
                        onChanged: (value) {
                        setDialogState(() {
                            selected = value!;
                        });
                        },
                    ),

                    RadioListTile<DocumentTypeFilter>(
                        title: const Text("Images"),
                        value: DocumentTypeFilter.image,
                        groupValue: selected,
                        onChanged: (value) {
                        setDialogState(() {
                            selected = value!;
                        });
                        },
                    ),

                    RadioListTile<DocumentTypeFilter>(
                        title: const Text("PDFs"),
                        value: DocumentTypeFilter.pdf,
                        groupValue: selected,
                        onChanged: (value) {
                        setDialogState(() {
                            selected = value!;
                        });
                        },
                    ),
                    ],
                ),

                actions: [
                    TextButton(
                    onPressed: () {
                        Navigator.pop(context);
                    },
                    child: const Text("Cancel"),
                    ),

                    ElevatedButton(
                    onPressed: () {
                        Navigator.pop(context, selected);
                    },
                    child: const Text("Apply"),
                    ),
                ],
                );
            },
            );
        },
        );
    }
}