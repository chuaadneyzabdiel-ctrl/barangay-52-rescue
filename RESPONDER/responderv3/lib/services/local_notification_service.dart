import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Simple local notifications for citizen (responder assigned) and rescuer (new SOS).
class LocalNotificationService {
  static final LocalNotificationService _instance = LocalNotificationService._();
  factory LocalNotificationService() => _instance;

  LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: android);
      await _plugin.initialize(initSettings);
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _initialized = true;
    } catch (_) {}
  }

  Future<void> showResponderAssigned(String unitCallSign) async {
    if (!_initialized || kIsWeb) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'rescue_channel',
          'Rescue Updates',
          channelDescription: 'Responder and SOS updates',
          importance: Importance.defaultImportance,
        ),
      );
      await _plugin.show(
        1,
        'Help is on the way!',
        '$unitCallSign has been assigned to your SOS.',
        details,
      );
    } catch (_) {}
  }

  /// Incoming SOS chat message (when not the sender).
  Future<void> showChatMessage({
    required String senderName,
    required String preview,
  }) async {
    if (!_initialized || kIsWeb) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'chat_channel',
          'SOS Messages',
          channelDescription: 'New messages in SOS chat',
          importance: Importance.high,
        ),
      );
      final short =
          preview.length > 80 ? '${preview.substring(0, 77)}...' : preview;
      await _plugin.show(
        4100,
        'New message from $senderName',
        short,
        details,
      );
    } catch (_) {}
  }

  Future<void> showNewSOS() async {
    if (!_initialized || kIsWeb) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'rescue_channel',
          'Rescue Updates',
          channelDescription: 'Responder and SOS updates',
          importance: Importance.high,
        ),
      );
      await _plugin.show(
        2,
        'New SOS request',
        'A new emergency request needs a responder.',
        details,
      );
    } catch (_) {}
  }
}
