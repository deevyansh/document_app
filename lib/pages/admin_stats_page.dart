import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

class AdminStatsPage extends StatefulWidget {
  const AdminStatsPage({super.key});

  @override
  State<AdminStatsPage> createState() => _AdminStatsPageState();
}

class _AdminStatsPageState extends State<AdminStatsPage> {
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _stats;

  @override
  void initState() {
    super.initState();
    _runStats();
  }

  Future<void> _runStats() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await storage.read(key: "token");
      if (token == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = "Not logged in.";
        });
        return;
      }

      final res = await http
          .post(
            Uri.parse('$baseUrl/admin/stats'),
            headers: {
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode == 403) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = "Not authorized.";
        });
        return;
      }

      if (res.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = "Server error (${res.statusCode}).";
        });
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (data['success'] != true) {
        if (!mounted) return;

        setState(() {
          _loading = false;
          _error = "Failed to load statistics.";
        });

        return;
      }

      if (!mounted) return;

      setState(() {
        _loading = false;
        _stats = data;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = "Request failed: $e";
      });
    }
  }

  Widget _sectionCard({
    required String title,
    required Widget child,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final stats = _stats!;

    final docsByUser =
        (stats['docs_by_user'] as List? ?? [])
            .cast<Map<String, dynamic>>();

    final users =
        (stats['users'] as List? ?? [])
            .cast<Map<String, dynamic>>();

    final recentQueries =
        (stats['recent_queries_last_1_day'] as List? ?? [])
            .cast<Map<String, dynamic>>();

    return RefreshIndicator(
      onRefresh: _runStats,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // TOTAL DOCUMENTS
          _sectionCard(
            title: "TOTAL DOCUMENTS",
            child: Text(
              "${stats['total_docs'] ?? 0}",
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // DOCUMENTS BY USER
          _sectionCard(
            title: "DOCUMENTS BY USER",
            child: docsByUser.isEmpty
                ? const Text("No documents yet.")
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: docsByUser.map(
                      (user) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  "${user['email']}",
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                "${user['doc_count']} docs",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ).toList(),
                  ),
          ),

          // TOTAL USERS
          _sectionCard(
            title: "TOTAL USERS",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "${stats['total_users'] ?? 0}",
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                if (users.isNotEmpty) ...[
                  const SizedBox(height: 12),

                  const Divider(),

                  const SizedBox(height: 4),

                  ...users.map(
                    (user) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              "${user['email']}",
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "Created: ${user['created_at'] ?? 'Unknown'}",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),

          // SEARCHES IN LAST DAY
          _sectionCard(
            title: "SEARCHES IN THE LAST DAY",
            child: recentQueries.isEmpty
                ? const Text(
                    "No searches in the last day.",
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: recentQueries.map(
                      (query) {
                        final userName =
                            query['user_name']?.toString() ?? '';

                        final searchQuery =
                            query['query']?.toString() ?? '';

                        final docCount =
                            query['doc_count'] ?? 0;

                        final createdAt =
                            query['created_at']?.toString() ?? '';

                        return Padding(
                          padding:
                              const EdgeInsets.only(bottom: 14),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                "$userName: \"$searchQuery\"",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),

                              const SizedBox(height: 3),

                              Text(
                                "$docCount result(s)",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),

                              if (createdAt.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  createdAt,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Admin Stats"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh",
            onPressed: _loading ? null : _runStats,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && _stats == null
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            style: const TextStyle(
                              color: Colors.red,
                            ),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 16),

                          FilledButton.icon(
                            icon: const Icon(Icons.refresh),
                            label: const Text("Retry"),
                            onPressed: _runStats,
                          ),
                        ],
                      ),
                    ),
                  )
                : _stats == null
                    ? const Center(
                        child: Text("No data."),
                      )
                    : _buildResults(),
      ),
    );
  }
}