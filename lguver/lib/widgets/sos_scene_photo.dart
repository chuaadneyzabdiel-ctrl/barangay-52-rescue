import 'dart:convert';

import 'package:flutter/material.dart';

/// Optional SOS scene photo. Supports https URLs and data:image...;base64,...
class SosScenePhotoThumb extends StatelessWidget {
  final String? photoUrl;
  final double height;

  const SosScenePhotoThumb({
    super.key,
    required this.photoUrl,
    this.height = 120,
  });

  bool get hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  static ImageProvider? imageProviderFor(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('data:')) {
      final comma = trimmed.indexOf(',');
      if (comma < 0) return null;
      try {
        return MemoryImage(base64Decode(trimmed.substring(comma + 1)));
      } catch (_) {
        return null;
      }
    }
    return NetworkImage(trimmed);
  }

  static void showFull(BuildContext context, String url) {
    final provider = imageProviderFor(url);
    if (provider == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image(image: provider, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filled(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPhoto) return const SizedBox.shrink();
    final provider = imageProviderFor(photoUrl!.trim());
    if (provider == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        onTap: () => showFull(context, photoUrl!.trim()),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image(
            image: provider,
            height: height,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
