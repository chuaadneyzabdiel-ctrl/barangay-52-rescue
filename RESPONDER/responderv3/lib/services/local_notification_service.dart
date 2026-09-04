import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications for rescuer (new SOS) and SOS chat.
class LocalNotificationService {
  static final LocalNotificationService _instance = LocalNotificationService._();
  factory LocalNotificationService() => _instance;

  LocalNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _sosAlarmId = 2002;
  static const _sosAlarmChannelId = 'sos_alarm_channel';

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: android);
      await _plugin.initialize(initSettings);
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
      // New channel: Android freezes sound settings on the old rescue_channel.
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _sosAlarmChannelId,
          'SOS Alarms',
          description: 'Urgent incoming SOS alerts for responders',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          showBadge: true,
        ),
      );
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

  /// Incoming SOS alarm: max-priority sound + vibration, SOS type in the title.
  Future<void> showNewSOS({
    String? typeLabel,
    String? citizenName,
    bool escalate = false,
  }) async {
    if (!_initialized || kIsWeb) return;
    try {
      final type = (typeLabel ?? '').trim();
      final title = escalate
          ? (type.isEmpty ? 'SOS still waiting' : 'SOS still waiting — $type')
          : (type.isEmpty ? 'New SOS request' : 'New SOS — $type');
      final who = (citizenName ?? '').trim();
      final body = who.isEmpty
          ? 'A new emergency request needs a responder.'
          : (escalate
              ? '$who is still waiting for a responder.'
              : '$who needs a responder.');
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _sosAlarmChannelId,
          'SOS Alarms',
          channelDescription: 'Urgent incoming SOS alerts for responders',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          enableLights: true,
          category: AndroidNotificationCategory.alarm,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          visibility: NotificationVisibility.public,
          ticker: title,
          vibrationPattern: Int64List.fromList([0, 600, 250, 600, 250, 900]),
        ),
      );
      await _plugin.show(_sosAlarmId, title, body, details);
    } catch (_) {}
  }

  Future<void> cancelIncomingSosAlarm() async {
    if (!_initialized || kIsWeb) return;
    try {
      await _plugin.cancel(_sosAlarmId);
    } catch (_) {}
  }
}
