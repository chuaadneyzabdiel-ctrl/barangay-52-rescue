import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/rescue_provider.dart';
import '../services/chat_read_service.dart';

/// Two-way chat between citizen and rescuer for an SOS.
/// Read-only after rescue is complete + 2 hours. [completedAt] null = still active.
class SOSChatPanel extends StatefulWidget {
  final String sosId;
  final String senderRole;
  final String senderId;
  final String senderDisplayName;
  final DateTime? completedAt;
  final bool readOnly;

  /// Phone number of the other party (citizen or responder) for the call button. If null, call button is hidden.
  final String? otherPartyPhoneNumber;

  const SOSChatPanel({
    super.key,
    required this.sosId,
    required this.senderRole,
    required this.senderId,
    required this.senderDisplayName,
    this.completedAt,
    this.readOnly = false,
    this.otherPartyPhoneNumber,
  });

  @override
  State<SOSChatPanel> createState() => _SOSChatPanelState();
}

class _SOSChatPanelState extends State<SOSChatPanel> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final Stream<List<Map<String, dynamic>>> _chatStream;
  bool _reporting = false;

  bool get _canSend {
    if (widget.readOnly) return false;
    if (widget.completedAt == null) return true;
    final lockAt = widget.completedAt!.add(const Duration(hours: 2));
    return DateTime.now().isBefore(lockAt);
  }

  @override
  void initState() {
    super.initState();
    _chatStream =
        context.read<RescueProvider>().firebaseSync.watchSOSChat(widget.sosId);
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
    await ChatReadService.markReadThrough(widget.sosId, maxTs);
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || !_canSend) return;
    final provider = context.read<RescueProvider>();
    await provider.firebaseSync.sendChatMessage(
      sosId: widget.sosId,
      senderRole: widget.senderRole,
      senderId: widget.senderId,
      senderDisplayName: widget.senderDisplayName,
      text: text,
    );
    _textController.clear();
  }

  Future<void> _reportToLgu() async {
    if (widget.senderRole != 'responder' || widget.readOnly) return;
    final controller = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notify LGU'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Type the issue for LGU + citizen...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    final trimmed = msg?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    setState(() => _reporting = true);
    try {
      await context
          .read<RescueProvider>()
          .firebaseSync
          .reportResponderProblem(widget.sosId, trimmed);
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sent to LGU.')),
      );
    }
  }

  Future<void> _launchCall(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone.trim());
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  bool get _hasCitizenPhone =>
      widget.otherPartyPhoneNumber != null &&
      widget.otherPartyPhoneNumber!.trim().isNotEmpty;

  Widget _citizenPhoneHeader() {
    final phone = widget.otherPartyPhoneNumber!.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: const Color(0xFF243447),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => _launchCall(phone),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.call, color: Color(0xFF2ECC71), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Citizen: $phone',
                    style: const TextStyle(
                      color: Colors.lightGreenAccent,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                const Text(
                  'Call',
                  style: TextStyle(
                    color: Color(0xFF2ECC71),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.senderRole == 'responder' && _canSend)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: FilledButton.tonalIcon(
              onPressed: _reporting ? null : _reportToLgu,
              icon: _reporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.campaign_outlined),
              label: const Text('Notify LGU'),
            ),
          ),
        if (_hasCitizenPhone) _citizenPhoneHeader(),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _chatStream,
            builder: (context, snap) {
              final list = snap.data ?? [];
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(_markRead(list));
                if (_scrollController.hasClients) {
                  _scrollController
                      .jumpTo(_scrollController.position.maxScrollExtent);
                }
              });
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    _canSend ? 'No messages yet. Say hi!' : 'No messages.',
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
                  final imageUrl = m['imageUrl'] as String?;
                  final ts = m['timestamp'];
                  final time = ts is int
                      ? DateTime.fromMillisecondsSinceEpoch(ts)
                      : null;
                  return Align(
                    alignment:
                        isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.8,
                      ),
                      decoration: BoxDecoration(
                        color: isMe
                            ? const Color(0xFF1565C0)
                            : Colors.grey.shade700,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (imageUrl != null && imageUrl.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                imageUrl,
                                loadingBuilder: (c, w, p) {
                                  if (p == null) return w;
                                  return const SizedBox(
                                    height: 120,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  );
                                },
                                errorBuilder: (context, error, st) => const Icon(
                                  Icons.broken_image,
                                  color: Colors.white54,
                                  size: 48,
                                ),
                              ),
                            ),
                          if (text.isNotEmpty) ...[
                            if (imageUrl != null && imageUrl.isNotEmpty)
                              const SizedBox(height: 6),
                            Text(
                              text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                          if (time != null)
                            Text(
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                              ),
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
                      hintStyle:
                          TextStyle(color: Colors.grey[500], fontSize: 14),
                      filled: true,
                      fillColor: Colors.grey.shade800,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 2,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                if (widget.otherPartyPhoneNumber != null &&
                    widget.otherPartyPhoneNumber!.trim().isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: () =>
                        _launchCall(widget.otherPartyPhoneNumber!),
                    icon: const Icon(Icons.call, size: 22),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF2ECC71),
                    ),
                    tooltip: 'Call',
                  ),
                ],
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
