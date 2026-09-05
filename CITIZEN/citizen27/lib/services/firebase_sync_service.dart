import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:latlong2/latlong.dart';
import '../models/barangay.dart';
import '../models/rescue_models.dart';
import '../models/response_unit_status.dart';

/// Real-time sync layer between all devices via Firebase Realtime Database.
///
/// Database structure:
/// ```
/// /unit_locations/{unitId}  → { lat, lng, callSign, type, status, timestamp }
/// /active_sos/{sosId}       → SOSRequest JSON
/// /hazard_zones/{zoneId}    → HazardZone JSON
/// /dispatch/{sosId}         → { status, unitId, unitCallSign, unitType }
/// ```
class FirebaseSyncService {
  final FirebaseDatabase _db;

  FirebaseSyncService({FirebaseDatabase? database})
      : _db = database ?? FirebaseDatabase.instance;

  // ──────────────── Unit Locations ────────────────

  // ──────────────── User Accounts ────────────────

  Future<void> upsertUserAccount({
    required String userId,
    required String role, // citizen | responder | lgu
    required String name,
    String? email,
    bool? isGuest,
    bool? approvedByLgu,
    String? responseUnitStatus,
    String? barangayId,
  }) async {
    final ref = _db.ref('users/$userId');
    final snap = await ref.get();
    final existing = snap.value as Map?;
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.update({
      'role': role,
      'name': name.trim(),
      if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      if (isGuest != null) 'isGuest': isGuest,
      if (approvedByLgu != null) 'approvedByLgu': approvedByLgu,
      if (responseUnitStatus != null && responseUnitStatus.trim().isNotEmpty)
        'responseUnitStatus': responseUnitStatus.trim(),
      'barangayId': normalizeBarangayId(barangayId),
      'updatedAt': now,
      'createdAt': (existing?['createdAt'] as num?)?.toInt() ?? now,
    });
  }

  /// Upserts a registered citizen profile at users/{uid}.
  Future<void> upsertCitizenProfile({
    required String userId,
    required String name,
    required String email,
    required String phone,
    required String address,
    String? emergencyContactName,
    String? emergencyContactPhone,
    String? barangayId,
  }) async {
    final ref = _db.ref('users/$userId');
    final snap = await ref.get();
    final existing = snap.value as Map?;
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.update({
      'role': 'citizen',
      'name': name.trim(),
      'email': email.trim(),
      'phone': phone.trim(),
      'address': address.trim(),
      if (emergencyContactName != null &&
          emergencyContactName.trim().isNotEmpty)
        'emergencyContactName': emergencyContactName.trim(),
      if (emergencyContactPhone != null &&
          emergencyContactPhone.trim().isNotEmpty)
        'emergencyContactPhone': emergencyContactPhone.trim(),
      'barangayId': normalizeBarangayId(barangayId),
      'isGuest': false,
      'updatedAt': now,
      'createdAt': (existing?['createdAt'] as num?)?.toInt() ?? now,
    });
  }

  /// Reads one citizen profile row from users/{uid}, or null if not found.
  Future<Map<String, dynamic>?> getCitizenProfile(String userId) async {
    final snap = await _db.ref('users/$userId').get();
    final raw = snap.value;
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    map['id'] = userId;
    return map;
  }

  Future<void> upsertResponderAccount({
    required String userId,
    required String callSign,
    required String unitType,
    required bool approvedByLgu,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('responders/$userId').update({
      'callSign': callSign,
      'type': unitType,
      'approvedByLgu': approvedByLgu,
      'updatedAt': now,
    });
  }

  Future<void> setResponseUnitStatus({
    required String responderId,
    required ResponseUnitStatus status,
    String? name,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('users/$responderId').update({
      'role': 'responder',
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      'responseUnitStatus': status.wireName,
      'approvedByLgu': status.canTakeSos,
      'updatedAt': now,
    });
    await _db.ref('responders/$responderId').update({
      'responseUnitStatus': status.wireName,
      'approvedByLgu': status.canTakeSos,
      'updatedAt': now,
    });
  }

  Future<void> setResponderApproval({
    required String responderId,
    required bool approved,
  }) async {
    await setResponseUnitStatus(
      responderId: responderId,
      status: approved
          ? ResponseUnitStatus.inService
          : ResponseUnitStatus.outOfService,
    );
  }

  Future<bool?> getResponderApproval(String responderId) async {
    final status = await getResponseUnitStatus(responderId);
    return status.canTakeSos;
  }

  Future<ResponseUnitStatus> getResponseUnitStatus(String responderId) async {
    final userSnap = await _db.ref('users/$responderId').get();
    final userRaw = userSnap.value;
    if (userRaw is Map) {
      return responseUnitStatusFromUser(Map<dynamic, dynamic>.from(userRaw));
    }
    return ResponseUnitStatus.inService;
  }

  /// Watches approval flag for a responder (true/false).
  /// Uses `users/{id}` operational status as the source of truth.
  Stream<bool> watchResponderApproval(String responderId) {
    return watchResponseUnitStatus(responderId).map((status) => status.canTakeSos);
  }

  /// Watches operational status on `users/{id}`.
  Stream<ResponseUnitStatus> watchResponseUnitStatus(String responderId) {
    return _db.ref('users/$responderId').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        return responseUnitStatusFromUser(Map<dynamic, dynamic>.from(raw));
      }
      return ResponseUnitStatus.inService;
    });
  }

  /// LGU ban for a citizen account (`users/{citizenId}`).
  Future<void> setCitizenBan({
    required String citizenId,
    required bool banned,
    String? reason,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = _db.ref('users/$citizenId');
    if (banned) {
      await ref.update({
        'bannedByLgu': true,
        'banReason': (reason ?? '').trim(),
        'bannedAt': now,
        'updatedAt': now,
      });
    } else {
      await ref.update({
        'bannedByLgu': false,
        'updatedAt': now,
      });
      await ref.child('banReason').remove();
      await ref.child('bannedAt').remove();
    }
  }

  /// Reads ban fields for SOS gating (works before streams deliver).
  Future<({bool banned, String? reason})> getCitizenBanStatus(
      String citizenId) async {
    final snap = await _db.ref('users/$citizenId').get();
    final v = snap.value;
    if (v is! Map) return (banned: false, reason: null);
    final m = Map<Object?, Object?>.from(v);
    final banned = m['bannedByLgu'] == true;
    final r = m['banReason']?.toString();
    return (banned: banned, reason: r?.trim().isEmpty == true ? null : r);
  }

  Stream<List<Map<String, dynamic>>> watchAllUsers() {
    return _db.ref('users').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <Map<String, dynamic>>[];
      final rows = <Map<String, dynamic>>[];
      for (final e in data.entries) {
        final raw = e.value;
        if (raw is! Map) continue;
        final v = Map<String, dynamic>.from(raw);
        v['id'] = e.key;
        rows.add(v);
      }
      rows.sort((a, b) =>
          ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
      return rows;
    });
  }

  /// Writes a responder's live GPS position to Firebase.
  Future<void> updateUnitLocation(RescueUnit unit) async {
    await _db.ref('unit_locations/${unit.id}').set({
      'lat': unit.position.latitude,
      'lng': unit.position.longitude,
      'callSign': unit.callSign,
      'type': unit.type.name,
      'status': unit.status.name,
      'assignedSOSId': unit.assignedSOSId,
      'stationId': unit.stationId,
      'barangayId': normalizeBarangayId(unit.barangayId),
      'timestamp': ServerValue.timestamp,
    });
  }

  /// Streams all unit location changes in real-time.
  Stream<List<RescueUnit>> watchAllUnitLocations() {
    return _db.ref('unit_locations').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <RescueUnit>[];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      const staleMs = 20 * 1000; // Hide units with no heartbeat for 20s.
      final units = <RescueUnit>[];

      for (final e in data.entries) {
        final raw = e.value;
        if (raw is! Map) continue;
        final v = Map<String, dynamic>.from(raw);

        // Only consider units online if their timestamp heartbeat is recent.
        final ts = (v['timestamp'] as num?)?.toInt();
        if (ts == null || (nowMs - ts) > staleMs) continue;

        units.add(
          RescueUnit(
            id: e.key as String,
            callSign: v['callSign'] as String? ?? '',
            type: UnitType.values.firstWhere(
              (t) => t.name == v['type'],
              orElse: () => UnitType.rescue,
            ),
            status: UnitStatus.values.firstWhere(
              (s) => s.name == v['status'],
              orElse: () => UnitStatus.idle,
            ),
            position: LatLng(
              (v['lat'] as num).toDouble(),
              (v['lng'] as num).toDouble(),
            ),
            assignedSOSId: v['assignedSOSId'] as String?,
            stationId: v['stationId'] as String? ?? '',
            barangayId: normalizeBarangayId(v['barangayId']?.toString()),
          ),
        );
      }
      return units;
    });
  }

  /// Streams a single unit's location changes.
  Stream<LatLng?> watchUnitLocation(String unitId) {
    return _db.ref('unit_locations/$unitId').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return null;
      return LatLng(
        (data['lat'] as num).toDouble(),
        (data['lng'] as num).toDouble(),
      );
    });
  }

  /// Removes a unit's location entry (e.g. when going offline).
  Future<void> removeUnitLocation(String unitId) async {
    await _db.ref('unit_locations/$unitId').remove();
  }

  // ──────────────── SOS Requests ────────────────

  /// Publishes a new SOS request to Firebase.
  Future<void> publishSOS(SOSRequest sos) async {
    await _db.ref('active_sos/${sos.id}').set(sos.toJson());
  }

  /// Updates the citizen's live location on an existing SOS.
  /// Pinned / proxy SOS pins are never moved by reporter GPS.
  Future<void> updateSOSLocation(String sosId, LatLng location) async {
    final pinned =
        await _db.ref('active_sos/$sosId/locationIsPinned').get();
    if (pinned.value == true) return;
    await _db.ref('active_sos/$sosId').update({
      'lat': location.latitude,
      'lng': location.longitude,
    });
  }

  /// One-time read of all active SOS (e.g. to mark old ones as completed).
  Future<List<SOSRequest>> getActiveSOSOnce() async {
    final snapshot = await _db.ref('active_sos').get();
    final data = snapshot.value as Map?;
    if (data == null) return [];
    final list = <SOSRequest>[];
    for (final e in data.entries) {
      try {
        final value = e.value;
        if (value is! Map) continue;
        final v = Map<String, dynamic>.from(value);
        v['id'] = e.key?.toString() ?? '';
        list.add(SOSRequest.fromJson(v));
      } catch (_) {}
    }
    return list;
  }

  /// Streams all active SOS requests. Skips malformed, cancelled, and stale entries to avoid phantom SOS.
  Stream<List<SOSRequest>> watchAllSOS() {
    return _db.ref('active_sos').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <SOSRequest>[];
      final list = <SOSRequest>[];
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final e in data.entries) {
        try {
          final value = e.value;
          if (value is! Map) continue;
          final v = Map<String, dynamic>.from(value);
          final id = e.key?.toString() ?? '';
          if (id.isEmpty) continue;
          v['id'] = id;
          final req = SOSRequest.fromJson(v);
          // Exclude cancelled/resolved/completed (should not be in active_sos; safety filter).
          if (!req.isActive) continue;
          // Exclude very old SOS (likely phantom/stale).
          if (req.createdAt.isBefore(cutoff)) continue;
          list.add(req);
        } catch (_) {
          // Skip malformed SOS entry
        }
      }
      return list;
    });
  }

  /// Streams a single SOS request (for the citizen to watch status changes).
  Stream<SOSRequest?> watchSOS(String sosId) {
    return _db.ref('active_sos/$sosId').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return null;
      final v = Map<String, dynamic>.from(data);
      v['id'] = sosId;
      return SOSRequest.fromJson(v);
    });
  }

  /// Reads final SOS status from history after it leaves active_sos.
  /// Returns null when entry is not found or malformed.
  Future<SOSStatus?> getSOSHistoryStatus(String sosId) async {
    final snap = await _db.ref('sos_history/$sosId').get();
    final raw = snap.value as Map?;
    if (raw == null) return null;
    final map = Map<String, dynamic>.from(raw);
    final statusRaw = map['status'] as String?;
    if (statusRaw == null || statusRaw.isEmpty) return null;
    for (final s in SOSStatus.values) {
      if (s.name == statusRaw) return s;
    }
    return null;
  }

  /// Removes an SOS from active map without adding to history (e.g. when request not in memory).
  Future<void> removeActiveSOS(String sosId) async {
    await _db.ref('active_sos/$sosId').remove();
    await _db.ref('dispatch/$sosId').remove();
  }

  /// Resolves/cancels an SOS: moves to history then removes from active map.
  Future<void> resolveSOS(SOSRequest request) async {
    final now = DateTime.now();
    final entry = SOSRequest(
      id: request.id,
      location: request.location,
      citizenId: request.citizenId,
      citizenName: request.citizenName,
      message: request.message,
      priority: request.priority,
      sosType: request.sosType,
      status: SOSStatus.cancelled,
      createdAt: request.createdAt,
      assignedUnitId: request.assignedUnitId,
      completedAt: now,
      preferredFacilityId: request.preferredFacilityId,
      preferredFacilityName: request.preferredFacilityName,
      preferredFacilityLocation: request.preferredFacilityLocation,
      locationIsPinned: request.locationIsPinned,
      reportedForName: request.reportedForName,
      callbackPhone: request.callbackPhone,
      scenePhotoUrl: request.scenePhotoUrl,
    );
    final json = entry.toJson();
    json['completedAt'] = now.millisecondsSinceEpoch;
    await _db.ref('sos_history/${request.id}').set(json);
    await _db.ref('active_sos/${request.id}').remove();
    await _db.ref('dispatch/${request.id}').remove();
  }

  /// Marks SOS as completed (victim assisted), moves to history, removes from active map.
  /// [extraMetrics] can be used to attach evaluation fields (response times, distances, etc.).
  Future<void> completeSOS(
    SOSRequest request, {
    Map<String, Object?>? extraMetrics,
  }) async {
    final now = DateTime.now();
    final completed = SOSRequest(
      id: request.id,
      location: request.location,
      citizenId: request.citizenId,
      citizenName: request.citizenName,
      message: request.message,
      priority: request.priority,
      sosType: request.sosType,
      status: SOSStatus.completed,
      createdAt: request.createdAt,
      assignedUnitId: request.assignedUnitId,
      completedAt: now,
      preferredFacilityId: request.preferredFacilityId,
      preferredFacilityName: request.preferredFacilityName,
      preferredFacilityLocation: request.preferredFacilityLocation,
      locationIsPinned: request.locationIsPinned,
      reportedForName: request.reportedForName,
      callbackPhone: request.callbackPhone,
      scenePhotoUrl: request.scenePhotoUrl,
    );
    final json = completed.toJson();
    json['completedAt'] = now.millisecondsSinceEpoch;
    if (extraMetrics != null && extraMetrics.isNotEmpty) {
      json.addAll(extraMetrics);
    }
    await _db.ref('sos_history/${request.id}').set(json);
    await _db.ref('active_sos/${request.id}').remove();
    await _db.ref('dispatch/${request.id}').remove();
  }

  /// Streams SOS history (completed/cancelled/resolved) for logs. Skips malformed entries.
  Stream<List<SOSRequest>> watchSOSHistory() {
    return _db.ref('sos_history').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <SOSRequest>[];
      final list = <SOSRequest>[];
      for (final e in data.entries) {
        try {
          final value = e.value;
          if (value is! Map) continue;
          final v = Map<String, dynamic>.from(value);
          v['id'] = e.key?.toString() ?? '';
          list.add(SOSRequest.fromJson(v));
        } catch (_) {
          // Skip malformed history entry
        }
      }
      return list;
    });
  }

  // ──────────────── Dispatch Status ────────────────

  /// Records that a unit has accepted an SOS dispatch.
  Future<void> acceptDispatch({
    required String sosId,
    required RescueUnit unit,
  }) async {
    await _db.ref('dispatch/$sosId').set({
      'status': 'accepted',
      'unitId': unit.id,
      'unitCallSign': unit.callSign,
      'unitType': unit.type.name,
      'timestamp': ServerValue.timestamp,
    });
    await _db.ref('active_sos/$sosId').update({
      'status': SOSStatus.dispatched.name,
      'assignedUnitId': unit.id,
    });
    await _db.ref('unit_locations/${unit.id}/status').set(UnitStatus.enRoute.name);
    await _db.ref('unit_locations/${unit.id}/assignedSOSId').set(sosId);
  }

  /// Updates dispatch status progression.
  Future<void> updateDispatchStatus(String sosId, String status) async {
    await _db.ref('dispatch/$sosId/status').set(status);
  }

  /// Updates richer dispatch telemetry for citizen live tracking.
  Future<void> updateDispatchProgress(
    String sosId, {
    String? status,
    String? phase,
    int? etaMinutes,
    int? distanceMeters,
    String? nextInstruction,
    String? routingTo,
    String? destinationName,
    LatLng? destinationLocation,
  }) async {
    final payload = <String, Object?>{
      if (status != null) 'status': status,
      if (phase != null) 'phase': phase,
      if (etaMinutes != null) 'etaMinutes': etaMinutes,
      if (distanceMeters != null) 'distanceMeters': distanceMeters,
      if (nextInstruction != null) 'nextInstruction': nextInstruction,
      if (routingTo != null) 'routingTo': routingTo,
      if (destinationName != null) 'destinationName': destinationName,
      if (destinationLocation != null) 'destinationLat': destinationLocation.latitude,
      if (destinationLocation != null) 'destinationLng': destinationLocation.longitude,
      'updatedAt': ServerValue.timestamp,
    };
    await _db.ref('dispatch/$sosId').update(payload);
  }

  /// Streams dispatch info for a specific SOS (citizen watches this).
  Stream<Map<String, dynamic>?> watchDispatch(String sosId) {
    return _db.ref('dispatch/$sosId').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return null;
      return Map<String, dynamic>.from(data);
    });
  }

  // ──────────────── Hazard Zones ────────────────

  /// Publishes or updates a hazard zone in Firebase.
  Future<void> publishHazardZone(HazardZone zone) async {
    await _db.ref('hazard_zones/${zone.id}').set(zone.toJson());
  }

  /// Marks a hazard zone as resolved.
  Future<void> resolveHazardZone(String zoneId) async {
    await _db.ref('hazard_zones/$zoneId/resolvedAt').set(
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ──────────────── Audit Log ────────────────

  /// Logs when a user leaves a dashboard (for accountability).
  Future<void> logDashboardExit({
    required String role,
    required String screen,
    String? unitId,
    String? sosId,
  }) async {
    try {
      await _db.ref('audit_log').push().set({
        'event': 'dashboard_exit',
        'role': role,
        'screen': screen,
        if (unitId != null) 'unitId': unitId,
        if (sosId != null) 'sosId': sosId,
        'timestamp': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  // ──────────────── SOS Chat (rescuer ↔ citizen) ────────────────

  /// Sends a message in the SOS chat. [senderRole] is 'citizen' or 'responder'.
  /// For images, set [imageUrl] and optional short [text] (caption).
  Future<void> sendChatMessage({
    required String sosId,
    required String senderRole,
    required String senderId,
    required String senderDisplayName,
    String text = '',
    String? imageUrl,
  }) async {
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    if (text.trim().isEmpty && !hasImage) return;

    final payload = <String, dynamic>{
      'senderRole': senderRole,
      'senderId': senderId,
      'senderDisplayName': senderDisplayName,
      'text': text,
      'timestamp': ServerValue.timestamp,
    };
    if (imageUrl != null && imageUrl.isNotEmpty) {
      payload['imageUrl'] = imageUrl;
      payload['type'] = 'image';
    } else {
      payload['type'] = 'text';
    }
    await _db.ref('sos_chats/$sosId/messages').push().set(payload);
  }

  /// Streams all messages for an SOS chat.
  Stream<List<Map<String, dynamic>>> watchSOSChat(String sosId) {
    return _db.ref('sos_chats/$sosId/messages').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <Map<String, dynamic>>[];
      final list = <Map<String, dynamic>>[];
      for (final e in data.entries) {
        if (e.value is! Map) continue;
        final v = Map<String, dynamic>.from(e.value as Map);
        v['messageId'] = e.key?.toString() ?? '';
        list.add(v);
      }
      list.sort((a, b) => (a['timestamp'] as int? ?? 0).compareTo(b['timestamp'] as int? ?? 0));
      return list;
    });
  }

  /// Streams all hazard zones (active and resolved).
  Stream<List<HazardZone>> watchAllHazardZones() {
    return _db.ref('hazard_zones').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <HazardZone>[];
      return data.entries.map((e) {
        final v = Map<String, dynamic>.from(e.value as Map);
        v['id'] = e.key;
        return HazardZone.fromJson(v);
      }).toList();
    });
  }

  List<BarangayRecord> _parseBarangays(Object? raw) {
    if (raw is! Map) return List<BarangayRecord>.from(kBuiltInBarangays);
    final out = <BarangayRecord>[];
    for (final e in raw.entries) {
      final v = e.value;
      if (v is! Map) continue;
      out.add(BarangayRecord.fromJson(e.key.toString(), Map<dynamic, dynamic>.from(v)));
    }
    if (out.isEmpty) return List<BarangayRecord>.from(kBuiltInBarangays);
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  Stream<List<BarangayRecord>> watchBarangays() {
    return _db.ref('barangays').onValue.map((event) {
      return _parseBarangays(event.snapshot.value);
    });
  }

  Future<List<BarangayRecord>> fetchBarangays() async {
    try {
      final snap = await _db.ref('barangays').get();
      return _parseBarangays(snap.value);
    } catch (_) {
      return List<BarangayRecord>.from(kBuiltInBarangays);
    }
  }

  List<RescueUnit> _parseRescueUnitRoster(Object? raw) {
    if (raw is! Map) return builtInRescueUnits();
    final out = <RescueUnit>[];
    for (final e in raw.entries) {
      final value = e.value;
      if (value is! Map) continue;
      final map = Map<dynamic, dynamic>.from(value);
      if (map['softDeletedAt'] != null) continue;
      final id = (map['id']?.toString().trim().isNotEmpty == true)
          ? map['id'].toString()
          : e.key.toString();
      if (id.isEmpty) continue;
      out.add(RescueUnit.fromRosterMap(id, map));
    }
    out.sort((a, b) => a.callSign.compareTo(b.callSign));
    return out;
  }

  Stream<List<RescueUnit>> watchRescueUnitRoster() {
    return _db.ref('rescue_unit_roster').onValue.map((event) {
      return _parseRescueUnitRoster(event.snapshot.value);
    });
  }

  Future<void> seedDefaultRescueUnitsIfMissing() async {
    for (final unit in builtInRescueUnits()) {
      final ref = _db.ref('rescue_unit_roster/${unit.id}');
      final snap = await ref.get();
      if (!snap.exists) {
        final now = DateTime.now().millisecondsSinceEpoch;
        await ref.set({
          ...unit.toRosterJson(),
          'createdAt': now,
          'updatedAt': now,
          'softDeletedAt': null,
        });
        continue;
      }
      final raw = snap.value;
      if (raw is! Map) continue;
      if (raw['softDeletedAt'] != null) continue;
      final lat = (raw['lat'] as num?)?.toDouble();
      final isLegacyFar =
          (unit.id == 'unit-2' && lat != null && lat > 14.70) ||
          (unit.id == 'unit-3' && lat != null && lat > 14.70);
      if (!isLegacyFar) continue;
      await ref.update({
        'lat': unit.position.latitude,
        'lng': unit.position.longitude,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }
}
