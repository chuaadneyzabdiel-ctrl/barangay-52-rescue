import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/rescue_provider.dart';
import '../services/chat_read_service.dart';

/// Separate thread: LGU ↔ Responder chat for an SOS.
/// Stored under `lgu_responder_chats/{sosId}/messages`.
class LguResponderChatPanel extends StatefulWidget {
  final String sosId;
  final String senderRole; // 'lgu' | 'responder'
  final String senderId;
  final String senderDisplayName;
  final DateTime? completedAt;
  final bool readOnly;

  const LguResponderChatPanel({
    super.key,
    required this.sosId,
    required this.senderRole,
    required this.senderId,
    required this.senderDisplayName,
    this.completedAt,
    this.readOnly = false,
  });

  @override
  State<LguResponderChatPanel> createState() => _LguResponderChatPanelState();
}

class _LguResponderChatPanelState extends State<LguResponderChatPanel> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final Stream<List<Map<String, dynamic>>> _chatStream;

  bool get _canSend {
    if (widget.readOnly) return false;
    if (widget.completedAt == null) return true;
    final lockAt = widget.completedAt!.add(const Duration(hours: 2));
    return DateTime.now().isBefore(lockAt);
  }

  @override
  void initState() {
    super.initState();
    _chatStream = context
        .read<RescueProvider>()
        .firebaseSync
        .watchLguResponderChat(widget.sosId);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markRead(List<Map<String, dynamic>> list) async {
    var maxTs = 0;
    for (final m in list) {
      final ts = (m['timestamp'] as num?)?.toInt() ?? 0;
      if (ts > maxTs) maxTs = ts;
    }
    // Reuse the same read-through marker keying by sosId.
    await ChatReadService.markReadThrough('lgu_responder_${widget.sosId}', maxTs);
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || !_canSend) return;
    await context.read<RescueProvider>().firebaseSync.sendLguResponderChatMessage(
          sosId: widget.sosId,
          senderRole: widget.senderRole,
          senderId: widget.senderId,
          senderDisplayName: widget.senderDisplayName,
          text: text,
        );
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _chatStream,
            builder: (context, snap) {
              final list = snap.data ?? [];
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(_markRead(list));
                if (_scrollController.hasClients) {
                  _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                }
              });
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    _canSend ? 'No messages yet.' : 'No messages.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14),
                  ),
                );
              }
              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final m = list[i];
                  final isMe = (m['senderRole'] as String?) == widget.senderRole;
                  final name = m['senderDisplayName'] as String? ?? 'Unknown';
                  final text = m['text'] as String? ?? '';
                  final ts = m['timestamp'];
                  final time = ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.8,
                      ),
                      decoration: BoxDecoration(
                        color: isMe ? const Color(0xFF1565C0) : Colors.grey.shade700,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (text.isNotEmpty)
                            Text(
                              text,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          if (time != null)
                            Text(
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(color: Colors.white54, fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (_canSend)
          Container(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: 8 +
                  MediaQuery.of(context).padding.bottom +
                  MediaQuery.of(context).viewInsets.bottom,
            ),
            color: const Color(0xFF1B2838),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      hintText: 'Message...',
                      hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
                      filled: true,
                      fillColor: Colors.grey.shade800,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 2,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _send,
                  icon: const Icon(Icons.send, size: 22),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF2ECC71),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'This conversation is closed.',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

