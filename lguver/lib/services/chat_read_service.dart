import 'package:shared_preferences/shared_preferences.dart';

/// Persists last-read chat timestamp per SOS (for unread badge).
class ChatReadService {
  ChatReadService._();
  static const _prefix = 'chat_last_read_ts_';

  static Future<int> getLastReadMs(String sosId) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('$_prefix$sosId') ?? 0;
  }

  static Future<void> setLastReadMs(String sosId, int timestampMs) async {
    final p = await SharedPreferences.getInstance();
    final cur = p.getInt('$_prefix$sosId') ?? 0;
    if (timestampMs > cur) {
      await p.setInt('$_prefix$sosId', timestampMs);
    }
  }

  /// Marks all messages up to [maxMessageTs] as read.
  static Future<void> markReadThrough(String sosId, int maxMessageTs) async {
    await setLastReadMs(sosId, maxMessageTs);
  }
}
