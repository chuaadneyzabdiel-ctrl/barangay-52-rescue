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

  /// Citizen milestone: responder is very close to pickup point.
  Future<void> showResponderNearby({required int meters}) async {
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
      final safeMeters = meters.clamp(0, 30);
      await _plugin.show(
        3,
        'Responder is nearby',
        'Your responder is about ${safeMeters}m away. Please be ready.',
        details,
      );
    } catch (_) {}
  }

  /// Citizen milestone: patient has been picked up and transport started.
  Future<void> showPickupStarted({String? destinationName}) async {
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
      final body = destinationName != null && destinationName.trim().isNotEmpty
          ? 'Now on route to ${destinationName.trim()}.'
          : 'Now on route to the nearest hospital/clinic.';
      await _plugin.show(
        4,
        'Patient picked up',
        body,
        details,
      );
    } catch (_) {}
  }

  /// Citizen milestone: transport has reached destination facility.
  Future<void> showArrivedAtFacility({String? destinationName}) async {
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
      final body = destinationName != null && destinationName.trim().isNotEmpty
          ? 'Arrived at ${destinationName.trim()}.'
          : 'Arrived at the destination facility.';
      await _plugin.show(
        5,
        'Arrived at facility',
        body,
        details,
      );
    } catch (_) {}
  }
}
