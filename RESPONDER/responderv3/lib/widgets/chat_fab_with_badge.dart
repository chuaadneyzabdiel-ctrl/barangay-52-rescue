import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/rescue_provider.dart';
import '../services/chat_read_service.dart';
import '../services/local_notification_service.dart';

/// Chat FAB with unread count; set [suppressNotifications] while chat sheet is open.
class ChatFabWithBadge extends StatefulWidget {
  const ChatFabWithBadge({
    super.key,
    required this.sosId,
    required this.myRole,
    required this.onPressed,
    this.suppressNotifications = false,
    this.heroTag = 'chat',
  });

  final String sosId;
  final String myRole;
  final VoidCallback onPressed;
  final bool suppressNotifications;
  final Object heroTag;

  @override
  State<ChatFabWithBadge> createState() => _ChatFabWithBadgeState();
}

class _ChatFabWithBadgeState extends State<ChatFabWithBadge> {
  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  List<Map<String, dynamic>> _latest = [];
  int _unread = 0;
  int _lastNotifiedTs = 0;
  bool _primed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attach();
    });
  }

  @override
  void didUpdateWidget(ChatFabWithBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sosId != widget.sosId) {
      _sub?.cancel();
      _primed = false;
      _lastNotifiedTs = 0;
      _attach();
    }
  }

  void _attach() {
    final stream =
        context.read<RescueProvider>().firebaseSync.watchSOSChat(widget.sosId);
    _sub = stream.listen(_onMessages);
  }

  Future<void> _onMessages(List<Map<String, dynamic>> list) async {
    if (!mounted) return;
    _latest = list;

    final readMs = await ChatReadService.getLastReadMs(widget.sosId);
    var unread = 0;
    for (final m in list) {
      final ts = (m['timestamp'] as num?)?.toInt() ?? 0;
      final role = m['senderRole'] as String? ?? '';
      if (role != widget.myRole && ts > readMs) unread++;
    }

    if (!_primed) {
      _primed = true;
      for (final m in list) {
        final ts = (m['timestamp'] as num?)?.toInt() ?? 0;
        final role = m['senderRole'] as String? ?? '';
        if (role != widget.myRole && ts > _lastNotifiedTs) {
          _lastNotifiedTs = ts;
        }
      }
      if (mounted) setState(() => _unread = unread);
      return;
    }

    if (!widget.suppressNotifications) {
      for (final m in list) {
        final ts = (m['timestamp'] as num?)?.toInt() ?? 0;
        final role = m['senderRole'] as String? ?? '';
        if (role != widget.myRole && ts > _lastNotifiedTs) {
          _lastNotifiedTs = ts;
          final name = m['senderDisplayName'] as String? ?? 'Contact';
          final text = m['text'] as String? ?? '';
          final img = m['imageUrl'] as String?;
          final preview =
              img != null && img.isNotEmpty ? '📷 Image' : (text.isEmpty ? 'Message' : text);
          unawaited(
            LocalNotificationService().showChatMessage(
              senderName: name,
              preview: preview,
            ),
          );
          break;
        }
      }
    }

    if (mounted) setState(() => _unread = unread);
  }

  Future<void> _markReadNow() async {
    var maxTs = 0;
    for (final m in _latest) {
      final ts = (m['timestamp'] as num?)?.toInt() ?? 0;
      if (ts > maxTs) maxTs = ts;
    }
    await ChatReadService.markReadThrough(widget.sosId, maxTs);
    if (mounted) setState(() => _unread = 0);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        FloatingActionButton.small(
          heroTag: widget.heroTag,
          onPressed: () async {
            await _markReadNow();
            widget.onPressed();
          },
          backgroundColor: const Color(0xFF1B3A5C),
          child: const Icon(Icons.chat, color: Colors.white),
        ),
        if (_unread > 0)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1),
              ),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              child: Text(
                _unread > 9 ? '9+' : '$_unread',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}
