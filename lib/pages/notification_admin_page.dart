import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

class NotificationAdminPage extends StatefulWidget {
  const NotificationAdminPage({super.key});

  @override
  State<NotificationAdminPage> createState() =>
      _NotificationAdminPageState();
}

class _NotificationAdminPageState extends State<NotificationAdminPage> {
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();
  final _imageUrlController = TextEditingController();

  bool _isPosting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _messageController.dispose();
    _imageUrlController.dispose();
    super.dispose();
  }

  Future<void> _postNotification() async {
    final title = _titleController.text.trim();
    final message = _messageController.text.trim();
    final imageUrl = _imageUrlController.text.trim();

    if (title.isEmpty) {
      _showMessage('Please enter a title.');
      return;
    }

    if (message.isEmpty) {
      _showMessage('Please enter a message.');
      return;
    }

    setState(() {
      _isPosting = true;
    });

    try {
      final token = await storage.read(key: 'token');

      final response = await http.post(
        Uri.parse('$baseUrl/post-notification'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null)
            'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'title': title,
          'text': message,
          'image_url': imageUrl.isEmpty ? null : imageUrl,
        }),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 &&
          data['success'] == true) {
        _titleController.clear();
        _messageController.clear();
        _imageUrlController.clear();

        if (!mounted) return;

        _showMessage(
          'Notification posted successfully.',
        );
      } else {
        _showMessage(
          data['detail'] ??
              data['message'] ??
              'Failed to post notification.',
        );
      }
    } catch (e) {
      _showMessage(
        'Something went wrong. Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPosting = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Announcement'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),

              const SizedBox(height: 28),

              _buildTitleField(),

              const SizedBox(height: 18),

              _buildMessageField(),

              const SizedBox(height: 18),

              _buildImageUrlField(),

              const SizedBox(height: 28),

              _buildPreview(),

              const SizedBox(height: 28),

              _buildPostButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.campaign_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),

            const SizedBox(width: 12),

            const Expanded(
              child: Text(
                'New Announcement',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        Text(
          'Create an announcement that will be visible to DocEzy users.',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildTitleField() {
    return TextField(
      controller: _titleController,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: 'Title',
        hintText: 'e.g. New QR Search Feature',
        prefixIcon: const Icon(Icons.title_outlined),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Widget _buildMessageField() {
    return TextField(
      controller: _messageController,
      textCapitalization: TextCapitalization.sentences,
      maxLines: 6,
      decoration: InputDecoration(
        labelText: 'Message',
        hintText: 'Write your announcement...',
        alignLabelWithHint: true,
        prefixIcon: const Padding(
          padding: EdgeInsets.only(bottom: 80),
          child: Icon(Icons.notes_outlined),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Widget _buildImageUrlField() {
    return TextField(
      controller: _imageUrlController,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        labelText: 'Image URL (optional)',
        hintText: 'https://...',
        prefixIcon: const Icon(Icons.image_outlined),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.grey.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),

          const SizedBox(height: 12),

          Text(
            _titleController.text.isEmpty
                ? 'Announcement title'
                : _titleController.text,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 6),

          Text(
            _messageController.text.isEmpty
                ? 'Your announcement message will appear here.'
                : _messageController.text,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPostButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: _isPosting ? null : _postNotification,
        icon: _isPosting
            ? const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.send_outlined),
        label: Text(
          _isPosting
              ? 'Posting...'
              : 'Post Announcement',
        ),
      ),
    );
  }
}