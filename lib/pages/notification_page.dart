import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'notification_admin_page.dart';

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
    List<dynamic> _notifications = [];

    bool _isLoading = true;
    bool _hasError = false;

    // Hidden admin shortcut
    int _adminTapCount = 0;

    @override
    void initState() {
        super.initState();
        _loadNotifications();
    }

    Future<http.Response?> _safePost(
        String path,
        Map<String, dynamic> body, {
            Map<String, String>? extraHeaders,
        }) async {
        final res = await http
            .post(
            Uri.parse('$baseUrl$path'),
            headers: {'Content-Type': 'application/json', ...?extraHeaders},
            body: jsonEncode(body),
        ).timeout(const Duration(seconds: 30));
        return res;
    }

    Future<void> _handleAdminTap() async {
        _adminTapCount++;

        // Wait for 3 consecutive taps
        if (_adminTapCount < 3) {
        return;
        }

        // Reset immediately
        _adminTapCount = 0;

        // Check logged-in user's email
        final email = await storage.read(key: 'email');

        if (!mounted) return;

        if (email == adminEmail) {
        await Navigator.push(
            context,
            MaterialPageRoute(
            builder: (_) => const NotificationAdminPage(),
            ),
        );
        }
    }

    Future<void> _loadNotifications() async {
        setState(() {
        _isLoading = true;
        _hasError = false;
        });

        try {
        final email=await storage.read(key: "email");
        final token = await storage.read(key: 'token');
        await _safePost('/read-notification', {}, extraHeaders: {'Authorization': 'Bearer $token'},);

        final response = await http.post(
            Uri.parse('$baseUrl/get-notification'),
            headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
            },
        );

        if (response.statusCode != 200) {
            throw Exception('Failed to load notifications');
        }

        final data = jsonDecode(response.body);

        if (data['success'] != true) {
            throw Exception('Failed to load notifications');
        }

        if (!mounted) return;

        setState(() {
            _notifications = data['rows'] ?? [];
            _isLoading = false;
        });
        } catch (e) {
        if (!mounted) return;

        setState(() {
            _isLoading = false;
            _hasError = true;
        });
        }
    }

    @override
    Widget build(BuildContext context) {
        return Scaffold(
        appBar: AppBar(
            title: GestureDetector(
            onTap: _handleAdminTap,
            child: const Text('Announcements'),
            ),
        ),
        body: _buildBody(),
        );
    }

    Widget _buildBody() {
        if (_isLoading) {
        return const Center(
            child: CircularProgressIndicator(),
        );
        }

        if (_hasError) {
        return _buildErrorState();
        }

        if (_notifications.isEmpty) {
        return _buildEmptyState();
        }

        return RefreshIndicator(
        onRefresh: _loadNotifications,
        child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: _notifications.length,
            itemBuilder: (context, index) {
            final notification = _notifications[index];

            return _buildNotificationCard(notification);
            },
        ),
        );
    }

    Widget _buildNotificationCard(dynamic notification) {
        final title = notification['title']?.toString() ?? '';
        final message = notification['message']?.toString() ?? '';
        final imageUrl = notification['image_url']?.toString();

        return Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
            color: Colors.grey.withValues(alpha: 0.15),
            ),
            boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 3),
            ),
            ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
                Image.network(
                imageUrl,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                    return const SizedBox.shrink();
                },
                loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) {
                    return child;
                    }

                    return const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(
                        child: CircularProgressIndicator(),
                    ),
                    );
                },
                ),

            Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                    Text(
                    title,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                    ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                    message,
                    style: TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        color: Colors.grey[700],
                    ),
                    ),

                    const SizedBox(height: 14),

                    _buildDate(notification['created_at']),
                ],
                ),
            ),
            ],
        ),
        );
    }

    Widget _buildDate(dynamic value) {
        if (value == null) {
        return const SizedBox.shrink();
        }

        DateTime? date;

        try {
        date = DateTime.parse(value.toString()).toLocal();
        } catch (_) {
        return const SizedBox.shrink();
        }

        final formatted =
            '${date.day.toString().padLeft(2, '0')}/'
            '${date.month.toString().padLeft(2, '0')}/'
            '${date.year}';

        return Text(
        formatted,
        style: TextStyle(
            fontSize: 12,
            color: Colors.grey[500],
        ),
        );
    }

    Widget _buildEmptyState() {
        return Center(
        child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                Icon(
                Icons.notifications_none,
                size: 52,
                color: Colors.grey[400],
                ),

                const SizedBox(height: 16),

                Text(
                'No announcements yet',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey[700],
                ),
                ),

                const SizedBox(height: 6),

                Text(
                'New updates and announcements will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[500],
                ),
                ),
            ],
            ),
        ),
        );
    }

    Widget _buildErrorState() {
        return Center(
        child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: Colors.grey[400],
                ),

                const SizedBox(height: 16),

                Text(
                'Couldn’t load announcements',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey[700],
                ),
                ),

                const SizedBox(height: 14),

                OutlinedButton(
                onPressed: _loadNotifications,
                child: const Text('Try Again'),
                ),
            ],
            ),
        ),
        );
    }
}