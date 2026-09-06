import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:latlong2/latlong.dart';
import '../firebase_options.dart';
import '../models/barangay.dart';
import '../models/mutual_aid.dart';
import '../models/rescue_models.dart';
import '../models/response_unit_status.dart';
import '../utils/password_utils.dart';

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
      : _db = database ?? connectedRealtimeDatabase();

  /// Same RTDB instance everywhere (LGU web, Android, Windows).
  static FirebaseDatabase connectedRealtimeDatabase() {
    final url = DefaultFirebaseOptions.currentPlatform.databaseURL;
    if (url == null || url.isEmpty) {
      return FirebaseDatabase.instance;
    }
    return FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: url,
    );
  }

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
    // No users/{id} row yet → legacy in-service (Account Center not configured).
    return ResponseUnitStatus.inService;
  }

  /// Watches approval flag for a responder (true/false).
  /// Uses `users/{id}/approvedByLgu` as the source of truth.
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

  // ──────────────── LGU Unit Accounts ────────────────

  Future<void> createUnitAccount({
    required String loginId,
    required String responderUnitId,
    required String unitType,
    required String passwordHash,
    required String passwordSalt,
    required String createdBy,
    String? barangayId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('unit_accounts/$loginId').set({
      'loginId': loginId,
      'role': 'responder_unit',
      'responderUnitId': responderUnitId,
      'unitType': unitType,
      'status': 'active',
      'mustChangePassword': true,
      'passwordHash': passwordHash,
      'passwordSalt': passwordSalt,
      'passwordUpdatedAt': now,
      'createdBy': createdBy,
      'barangayId': normalizeBarangayId(barangayId),
      'createdAt': now,
      'updatedAt': now,
      'softDeletedAt': null,
    });
  }

  Future<void> updateUnitAccount(
    String loginId, {
    String? responderUnitId,
    String? unitType,
    String? status,
    bool? mustChangePassword,
    String? barangayId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('unit_accounts/$loginId').update({
      if (responderUnitId != null) 'responderUnitId': responderUnitId,
      if (unitType != null) 'unitType': unitType,
      if (status != null) 'status': status,
      if (mustChangePassword != null) 'mustChangePassword': mustChangePassword,
      if (barangayId != null) 'barangayId': normalizeBarangayId(barangayId),
      'updatedAt': now,
    });
  }

  Future<void> resetUnitPassword({
    required String loginId,
    required String passwordHash,
    required String passwordSalt,
    bool forceChangeOnNextLogin = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('unit_accounts/$loginId').update({
      'passwordHash': passwordHash,
      'passwordSalt': passwordSalt,
      'passwordUpdatedAt': now,
      'mustChangePassword': forceChangeOnNextLogin,
      'updatedAt': now,
    });
  }

  Future<void> softDeleteUnitAccount(String loginId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('unit_accounts/$loginId').update({
      'status': 'disabled',
      'softDeletedAt': now,
      'updatedAt': now,
    });
  }

  Stream<List<Map<String, dynamic>>> watchAllUnitAccounts() {
    return _db.ref('unit_accounts').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <Map<String, dynamic>>[];
      final rows = <Map<String, dynamic>>[];
      for (final e in data.entries) {
        final raw = e.value;
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        row['id'] = e.key;
        rows.add(row);
      }
      rows.sort(
        (a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0)
            .compareTo((a['createdAt'] as num?)?.toInt() ?? 0),
      );
      return rows;
    });
  }

  Future<Map<String, dynamic>?> getUnitAccountByLoginId(String loginId) async {
    final snap = await _db.ref('unit_accounts/$loginId').get();
    if (!snap.exists || snap.value is! Map) return null;
    final row = Map<String, dynamic>.from(snap.value as Map);
    row['id'] = loginId;
    return row;
  }

  // ──────────────── Responder Session Locks ────────────────

  int _expiresAt(int nowMs, int ttlMs) => nowMs + ttlMs;

  Map<String, Object?> _sessionPayload({
    required String sessionId,
    required String loginId,
    required String responderUnitId,
    required int nowMs,
    required int ttlMs,
    String? deviceInfo,
  }) {
    return {
      'sessionId': sessionId,
      'loginId': loginId,
      'responderUnitId': responderUnitId,
      'startedAt': nowMs,
      'lastSeenAt': nowMs,
      'expiresAt': _expiresAt(nowMs, ttlMs),
      if (deviceInfo != null && deviceInfo.trim().isNotEmpty)
        'deviceInfo': deviceInfo.trim(),
    };
  }

  bool _lockIsExpired(Map<Object?, Object?> value, int nowMs) {
    final expires = (value['expiresAt'] as num?)?.toInt() ?? 0;
    return expires <= nowMs;
  }

  bool _belongsToSession(Map<Object?, Object?> value, String sessionId) {
    return (value['sessionId']?.toString() ?? '') == sessionId;
  }

  Future<({bool success, String? reason})> _acquireSingleLock({
    required DatabaseReference ref,
    required String sessionId,
    required Map<String, Object?> payload,
    required int nowMs,
  }) async {
    final result = await ref.runTransaction((currentData) {
      final current = currentData;
      if (current == null) {
        return Transaction.success(payload);
      }
      if (current is! Map) {
        return Transaction.abort();
      }
      final map = Map<Object?, Object?>.from(current);
      if (_belongsToSession(map, sessionId) || _lockIsExpired(map, nowMs)) {
        return Transaction.success(payload);
      }
      return Transaction.abort();
    });
    if (result.committed) return (success: true, reason: null);
    return (success: false, reason: 'LOCK_HELD');
  }

  Future<({bool success, String? reason})> acquireResponderSessionLocks({
    required String loginId,
    required String responderUnitId,
    required String sessionId,
    int ttlMs = 30 * 1000,
    String? deviceInfo,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = _sessionPayload(
      sessionId: sessionId,
      loginId: loginId,
      responderUnitId: responderUnitId,
      nowMs: now,
      ttlMs: ttlMs,
      deviceInfo: deviceInfo,
    );
    final loginRef = _db.ref('unit_sessions/by_login/$loginId');
    final unitRef = _db.ref('unit_sessions/by_unit/$responderUnitId');

    final loginRes = await _acquireSingleLock(
      ref: loginRef,
      sessionId: sessionId,
      payload: payload,
      nowMs: now,
    );
    if (!loginRes.success) {
      return (success: false, reason: 'ACCOUNT_LOCKED');
    }

    final unitRes = await _acquireSingleLock(
      ref: unitRef,
      sessionId: sessionId,
      payload: payload,
      nowMs: now,
    );
    if (!unitRes.success) {
      // Roll back account lock if unit lock cannot be acquired.
      await releaseResponderSessionLocks(
        loginId: loginId,
        responderUnitId: responderUnitId,
        sessionId: sessionId,
      );
      return (success: false, reason: 'UNIT_LOCKED');
    }

    return (success: true, reason: null);
  }

  Future<void> heartbeatResponderSessionLocks({
    required String loginId,
    required String responderUnitId,
    required String sessionId,
    int ttlMs = 30 * 1000,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final patch = {
      'lastSeenAt': now,
      'expiresAt': _expiresAt(now, ttlMs),
    };
    final loginRef = _db.ref('unit_sessions/by_login/$loginId');
    final unitRef = _db.ref('unit_sessions/by_unit/$responderUnitId');

    await loginRef.runTransaction((currentData) {
      final current = currentData;
      if (current is! Map) return Transaction.abort();
      final map = Map<Object?, Object?>.from(current);
      if (!_belongsToSession(map, sessionId)) return Transaction.abort();
      return Transaction.success({
        ...map.map((k, v) => MapEntry(k.toString(), v)),
        ...patch,
      });
    });
    await unitRef.runTransaction((currentData) {
      final current = currentData;
      if (current is! Map) return Transaction.abort();
      final map = Map<Object?, Object?>.from(current);
      if (!_belongsToSession(map, sessionId)) return Transaction.abort();
      return Transaction.success({
        ...map.map((k, v) => MapEntry(k.toString(), v)),
        ...patch,
      });
    });
  }

  Future<bool> isResponderSessionValid({
    required String loginId,
    required String responderUnitId,
    required String sessionId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final loginSnap = await _db.ref('unit_sessions/by_login/$loginId').get();
    final unitSnap = await _db.ref('unit_sessions/by_unit/$responderUnitId').get();
    if (!loginSnap.exists || !unitSnap.exists) return false;
    if (loginSnap.value is! Map || unitSnap.value is! Map) return false;
    final loginMap = Map<Object?, Object?>.from(loginSnap.value as Map);
    final unitMap = Map<Object?, Object?>.from(unitSnap.value as Map);
    final loginOk = _belongsToSession(loginMap, sessionId) &&
        !_lockIsExpired(loginMap, now);
    final unitOk = _belongsToSession(unitMap, sessionId) &&
        !_lockIsExpired(unitMap, now);
    return loginOk && unitOk;
  }

  Future<void> releaseResponderSessionLocks({
    required String loginId,
    required String responderUnitId,
    required String sessionId,
  }) async {
    final loginRef = _db.ref('unit_sessions/by_login/$loginId');
    final unitRef = _db.ref('unit_sessions/by_unit/$responderUnitId');

    await loginRef.runTransaction((currentData) {
      final current = currentData;
      if (current is! Map) return Transaction.abort();
      final map = Map<Object?, Object?>.from(current);
      if (!_belongsToSession(map, sessionId)) return Transaction.abort();
      return Transaction.success(null);
    });
    await unitRef.runTransaction((currentData) {
      final current = currentData;
      if (current is! Map) return Transaction.abort();
      final map = Map<Object?, Object?>.from(current);
      if (!_belongsToSession(map, sessionId)) return Transaction.abort();
      return Transaction.success(null);
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

  Future<void> updateSosAddress(String sosId, String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;
    await _db.ref('active_sos/$sosId/address').set(trimmed);
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
    await _db.ref('lgu_problem_reports/$sosId').remove();
  }

  /// Resolves/cancels an SOS: moves to history then removes from active map.
  Future<void> resolveSOS(SOSRequest request, {String? closeReason}) async {
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
      backupUnitIds: request.backupUnitIds,
      completedAt: now,
      closeReason: closeReason,
      address: request.address,
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
    await _db.ref('lgu_problem_reports/${request.id}').remove();
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
      backupUnitIds: request.backupUnitIds,
      completedAt: now,
      address: request.address,
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
    await _db.ref('lgu_problem_reports/${request.id}').remove();
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

  Future<void> updateSosBackupUnits(String sosId, List<String> backupUnitIds) async {
    await _db.ref('active_sos/$sosId/backupUnitIds').set(backupUnitIds);
  }

  Future<void> clearSosAssignment(String sosId) async {
    await _db.ref('active_sos/$sosId').update({
      'status': SOSStatus.pending.name,
      'assignedUnitId': null,
      'backupUnitIds': [],
    });
    await _db.ref('dispatch/$sosId').remove();
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

  /// Responder marks a problem while responding. LGU-only visibility at [lgu_problem_reports/$sosId].
  Future<void> reportResponderProblem(String sosId, String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    await _db.ref('lgu_problem_reports/$sosId').update({
      'hasProblem': true,
      'problemText': trimmed,
      'problemAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    });
  }

  /// Streams LGU-only responder problem metadata for a specific SOS.
  Stream<Map<String, dynamic>?> watchLguProblemReport(String sosId) {
    return _db.ref('lgu_problem_reports/$sosId').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return null;
      return Map<String, dynamic>.from(data);
    });
  }

  Stream<Map<String, Map<String, dynamic>>> watchAllLguProblemReports() {
    return _db.ref('lgu_problem_reports').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <String, Map<String, dynamic>>{};
      final out = <String, Map<String, dynamic>>{};
      for (final e in data.entries) {
        final key = e.key?.toString() ?? '';
        if (key.isEmpty || e.value is! Map) continue;
        out[key] = Map<String, dynamic>.from(e.value as Map);
      }
      return out;
    });
  }

  /// Clears LGU-only responder problem metadata for a dispatch.
  Future<void> clearResponderProblem(String sosId) async {
    try {
      await _db.ref('lgu_problem_reports/$sosId').update({
        'hasProblem': false,
        'problemText': '',
        'problemAt': null,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}
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

  Future<void> logAuditEvent({
    required String action,
    required String performedBy,
    required String targetId,
    required Map<String, Object?> details,
  }) async {
    try {
      await _db.ref('audit_log').push().set({
        'event': action,
        'performedBy': performedBy,
        'targetId': targetId,
        'details': details,
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

  // ──────────────── LGU ↔ Responder Chat (separate thread) ────────────────

  Future<void> sendLguResponderChatMessage({
    required String sosId,
    required String senderRole, // 'lgu' | 'responder'
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
    if (hasImage) {
      payload['imageUrl'] = imageUrl;
      payload['type'] = 'image';
    } else {
      payload['type'] = 'text';
    }
    await _db.ref('lgu_responder_chats/$sosId/messages').push().set(payload);
  }

  Stream<List<Map<String, dynamic>>> watchLguResponderChat(String sosId) {
    return _db.ref('lgu_responder_chats/$sosId/messages').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <Map<String, dynamic>>[];
      final list = <Map<String, dynamic>>[];
      for (final e in data.entries) {
        if (e.value is! Map) continue;
        final v = Map<String, dynamic>.from(e.value as Map);
        v['messageId'] = e.key?.toString() ?? '';
        list.add(v);
      }
      list.sort((a, b) =>
          (a['timestamp'] as int? ?? 0).compareTo(b['timestamp'] as int? ?? 0));
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

  Future<void> seedDefaultBarangaysIfMissing() async {
    for (final barangay in kBuiltInBarangays) {
      final ref = _db.ref('barangays/${barangay.id}');
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set(barangay.toJson());
        continue;
      }
      final raw = snap.value;
      if (raw is! Map) continue;
      final current = BarangayRecord.fromJson(barangay.id, Map<dynamic, dynamic>.from(raw));
      final neighbors = [...current.neighbors];
      for (final n in barangay.neighbors) {
        if (!neighbors.contains(n)) neighbors.add(n);
      }
      await ref.update({
        'neighbors': neighbors,
        'mapCenter': {
          'lat': barangay.mapCenter.latitude,
          'lng': barangay.mapCenter.longitude,
        },
      });
    }
  }

  Future<void> seedDefaultLguAdminIfMissing() async {
    final ref = _db.ref('lgu_accounts/$kDemoLgu52Username');
    final snap = await ref.get();
    if (snap.exists) return;
    final salt = PasswordUtils.generateSalt();
    final hash = PasswordUtils.hashPassword(
      password: kDemoLgu52Password,
      salt: salt,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.set({
      'username': kDemoLgu52Username,
      'barangayId': kDefaultBarangayId,
      'isActive': true,
      'passwordHash': hash,
      'passwordSalt': salt,
      'createdAt': now,
      'updatedAt': now,
    });
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
      // One-time: pull legacy far station coords back into Barangay 52 area.
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

  Future<void> upsertRescueUnitRoster(RescueUnit unit, {String? createdBy}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = _db.ref('rescue_unit_roster/${unit.id}');
    final snap = await ref.get();
    final existing = snap.value as Map?;
    await ref.update({
      ...unit.toRosterJson(),
      if (createdBy != null && createdBy.trim().isNotEmpty) 'createdBy': createdBy.trim(),
      'updatedAt': now,
      'createdAt': (existing?['createdAt'] as num?)?.toInt() ?? now,
      'softDeletedAt': null,
    });
  }

  Future<void> softDeleteRescueUnitRoster(String unitId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('rescue_unit_roster/$unitId').update({
      'softDeletedAt': now,
      'updatedAt': now,
    });
  }

  Future<Map<String, dynamic>?> getLguAccount(String username) async {
    final clean = username.trim().toLowerCase();
    if (clean.isEmpty) return null;
    final snap = await _db.ref('lgu_accounts/$clean').get();
    final raw = snap.value;
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    map['username'] = clean;
    return map;
  }

  Stream<List<Map<String, dynamic>>> watchLguAccounts() {
    return _db.ref('lgu_accounts').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <Map<String, dynamic>>[];
      final rows = <Map<String, dynamic>>[];
      for (final e in data.entries) {
        final raw = e.value;
        if (raw is! Map) continue;
        final v = Map<String, dynamic>.from(raw);
        v['username'] = e.key.toString();
        rows.add(v);
      }
      rows.sort((a, b) =>
          (a['username']?.toString() ?? '').compareTo(b['username']?.toString() ?? ''));
      return rows;
    });
  }

  Future<void> updateSosAssistance({
    required String sosId,
    required List<String> assistingBarangayIds,
    required Map<String, List<String>> assistingUnitTypes,
  }) async {
    await _db.ref('active_sos/$sosId').update({
      'assistingBarangayIds': assistingBarangayIds,
      'assistingUnitTypes': assistingUnitTypes,
    });
  }

  Future<void> publishMutualAidRequest(MutualAidRequest request) async {
    await _db.ref('mutual_aid_requests/${request.id}').set(request.toJson());
  }

  Future<void> updateMutualAidRequestStatus({
    required String id,
    required String status,
  }) async {
    await _db.ref('mutual_aid_requests/$id').update({
      'status': status,
      'respondedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Stream<List<MutualAidRequest>> watchMutualAidRequests() {
    return _db.ref('mutual_aid_requests').onValue.map((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return <MutualAidRequest>[];
      final rows = <MutualAidRequest>[];
      for (final e in data.entries) {
        final raw = e.value;
        if (raw is! Map) continue;
        rows.add(MutualAidRequest.fromJson(
          e.key.toString(),
          Map<dynamic, dynamic>.from(raw),
        ));
      }
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return rows;
    });
  }
}
