import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

/// Debug-only screen: pulls a snapshot of backend stats (document counts,
/// per-user breakdown, OTP vs Google-auth users, recent search queries)
/// from the backend's `POST /admin/stats`.
///
/// Reachable only by triple-tapping the "Profile" app bar title while
/// signed in as [adminEmail] (see the tap handler in `profile_page.dart`)
/// — that check is what keeps this screen from even being navigated to
/// for anyone else, but the backend's own check is what actually matters:
/// `/admin/stats` independently rejects (403) any request whose token
/// doesn't belong to [adminEmail], regardless of how it was reached.
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
        setState(() {
          _loading = false;
          _error = "Not logged in.";
        });
        return;
      }

      final res = await http
          .post(
        Uri.parse('$baseUrl/admin/stats'),
        headers: {'Authorization': 'Bearer $token'},
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

  Widget _sectionCard({required String title, required Widget child}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
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
    final docsByUser = (stats['docs_by_user'] as List)
        .cast<Map<String, dynamic>>();
    final nonOtpEmails = (stats['non_otp_doc_user_emails'] as List)
        .cast<dynamic>();
    final users = (stats['users'] as List).cast<Map<String, dynamic>>();
    final recentQueries = (stats['recent_queries_last_1_day'] as List)
        .cast<Map<String, dynamic>>();

    return RefreshIndicator(
      onRefresh: _runStats,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionCard(
            title: "TOTAL DOCUMENTS",
            child: Text(
              "${stats['total_docs']}",
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          _sectionCard(
            title: "DOCUMENTS BY USER",
            child: docsByUser.isEmpty
                ? const Text("No documents yet.")
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: docsByUser
                  .map(
                    (r) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    "${r['email']}  —  ${r['doc_count']} docs",
                  ),
                ),
              )
                  .toList(),
            ),
          ),

          _sectionCard(
            title: "GOOGLE / NON-OTP USERS WITH DOCUMENTS",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Count: ${stats['non_otp_doc_users_count']}"),
                if (nonOtpEmails.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ...nonOtpEmails.map((e) => Text("$e")),
                ],
              ],
            ),
          ),

          _sectionCard(
            title: "TOTAL USERS",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "${stats['total_users']}",
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                ...users.map(
                      (u) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text("${u['email']}  —  created ${u['created_at']}"),
                  ),
                ),
              ],
            ),
          ),

          _sectionCard(
            title: "SEARCHES IN THE LAST DAY",
            child: recentQueries.isEmpty
                ? const Text("No searches in the last day.")
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: recentQueries
                  .map(
                    (q) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    "${q['user_name']}: \"${q['query']}\"  →  "
                        "${q['doc_count'] ?? 0} result(s)",
                  ),
                ),
              )
                  .toList(),
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
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
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
            ? const Center(child: Text("No data."))
            : _buildResults(),
      ),
    );
  }
}