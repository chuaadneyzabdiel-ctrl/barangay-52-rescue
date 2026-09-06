import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/osrm_navigation_models.dart';
import '../models/barangay.dart';
import '../models/rescue_models.dart';
import '../models/response_unit_status.dart';
import '../services/a_star_routing_service.dart';
import '../services/dynamic_relocation_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/location_service.dart';
import '../services/osrm_routing_service.dart';
import '../utils/geo_utils.dart';
import '../utils/password_utils.dart';
import '../utils/route_geo_utils.dart';
import '../utils/unit_sos_compatibility.dart';

const _kActiveSosId = 'active_sos_id';
const _kResponderNavSosId = 'responder_nav_sos_id';
const _kResponderNavUnitId = 'responder_nav_unit_id';
const _kPersistedRoleKey = 'persisted_user_role';
const _kResponderSessionUnitIdKey = 'responder_session_unit_id';
const _kResponderUnitLoginIdKey = 'responder_unit_login_id';
const _kResponderSessionIdKey = 'responder_session_id';

enum UserRole { citizen, responder, lguAdmin }
enum CitizenAccessMode { guest, registered }

/// Central state for the rescue dispatch system.
///
/// Integrates Firebase for real-time cross-device sync, OSRM for
/// road-accurate routes, and A* for hazard-aware pathfinding.
class RescueProvider extends ChangeNotifier {
  final AStarRoutingService _routingService;
  final DynamicRelocationService _relocationService;
  final LocationService _locationService;
  final FirebaseSyncService _firebaseSync;
  final OsrmRoutingService _osrmService;

  UserRole _currentRole = UserRole.citizen;
  LatLng? _currentPosition;
  List<LatLng> _aStarRoute = [];
  List<LatLng> _osrmRoute = [];
  List<List<LatLng>> _osrmAlternates = [];
  List<RouteTrafficSegment> _routeTrafficSegments = [];
  List<OsrmNavigationStep> _navigationSteps = [];
  double _osrmEtaMinutes = 0;
  double _osrmDistanceKm = 0;
  double _safeEtaMinutes = 0;
  double _safeDistanceKm = 0;
  int _osrmHazardCrossings = 0;
  int _safeHazardCrossings = 0;
  StreamSubscription<LatLng>? _locationSub;

  // Firebase-synced live data
  List<HazardZone> _hazardZones = [];
  List<RescueUnit> _rescueUnits = [];
  List<SOSRequest> _sosRequests = [];
  List<SOSRequest> _sosHistory = [];
  Map<String, StandbyPoint> _relocationSuggestions = {};

  // Firebase stream subscriptions
  StreamSubscription? _unitsSub;
  StreamSubscription? _sosSub;
  StreamSubscription? _hazardSub;
  StreamSubscription? _sosHistorySub;
  StreamSubscription? _usersSub;
  StreamSubscription? _unitAccountsSub;
  StreamSubscription? _rosterSub;

  // GPS upload timer for responders
  Timer? _gpsUploadTimer;
  Timer? _responderSessionHeartbeatTimer;
  Timer? _gpsSpoofPushTimer;

  // Debug-only GPS spoof (never auto-enabled; gated by kDebugMode in getters).
  bool _gpsSpoofEnabled = false;
  String? _gpsSpoofUnitId;
  LatLng? _gpsSpoofPosition;
  double _gpsSpoofSpeedKmh = 30;
  DateTime? _lastGpsSpoofPushAt;
  bool _gpsSpoofPushInFlight = false;
  bool _gpsSpoofPushPending = false;
  String? _lastGpsSpoofError;
  /// Unit IDs currently locked by the debug joystick (other Chrome tab).
  Set<String> _remoteGpsSpoofUnitIds = {};

  // Persisted active SOS (citizen) — restored when app reopens
  String? _activeSosId;

  // Persisted citizen profile (for naming SOS requests)
  String? _citizenName;
  String? _citizenId;
  CitizenAccessMode _citizenAccessMode = CitizenAccessMode.guest;
  String? _citizenEmail;
  int _guestSosCountToday = 0;
  DateTime? _guestLastSosAt;
  DateTime? _guestCounterDate;
  int _guestStrikes = 0;
  bool _guestIsBanned = false;
  List<Map<String, dynamic>> _accountUsers = [];
  List<Map<String, dynamic>> _unitAccounts = [];
  String? _currentResponderUnitLoginId;
  String? _currentResponderSessionId;
  String? _currentResponderSessionUnitId;

  // Location status for "turn on location" prompts
  LocationStatus? _locationStatus;

  // Ensure Firebase listeners are only started once.
  bool _listenersStarted = false;

  // Periodic timer to auto-complete very old SOS requests.
  Timer? _sosCleanupTimer;

  // Track which relocation strategy was used per SOS (for evaluation logging).
  // Key: sosId, Value: 'suggested', 'none', or 'unknown'.
  final Map<String, String> _relocationStrategyBySosId = {};

  String? get activeSosId => _activeSosId;
  LocationStatus? get locationStatus => _locationStatus;
  String? get citizenName => _citizenName;
  String? get citizenId => _citizenId;
  CitizenAccessMode get citizenAccessMode => _citizenAccessMode;
  String? get citizenEmail => _citizenEmail;
  int get guestSosCountToday => _guestSosCountToday;
  DateTime? get guestLastSosAt => _guestLastSosAt;
  int get guestStrikes => _guestStrikes;
  bool get guestIsBanned => _guestIsBanned;
  bool get isCitizenGuest => _citizenAccessMode == CitizenAccessMode.guest;
  bool get isCitizenRegistered => _citizenAccessMode == CitizenAccessMode.registered;
  List<Map<String, dynamic>> get accountUsers => List.unmodifiable(_accountUsers);
  List<Map<String, dynamic>> get unitAccounts => List.unmodifiable(_unitAccounts);

  ResponseUnitStatus responseUnitStatusForUnit(String unitId) {
    final fromCache = _accountUsers
        .where((u) => (u['id']?.toString() ?? '') == unitId)
        .firstOrNull;
    return responseUnitStatusFromUser(fromCache);
  }

  ResponseUnitStatus responseUnitStatusForLogin(String? loginId) {
    final id = loginId?.trim().toLowerCase() ?? '';
    if (id.isEmpty) return ResponseUnitStatus.outOfService;
    final account = _unitAccounts.where((a) {
      final login = (a['loginId'] ?? a['id'])?.toString().trim().toLowerCase();
      return login == id && a['softDeletedAt'] == null;
    }).firstOrNull;
    if (account == null) return ResponseUnitStatus.outOfService;
    if (unitLoginIsDisabled(account['status']?.toString())) {
      return ResponseUnitStatus.disabled;
    }
    final unitId = account['responderUnitId']?.toString() ?? '';
    if (unitId.isEmpty) return ResponseUnitStatus.outOfService;
    return responseUnitStatusForUnit(unitId);
  }

  bool canResponseUnitTakeSos(String unitId) =>
      responseUnitStatusForUnit(unitId).canTakeSos;

  Future<ResponseUnitStatus> _resolveResponseUnitStatus(String responderId) async {
    final fromCache = _accountUsers
        .where((u) => (u['id']?.toString() ?? '') == responderId)
        .firstOrNull;
    if (fromCache != null) {
      return responseUnitStatusFromUser(fromCache);
    }
    return _firebaseSync.getResponseUnitStatus(responderId);
  }
  String? get currentResponderUnitLoginId => _currentResponderUnitLoginId;
  String? get currentResponderSessionId => _currentResponderSessionId;
  String? get currentResponderSessionUnitId => _currentResponderSessionUnitId;

  RescueProvider({
    AStarRoutingService? routingService,
    DynamicRelocationService? relocationService,
    LocationService? locationService,
    FirebaseSyncService? firebaseSyncService,
    OsrmRoutingService? osrmService,
  })  : _routingService = routingService ?? const AStarRoutingService(),
        _relocationService = relocationService ?? DynamicRelocationService(),
        _locationService = locationService ?? LocationService(),
        _firebaseSync = firebaseSyncService ?? FirebaseSyncService(),
        _osrmService = osrmService ?? OsrmRoutingService() {
    // Always listen to Firebase so all roles (citizen, responder, LGU)
    // see real-time updates, even if specific screens are not opened yet.
    startFirebaseListeners();
  }

  // --- Getters ---

  UserRole get currentRole => _currentRole;
  LatLng? get currentPosition => _currentPosition;
  /// Current speed in m/s from GPS, if available. Use for speedometer.
  double? get currentSpeedMps => _locationService.lastSpeedMps;
  List<LatLng> get aStarRoute => List.unmodifiable(_aStarRoute);
  List<LatLng> get osrmRoute => List.unmodifiable(_osrmRoute);
  List<List<LatLng>> get osrmAlternates =>
      _osrmAlternates.map((e) => List<LatLng>.unmodifiable(e)).toList();
  List<RouteTrafficSegment> get routeTrafficSegments =>
      List.unmodifiable(_routeTrafficSegments);
  List<OsrmNavigationStep> get navigationSteps =>
      List.unmodifiable(_navigationSteps);
  double get osrmEtaMinutes => _osrmEtaMinutes;
  double get osrmDistanceKm => _osrmDistanceKm;
  double get safeEtaMinutes => _safeEtaMinutes;
  double get safeDistanceKm => _safeDistanceKm;
  int get osrmHazardCrossings => _osrmHazardCrossings;
  int get safeHazardCrossings => _safeHazardCrossings;
  List<HazardZone> get hazardZones => List.unmodifiable(_hazardZones);
  List<RescueUnit> get rescueUnits => List.unmodifiable(_rescueUnits);

  /// Canonical roster of rescue units (same list for LGU and responders).
  List<RescueUnit> get rescueUnitsRoster => List.unmodifiable(_rescueUnitsRoster);

  List<RescueUnit> get assignableEmergencyUnits =>
      List.unmodifiable(_rescueUnitsRoster);
  List<RescueUnit> _rescueUnitsRoster = builtInRescueUnits();

  /// When a responder selects a unit, we keep it so GPS upload can use it before Firebase stream delivers.
  RescueUnit? _currentResponderUnit;
  RescueUnit? get currentResponderUnit => _currentResponderUnit;
  void setCurrentResponderUnit(RescueUnit? unit) {
    _currentResponderUnit = unit;
  }

  void setCurrentResponderUnitLoginId(String? loginId) {
    _currentResponderUnitLoginId = loginId;
  }

  Future<void> hydrateResponderSessionLock({
    required String loginId,
    required String responderUnitId,
    required String sessionId,
  }) async {
    _currentResponderUnitLoginId = loginId;
    _currentResponderSessionUnitId = responderUnitId;
    _currentResponderSessionId = sessionId;
    await _startResponderSessionHeartbeat();
  }

  Future<void> _startResponderSessionHeartbeat() async {
    _responderSessionHeartbeatTimer?.cancel();
    if (_currentResponderUnitLoginId == null ||
        _currentResponderSessionUnitId == null ||
        _currentResponderSessionId == null) {
      return;
    }
    _responderSessionHeartbeatTimer =
        Timer.periodic(const Duration(seconds: 5), (_) async {
      final loginId = _currentResponderUnitLoginId;
      final unitId = _currentResponderSessionUnitId;
      final sessionId = _currentResponderSessionId;
      if (loginId == null || unitId == null || sessionId == null) return;
      try {
        await _firebaseSync.heartbeatResponderSessionLocks(
          loginId: loginId,
          responderUnitId: unitId,
          sessionId: sessionId,
          ttlMs: 120 * 1000,
        );
      } catch (_) {
        // Best-effort heartbeat; validity checks enforce safety on actions.
      }
    });
  }

  void _stopResponderSessionHeartbeat() {
    _responderSessionHeartbeatTimer?.cancel();
    _responderSessionHeartbeatTimer = null;
  }

  Future<bool> ensureResponderSessionIsValid({
    String? unitId,
    bool logOnFailure = true,
  }) async {
    final loginId = _currentResponderUnitLoginId;
    final responderUnitId = unitId ?? _currentResponderSessionUnitId;
    final sessionId = _currentResponderSessionId;
    if (loginId == null || responderUnitId == null || sessionId == null) {
      return false;
    }
    // Refresh TTL before validating so a slow Accept is not blocked by expiry.
    try {
      await _firebaseSync.heartbeatResponderSessionLocks(
        loginId: loginId,
        responderUnitId: responderUnitId,
        sessionId: sessionId,
        ttlMs: 120 * 1000,
      );
    } catch (_) {}
    final ok = await _firebaseSync.isResponderSessionValid(
      loginId: loginId,
      responderUnitId: responderUnitId,
      sessionId: sessionId,
    );
    if (!ok && logOnFailure) {
      await _firebaseSync.logAuditEvent(
        action: 'SESSION_HEARTBEAT_TIMEOUT',
        performedBy: loginId,
        targetId: responderUnitId,
        details: const {},
      );
    }
    return ok;
  }

  /// Units for LGU display: roster merged with live data (roster unit shown as offline if not in Firebase).
  List<RescueUnit> get unitsForDisplay {
    return _rescueUnitsRoster.map((roster) {
      final live = _rescueUnits.where((u) => u.id == roster.id).firstOrNull;
      return live ?? roster;
    }).toList();
  }

  /// True if this roster unit is currently online (has live data in Firebase).
  bool isUnitOnline(String unitId) =>
      _rescueUnits.any((u) => u.id == unitId);

  List<SOSRequest> get sosRequests => List.unmodifiable(_sosRequests);
  /// Only requests that should appear on the map (pending, dispatched, inProgress).
  List<SOSRequest> get activeSosRequests {
    final list = _sosRequests.where((r) => r.isActive);
    final unitBarangay = _responderUnitBarangayId;
    if (unitBarangay == null) {
      // Responder without a resolved unit barangay must not see every SOS.
      if (_currentRole == UserRole.responder) return const [];
      return list.toList();
    }
    return list.where((r) => r.isVisibleToBarangay(unitBarangay)).toList();
  }
  List<SOSRequest> get sosHistory => List.unmodifiable(_sosHistory);
  Map<String, StandbyPoint> get relocationSuggestions =>
      Map.unmodifiable(_relocationSuggestions);
  LocationService get locationService => _locationService;
  FirebaseSyncService get firebaseSync => _firebaseSync;

  /// Debug-only GPS spoof. Always false in release builds.
  bool get isGpsSpoofEnabled => kDebugMode && _gpsSpoofEnabled;
  String? get gpsSpoofUnitId => isGpsSpoofEnabled ? _gpsSpoofUnitId : null;
  LatLng? get gpsSpoofPosition => isGpsSpoofEnabled ? _gpsSpoofPosition : null;
  double get gpsSpoofSpeedKmh => _gpsSpoofSpeedKmh.clamp(1, 120);
  String? get lastGpsSpoofError => _lastGpsSpoofError;
  DateTime? get lastGpsSpoofPushAt =>
      isGpsSpoofEnabled ? _lastGpsSpoofPushAt : null;

  /// Units available to spoof: live GPS first, then roster fallbacks.
  List<RescueUnit> get spoofableResponderUnits {
    final byId = <String, RescueUnit>{};
    for (final u in _rescueUnitsRoster) {
      byId[u.id] = u;
    }
    for (final u in _rescueUnits) {
      byId[u.id] = u;
    }
    final list = byId.values.toList()
      ..sort((a, b) {
        final aLive = isUnitOnline(a.id);
        final bLive = isUnitOnline(b.id);
        if (aLive != bLive) return aLive ? -1 : 1;
        return a.callSign.compareTo(b.callSign);
      });
    return list;
  }

  void setGpsSpoofSpeedKmh(double kmh) {
    if (!kDebugMode) return;
    _gpsSpoofSpeedKmh = kmh.clamp(1, 120);
    notifyListeners();
  }

  void _mergeGpsSpoofIntoLiveUnits() {
    if (!isGpsSpoofEnabled ||
        _gpsSpoofUnitId == null ||
        _gpsSpoofPosition == null) {
      return;
    }
    final id = _gpsSpoofUnitId!;
    final base = _rescueUnits.where((u) => u.id == id).firstOrNull ??
        _rescueUnitsRoster.where((u) => u.id == id).firstOrNull;
    if (base == null) return;
    final spoofed = RescueUnit(
      id: base.id,
      callSign: base.callSign,
      type: base.type,
      status: base.status,
      position: _gpsSpoofPosition!,
      assignedSOSId: base.assignedSOSId,
      stationId: base.stationId,
      barangayId: base.barangayId,
    );
    _rescueUnits = [
      for (final u in _rescueUnits)
        if (u.id != id) u,
      spoofed,
    ];
  }

  /// When the joystick runs in another tab, mirror Firebase spoof into
  /// [currentPosition] so dispatch/nav maps move without a refresh.
  /// Production GPS never sets debugGpsSpoof, so this is a no-op for real runs.
  void _adoptRemoteSpoofIntoCurrentPosition() {
    if (isGpsSpoofEnabled) return;
    final unitId =
        _currentResponderSessionUnitId ?? _currentResponderUnit?.id;
    if (unitId == null || !_remoteGpsSpoofUnitIds.contains(unitId)) return;
    final live = _rescueUnits.where((u) => u.id == unitId).firstOrNull;
    if (live == null) return;
    _currentPosition = live.position;
    if (_currentResponderUnit?.id == unitId) {
      _currentResponderUnit!.position = live.position;
    }
  }

  bool _isSessionUnitRemoteSpoofed() {
    final unitId =
        _currentResponderSessionUnitId ?? _currentResponderUnit?.id;
    return unitId != null && _remoteGpsSpoofUnitIds.contains(unitId);
  }

  Future<void> enableGpsSpoof(String unitId) async {
    if (!kDebugMode) return;
    final unit = _resolveUnitForDispatch(unitId) ??
        spoofableResponderUnits.where((u) => u.id == unitId).firstOrNull;
    if (unit == null) {
      throw StateError('Unit not found for GPS spoof.');
    }
    _gpsSpoofEnabled = true;
    _gpsSpoofUnitId = unitId;
    _gpsSpoofPosition = unit.position;
    _lastGpsSpoofError = null;
    if (_currentResponderSessionUnitId == unitId ||
        _currentResponderUnit?.id == unitId) {
      _currentPosition = _gpsSpoofPosition;
    }
    _mergeGpsSpoofIntoLiveUnits();
    _ensureGpsSpoofPushTimer();
    await _pushGpsSpoofLocation(force: true);
    notifyListeners();
  }

  Future<void> disableGpsSpoof() async {
    final unitId = _gpsSpoofUnitId;
    _gpsSpoofEnabled = false;
    _gpsSpoofUnitId = null;
    _gpsSpoofPosition = null;
    _lastGpsSpoofError = null;
    _gpsSpoofPushTimer?.cancel();
    _gpsSpoofPushTimer = null;
    if (unitId != null) {
      try {
        await _firebaseSync.clearUnitGpsSpoofLock(unitId);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Turn spoof off and resume device GPS for the logged-in unit if any.
  Future<void> resetGpsSpoofToReal() async {
    await disableGpsSpoof();
    try {
      final pos = await _locationService.getCurrentPosition();
      if (pos != null) {
        _currentPosition = pos;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Move spoofed pin by [northMeters] / [eastMeters] (joystick nudge).
  void nudgeGpsSpoof({
    required double northMeters,
    required double eastMeters,
  }) {
    if (!isGpsSpoofEnabled || _gpsSpoofPosition == null) return;
    final lat = _gpsSpoofPosition!.latitude;
    const metersPerDegLat = 111320.0;
    final metersPerDegLng =
        111320.0 * cos(lat * pi / 180).abs().clamp(0.2, 1.0);
    _gpsSpoofPosition = LatLng(
      lat + northMeters / metersPerDegLat,
      _gpsSpoofPosition!.longitude + eastMeters / metersPerDegLng,
    );
    if (_gpsSpoofUnitId != null &&
        (_currentResponderSessionUnitId == _gpsSpoofUnitId ||
            _currentResponderUnit?.id == _gpsSpoofUnitId)) {
      _currentPosition = _gpsSpoofPosition;
    }
    _mergeGpsSpoofIntoLiveUnits();
    notifyListeners();
    unawaited(_pushGpsSpoofLocation());
  }

  /// Continuous motion: apply velocity for [dt] at current spoof speed and stick.
  void applyGpsSpoofStick({
    required double stickX,
    required double stickY,
    required double dtSeconds,
  }) {
    if (!isGpsSpoofEnabled) return;
    final mag = sqrt(stickX * stickX + stickY * stickY);
    if (mag < 0.08 || dtSeconds <= 0) return;
    final nx = stickX / mag;
    final ny = -stickY / mag; // screen Y down → north up
    final speed = gpsSpoofSpeedKmh * mag.clamp(0.0, 1.0);
    final meters = speed * 1000 / 3600 * dtSeconds;
    nudgeGpsSpoof(
      northMeters: ny * meters,
      eastMeters: nx * meters,
    );
  }

  void _ensureGpsSpoofPushTimer() {
    _gpsSpoofPushTimer?.cancel();
    if (!isGpsSpoofEnabled) return;
    // Keep heartbeat fresh so other clients keep the unit "online".
    _gpsSpoofPushTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      unawaited(_pushGpsSpoofLocation(force: true));
    });
  }

  Future<void> _pushGpsSpoofLocation({bool force = false}) async {
    if (!isGpsSpoofEnabled) return;
    final unitId = _gpsSpoofUnitId;
    final pos = _gpsSpoofPosition;
    if (unitId == null || pos == null) return;

    final now = DateTime.now();
    if (!force &&
        _lastGpsSpoofPushAt != null &&
        now.difference(_lastGpsSpoofPushAt!) < const Duration(milliseconds: 350)) {
      _gpsSpoofPushPending = true;
      return;
    }
    if (_gpsSpoofPushInFlight) {
      _gpsSpoofPushPending = true;
      return;
    }
    _gpsSpoofPushInFlight = true;
    _gpsSpoofPushPending = false;
    _lastGpsSpoofPushAt = now;

    try {
      final unit = _resolveUnitForDispatch(unitId);
      if (unit == null) {
        _lastGpsSpoofError = 'Unit "$unitId" not found while pushing spoof GPS.';
        notifyListeners();
        return;
      }
      unit.position = pos;
      if (_currentResponderUnit?.id == unitId) {
        setCurrentResponderUnit(unit);
      }
      await _firebaseSync.updateUnitLocation(
        unit,
        useClientTimestamp: true,
        gpsSpoofActive: true,
      );
      _lastGpsSpoofError = null;
      _mergeGpsSpoofIntoLiveUnits();
      notifyListeners();
    } catch (e) {
      _lastGpsSpoofError = e.toString();
      notifyListeners();
    } finally {
      _gpsSpoofPushInFlight = false;
      if (_gpsSpoofPushPending && isGpsSpoofEnabled) {
        _gpsSpoofPushPending = false;
        unawaited(_pushGpsSpoofLocation(force: true));
      }
    }
  }
  List<SOSRequest> get pendingRequests {
    final pending = _sosRequests.where((r) => r.status == SOSStatus.pending);
    final unitBarangay = _responderUnitBarangayId;
    // No unit barangay yet → show nothing (avoid leaking every barangay's SOS).
    if (unitBarangay == null) return const [];
    final unit = _currentResponderUnit ??
        _rescueUnitsRoster
            .where((u) => u.id == _currentResponderSessionUnitId)
            .firstOrNull;
    return pending.where((r) {
      if (r.isOwnedByBarangay(unitBarangay)) return true;
      if (!r.isVisibleToBarangay(unitBarangay)) return false;
      if (unit == null) return false;
      return r.allowsAssistingUnitType(unitBarangay, unit.type);
    }).toList();
  }

  String? get _responderUnitBarangayId {
    final live = _currentResponderUnit;
    if (live != null) return normalizeBarangayId(live.barangayId);
    final sessionUnitId = _currentResponderSessionUnitId;
    if (sessionUnitId == null || sessionUnitId.isEmpty) return null;
    final roster =
        _rescueUnitsRoster.where((u) => u.id == sessionUnitId).firstOrNull;
    return roster == null ? null : normalizeBarangayId(roster.barangayId);
  }

  // --- Role management & multi-user session (local persistence) ---

  void setRole(UserRole role) {
    _currentRole = role;
    notifyListeners();
  }

  /// Saved role for app relaunch (citizen / responder / LGU).
  Future<UserRole?> readPersistedRole() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPersistedRoleKey);
      if (raw == null || raw.isEmpty) return null;
      for (final r in UserRole.values) {
        if (r.name == raw) return r;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> persistSessionRole(UserRole role) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPersistedRoleKey, role.name);
      if (role != UserRole.responder) {
        await prefs.remove(_kResponderSessionUnitIdKey);
      }
    } catch (_) {}
    _currentRole = role;
    notifyListeners();
  }

  Future<void> persistResponderSessionUnit(String unitId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPersistedRoleKey, UserRole.responder.name);
      await prefs.setString(_kResponderSessionUnitIdKey, unitId);
      if (_currentResponderSessionId != null) {
        await prefs.setString(_kResponderSessionIdKey, _currentResponderSessionId!);
      }
    } catch (_) {}
    _currentRole = UserRole.responder;
    notifyListeners();
  }

  Future<String?> readResponderSessionUnitId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kResponderSessionUnitIdKey);
    } catch (_) {
      return null;
    }
  }

  Future<String?> readResponderUnitLoginId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kResponderUnitLoginIdKey);
    } catch (_) {
      return null;
    }
  }

  Future<String?> readResponderSessionId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kResponderSessionIdKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPersistedSessionKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPersistedRoleKey);
      await prefs.remove(_kResponderSessionUnitIdKey);
      await prefs.remove(_kResponderUnitLoginIdKey);
      await prefs.remove(_kResponderSessionIdKey);
    } catch (_) {}
  }

  /// Clears citizen-specific prefs (profile, guest stats, active SOS pointer).
  Future<void> clearCitizenLocalPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCitizenNameKey);
      await prefs.remove(_kCitizenIdKey);
      await prefs.remove(_kCitizenModeKey);
      await prefs.remove(_kCitizenEmailKey);
      await prefs.remove(_kGuestSosCountTodayKey);
      await prefs.remove(_kGuestLastSosAtKey);
      await prefs.remove(_kGuestCounterDateKey);
      await prefs.remove(_kGuestStrikesKey);
      await prefs.remove(_kGuestIsBannedKey);
      await prefs.remove(_kActiveSosId);
    } catch (_) {}
    _citizenName = null;
    _citizenId = null;
    _citizenAccessMode = CitizenAccessMode.guest;
    _citizenEmail = null;
    _guestSosCountToday = 0;
    _guestLastSosAt = null;
    _guestCounterDate = null;
    _guestStrikes = 0;
    _guestIsBanned = false;
    _activeSosId = null;
  }

  /// Ends citizen session; app returns to role selection on next launch or after navigation.
  Future<void> citizenLogout() async {
    await clearPersistedSessionKeys();
    await clearCitizenLocalPrefs();
    await clearResponderNavigation();
    _currentRole = UserRole.citizen;
    notifyListeners();
  }

  /// Ends responder session: offline unit, clear GPS upload, session keys.
  Future<void> responderLogout(String unitId) async {
    await disableGpsSpoof();
    final loginId = _currentResponderUnitLoginId;
    final sessionUnitId = _currentResponderSessionUnitId ?? unitId;
    final sessionId = _currentResponderSessionId;
    _stopResponderSessionHeartbeat();
    if (loginId != null && sessionId != null && sessionUnitId.isNotEmpty) {
      await _firebaseSync.releaseResponderSessionLocks(
        loginId: loginId,
        responderUnitId: sessionUnitId,
        sessionId: sessionId,
      );
      await _firebaseSync.logAuditEvent(
        action: 'SESSION_LOGOUT_RELEASED',
        performedBy: loginId,
        targetId: sessionUnitId,
        details: const {},
      );
    }
    await goOffline(unitId);
    setCurrentResponderUnit(null);
    await clearPersistedSessionKeys();
    await clearResponderNavigation();
    _currentResponderUnitLoginId = null;
    _currentResponderSessionId = null;
    _currentResponderSessionUnitId = null;
    _currentRole = UserRole.citizen;
    notifyListeners();
  }

  /// Ends LGU session only (no unit to offline).
  Future<void> lguLogout() async {
    await clearPersistedSessionKeys();
    _currentRole = UserRole.citizen;
    notifyListeners();
  }

  // --- Firebase listeners ---

  void startFirebaseListeners() {
    if (_listenersStarted) return;
    _listenersStarted = true;

    _unitsSub = _firebaseSync.watchAllUnitLocations().listen(
      (event) {
        _rescueUnits = event.units;
        _remoteGpsSpoofUnitIds = event.spoofLockedUnitIds;
        _mergeGpsSpoofIntoLiveUnits();
        _adoptRemoteSpoofIntoCurrentPosition();
        _refreshRelocations();
        notifyListeners();
      },
      onError: (e, st) {
        _rescueUnits = [];
        _remoteGpsSpoofUnitIds = {};
        _mergeGpsSpoofIntoLiveUnits();
        notifyListeners();
      },
    );

    _sosSub = _firebaseSync.watchAllSOS().listen(
      (requests) {
        _sosRequests = requests;
        _refreshRelocations();
        notifyListeners();
      },
      onError: (e, st) {
        _sosRequests = [];
        notifyListeners();
      },
    );

    _sosHistorySub = _firebaseSync.watchSOSHistory().listen(
      (history) {
        _sosHistory = history;
        notifyListeners();
      },
      onError: (e, st) {
        _sosHistory = [];
        notifyListeners();
      },
    );

    _usersSub = _firebaseSync.watchAllUsers().listen(
      (rows) {
        _accountUsers = rows;
        notifyListeners();
      },
      onError: (e, st) {
        _accountUsers = [];
        notifyListeners();
      },
    );

    _unitAccountsSub = _firebaseSync.watchAllUnitAccounts().listen(
      (rows) {
        _unitAccounts = rows;
        notifyListeners();
      },
      onError: (e, st) {
        _unitAccounts = [];
        notifyListeners();
      },
    );

    _rosterSub = _firebaseSync.watchRescueUnitRoster().listen(
      (rows) {
        _rescueUnitsRoster = rows;
        notifyListeners();
      },
      onError: (e, st) {},
    );

    unawaited(_firebaseSync.seedDefaultRescueUnitsIfMissing());

    _hazardSub = _firebaseSync.watchAllHazardZones().listen(
      (zones) {
        _hazardZones = zones;
        _refreshRelocations();
        notifyListeners();
      },
      onError: (e, st) {
        _hazardZones = [];
        notifyListeners();
      },
    );

    // Periodically clean up very old SOS requests so they move to history
    // even if the original citizen app is already closed.
    _sosCleanupTimer ??=
        Timer.periodic(const Duration(minutes: 10), (_) async {
      try {
        await markOldSOSAsCompleted(
          olderThan: const Duration(hours: 2),
        );
      } catch (_) {
        // Best-effort cleanup; ignore failures so streams keep running.
      }
    });
  }

  void stopFirebaseListeners() {
    _unitsSub?.cancel();
    _sosSub?.cancel();
    _hazardSub?.cancel();
    _sosHistorySub?.cancel();
    _usersSub?.cancel();
    _unitAccountsSub?.cancel();
    _rosterSub?.cancel();
    _listenersStarted = false;
  }

  // --- Location ---

  /// Refreshes location status (service enabled, permission). Call to update "turn on location" UI.
  Future<void> refreshLocationStatus() async {
    _locationStatus = await _locationService.getLocationStatus();
    notifyListeners();
  }

  Future<void> initLocation() async {
    try {
      final granted = await _locationService.requestPermission();
      await refreshLocationStatus();
      if (!granted) {
        notifyListeners();
        return;
      }

      _currentPosition = await _locationService.getCurrentPosition();
      notifyListeners();

      // Use a smaller distance filter so camera follow / markers feel smoother.
      _locationService.startTracking(distanceFilterMeters: 2);
      _locationSub = _locationService.positionStream.listen((pos) {
        // While spoofing this session unit, ignore device GPS.
        if (isGpsSpoofEnabled &&
            (_gpsSpoofUnitId == _currentResponderSessionUnitId ||
                _gpsSpoofUnitId == _currentResponderUnit?.id)) {
          return;
        }
        // Joystick in another tab owns this unit — don't fight it with browser GPS.
        if (_isSessionUnitRemoteSpoofed()) return;
        _currentPosition = pos;
        notifyListeners();
      });
    } catch (_) {
      _currentPosition = null;
      await refreshLocationStatus();
      notifyListeners();
    }
  }

  /// Starts uploading the responder's GPS to Firebase every 3 seconds.
  /// [knownUnit] can be passed when the unit is not yet in Firebase (e.g. right after selecting from roster).
  void startGpsUpload(String unitId, [RescueUnit? knownUnit]) {
    _gpsUploadTimer?.cancel();

    Future<void> pushOnce() async {
      // Spoof path owns Firebase writes for this unit while enabled.
      if (isGpsSpoofEnabled && _gpsSpoofUnitId == unitId) return;
      if (_remoteGpsSpoofUnitIds.contains(unitId)) return;
      RescueUnit? unit =
          knownUnit?.id == unitId ? knownUnit : _resolveUnitForDispatch(unitId);
      if (unit == null) return;
      if (_currentPosition != null) {
        unit.position = _currentPosition!;
      }
      setCurrentResponderUnit(unit);
      try {
        await _firebaseSync.updateUnitLocation(unit);
      } catch (_) {}
    }

    unawaited(pushOnce());
    _gpsUploadTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(pushOnce());
    });
  }

  void stopGpsUpload() {
    _gpsUploadTimer?.cancel();
    _gpsUploadTimer = null;
  }

  /// Stops GPS upload and removes this unit from Firebase so the blip disappears on LGU/citizen maps.
  Future<void> goOffline(String unitId) async {
    stopGpsUpload();
    await _firebaseSync.removeUnitLocation(unitId);
    notifyListeners();
  }

  /// Logs dashboard exit for accountability (LGU can see audit log).
  Future<void> logDashboardExit({
    required String role,
    required String screen,
    String? unitId,
    String? sosId,
  }) async {
    await _firebaseSync.logDashboardExit(
      role: role,
      screen: screen,
      unitId: unitId,
      sosId: sosId,
    );
  }

  // --- SOS ---

  // --- Citizen profile (name/id) ---

  static const _kCitizenNameKey = 'citizen_name';
  static const _kCitizenIdKey = 'citizen_id';
  static const _kCitizenModeKey = 'citizen_mode';
  static const _kCitizenEmailKey = 'citizen_email';
  static const _kGuestSosCountTodayKey = 'guest_sos_count_today';
  static const _kGuestLastSosAtKey = 'guest_last_sos_at_ms';
  static const _kGuestCounterDateKey = 'guest_counter_date_yyyy_mm_dd';
  static const _kGuestStrikesKey = 'guest_strikes';
  static const _kGuestIsBannedKey = 'guest_is_banned';

  /// Loads citizen profile (name/id) from local storage.
  Future<void> loadCitizenProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _citizenName = prefs.getString(_kCitizenNameKey);
      _citizenId = prefs.getString(_kCitizenIdKey);
      final modeRaw = prefs.getString(_kCitizenModeKey);
      _citizenAccessMode = modeRaw == CitizenAccessMode.registered.name
          ? CitizenAccessMode.registered
          : CitizenAccessMode.guest;
      _citizenEmail = prefs.getString(_kCitizenEmailKey);
      _guestSosCountToday = prefs.getInt(_kGuestSosCountTodayKey) ?? 0;
      _guestStrikes = prefs.getInt(_kGuestStrikesKey) ?? 0;
      _guestIsBanned = prefs.getBool(_kGuestIsBannedKey) ?? false;
      final lastMs = prefs.getInt(_kGuestLastSosAtKey);
      _guestLastSosAt = lastMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastMs)
          : null;
      final dateRaw = prefs.getString(_kGuestCounterDateKey);
      if (dateRaw != null && dateRaw.isNotEmpty) {
        _guestCounterDate = DateTime.tryParse(dateRaw);
      }
      _resetGuestCounterIfNewDay();
      notifyListeners();
    } catch (_) {}
  }

  /// Saves citizen profile and generates a stable local ID if needed.
  Future<void> setCitizenProfile({required String name}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    _citizenName = trimmed;
    _citizenId ??= _citizenAccessMode == CitizenAccessMode.registered
        ? 'registered-${trimmed.hashCode}'
        : 'guest-${trimmed.hashCode}';

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCitizenNameKey, _citizenName!);
      await prefs.setString(_kCitizenIdKey, _citizenId!);
    } catch (_) {}
    if (_citizenId != null && _citizenName != null) {
      await _firebaseSync.upsertUserAccount(
        userId: _citizenId!,
        role: 'citizen',
        name: _citizenName!,
        email: _citizenEmail,
        isGuest: _citizenAccessMode == CitizenAccessMode.guest,
      );
    }
    notifyListeners();
  }

  Future<void> setCitizenAccessMode(
    CitizenAccessMode mode, {
    String? email,
  }) async {
    _citizenAccessMode = mode;
    _citizenEmail = mode == CitizenAccessMode.registered ? email : null;
    if (_citizenName != null && _citizenName!.isNotEmpty) {
      _citizenId = mode == CitizenAccessMode.registered
          ? 'registered-${_citizenName.hashCode}'
          : 'guest-${_citizenName.hashCode}';
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCitizenModeKey, mode.name);
      if (_citizenEmail != null && _citizenEmail!.trim().isNotEmpty) {
        await prefs.setString(_kCitizenEmailKey, _citizenEmail!.trim());
      } else {
        await prefs.remove(_kCitizenEmailKey);
      }
      if (_citizenId != null) {
        await prefs.setString(_kCitizenIdKey, _citizenId!);
      }
    } catch (_) {}
    if (_citizenId != null && _citizenName != null) {
      await _firebaseSync.upsertUserAccount(
        userId: _citizenId!,
        role: 'citizen',
        name: _citizenName!,
        email: _citizenEmail,
        isGuest: _citizenAccessMode == CitizenAccessMode.guest,
      );
    }
    notifyListeners();
  }

  Future<bool> isResponderApproved(String responderId) async {
    return (await _resolveResponseUnitStatus(responderId)).canTakeSos;
  }

  Future<void> setResponseUnitStatus({
    required String responderId,
    required ResponseUnitStatus status,
    String? name,
  }) async {
    await _firebaseSync.setResponseUnitStatus(
      responderId: responderId,
      status: status,
      name: name,
    );
    final idx = _accountUsers.indexWhere(
      (u) => (u['id']?.toString() ?? '') == responderId,
    );
    final next = idx >= 0
        ? Map<String, dynamic>.from(_accountUsers[idx])
        : <String, dynamic>{'id': responderId, 'role': 'responder'};
    next['role'] = 'responder';
    if (name != null && name.trim().isNotEmpty) next['name'] = name.trim();
    next['responseUnitStatus'] = status.wireName;
    next['approvedByLgu'] = status.canTakeSos;
    next['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    if (idx >= 0) {
      _accountUsers = [..._accountUsers]..[idx] = next;
    } else {
      _accountUsers = [..._accountUsers, next];
    }
    notifyListeners();
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

  /// True if LGU banned this citizen in RTDB (`users/{id}/bannedByLgu`).
  bool isCitizenBannedByLguFromCache(String? citizenId) {
    if (citizenId == null || citizenId.isEmpty) return false;
    final row = _accountUsers
        .where((u) => (u['id']?.toString() ?? '') == citizenId)
        .firstOrNull;
    return row != null && row['bannedByLgu'] == true;
  }

  String? citizenLguBanReasonFromCache(String? citizenId) {
    if (citizenId == null || citizenId.isEmpty) return null;
    final row = _accountUsers
        .where((u) => (u['id']?.toString() ?? '') == citizenId)
        .firstOrNull;
    final r = row?['banReason']?.toString();
    if (r == null || r.trim().isEmpty) return null;
    return r.trim();
  }

  Future<void> setCitizenBanByLgu({
    required String citizenId,
    required bool banned,
    String? reason,
  }) async {
    await _firebaseSync.setCitizenBan(
      citizenId: citizenId,
      banned: banned,
      reason: reason,
    );
    _accountUsers = _accountUsers.map((u) {
      if ((u['id']?.toString() ?? '') != citizenId) return u;
      final next = Map<String, dynamic>.from(u);
      next['bannedByLgu'] = banned;
      if (banned) {
        next['banReason'] = (reason ?? '').trim();
        next['bannedAt'] = DateTime.now().millisecondsSinceEpoch;
      } else {
        next.remove('banReason');
        next.remove('bannedAt');
      }
      next['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      return next;
    }).toList();
    if (!_accountUsers.any((u) => (u['id']?.toString() ?? '') == citizenId) &&
        banned) {
      _accountUsers = [
        ..._accountUsers,
        {
          'id': citizenId,
          'role': 'citizen',
          'name': citizenId,
          'bannedByLgu': true,
          'banReason': (reason ?? '').trim(),
          'bannedAt': DateTime.now().millisecondsSinceEpoch,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ];
    }
    notifyListeners();
  }

  Future<String> createUnitLoginAccount({
    required String loginId,
    required String responderUnitId,
    required String createdBy,
    String? temporaryPassword,
  }) async {
    final cleanId = loginId.trim().toLowerCase();
    if (cleanId.length < 4) {
      throw StateError('Login ID must be at least 4 characters.');
    }
    final existing = await _firebaseSync.getUnitAccountByLoginId(cleanId);
    if (existing != null && existing['softDeletedAt'] == null) {
      throw StateError('Login ID already exists.');
    }
    final tempPassword = (temporaryPassword?.trim().isNotEmpty == true
        ? temporaryPassword!.trim()
        : PasswordUtils.generateTemporaryPassword());
    if (!PasswordUtils.isStrongEnough(tempPassword)) {
      throw StateError(
        'Temporary password must be at least 8 chars with upper, lower, and number.',
      );
    }
    final roster =
        _rescueUnitsRoster.where((u) => u.id == responderUnitId).firstOrNull;
    if (roster == null) throw StateError('Response unit not found.');
    final salt = PasswordUtils.generateSalt();
    final hash = PasswordUtils.hashPassword(password: tempPassword, salt: salt);
    await _firebaseSync.createUnitAccount(
      loginId: cleanId,
      responderUnitId: responderUnitId,
      unitType: roster.type.name,
      passwordHash: hash,
      passwordSalt: salt,
      createdBy: createdBy,
      barangayId: roster.barangayId,
    );
    await _firebaseSync.logAuditEvent(
      action: 'CREATE_UNIT_ACCOUNT',
      performedBy: createdBy,
      targetId: cleanId,
      details: {
        'responderUnitId': responderUnitId,
        'unitType': roster.type.name,
      },
    );
    return tempPassword;
  }

  Future<String> resetUnitLoginPassword({
    required String loginId,
    required String performedBy,
    String? newTemporaryPassword,
  }) async {
    final account = await _firebaseSync.getUnitAccountByLoginId(loginId);
    if (account == null) throw StateError('Account not found.');
    final tempPassword = (newTemporaryPassword?.trim().isNotEmpty == true
        ? newTemporaryPassword!.trim()
        : PasswordUtils.generateTemporaryPassword());
    if (!PasswordUtils.isStrongEnough(tempPassword)) {
      throw StateError(
        'Temporary password must be at least 8 chars with upper, lower, and number.',
      );
    }
    final salt = PasswordUtils.generateSalt();
    final hash = PasswordUtils.hashPassword(password: tempPassword, salt: salt);
    await _firebaseSync.resetUnitPassword(
      loginId: loginId,
      passwordHash: hash,
      passwordSalt: salt,
      forceChangeOnNextLogin: true,
    );
    await _firebaseSync.logAuditEvent(
      action: 'RESET_UNIT_ACCOUNT_PASSWORD',
      performedBy: performedBy,
      targetId: loginId,
      details: const {},
    );
    return tempPassword;
  }

  Future<void> updateUnitAccountMeta({
    required String loginId,
    required String performedBy,
    String? responderUnitId,
    String? status,
    bool? mustChangePassword,
  }) async {
    String? unitType;
    String? wireStatus = status?.trim();
    if (wireStatus != null && wireStatus.isNotEmpty) {
      final lower = wireStatus.toLowerCase();
      if (lower == 'active' || lower == 'disabled') {
        wireStatus = lower;
      } else {
        wireStatus = parseResponseUnitStatus(wireStatus).wireName;
      }
    } else {
      wireStatus = null;
    }
    if (responderUnitId != null) {
      final roster =
          _rescueUnitsRoster.where((u) => u.id == responderUnitId).firstOrNull;
      if (roster == null) throw StateError('Response unit not found.');
      unitType = roster.type.name;
      await _firebaseSync.updateUnitAccount(
        loginId,
        responderUnitId: responderUnitId,
        unitType: unitType,
        status: wireStatus,
        mustChangePassword: mustChangePassword,
        barangayId: roster.barangayId,
      );
    } else {
      await _firebaseSync.updateUnitAccount(
        loginId,
        responderUnitId: responderUnitId,
        unitType: unitType,
        status: wireStatus,
        mustChangePassword: mustChangePassword,
      );
    }
    await _firebaseSync.logAuditEvent(
      action: 'UPDATE_UNIT_ACCOUNT',
      performedBy: performedBy,
      targetId: loginId,
      details: {
        if (responderUnitId != null) 'responderUnitId': responderUnitId,
        if (wireStatus != null) 'status': wireStatus,
        if (mustChangePassword != null) 'mustChangePassword': mustChangePassword,
      },
    );
  }

  Future<void> softDeleteUnitAccount({
    required String loginId,
    required String performedBy,
  }) async {
    if (_currentResponderUnitLoginId == loginId) {
      throw StateError('Cannot delete currently logged-in responder account.');
    }
    await _firebaseSync.softDeleteUnitAccount(loginId);
    await _firebaseSync.logAuditEvent(
      action: 'DELETE_UNIT_ACCOUNT',
      performedBy: performedBy,
      targetId: loginId,
      details: const {},
    );
  }

  Future<Map<String, dynamic>> loginResponderUnitWithCredentials({
    required String loginId,
    required String password,
  }) async {
    final cleanId = loginId.trim().toLowerCase();
    if (cleanId.isEmpty || password.isEmpty) {
      throw StateError('Login ID and password are required.');
    }
    final account = await _firebaseSync.getUnitAccountByLoginId(cleanId);
    if (account == null) throw StateError('Account not found.');
    if (account['softDeletedAt'] != null) {
      throw StateError('Account has been deleted by LGU.');
    }
    if (unitLoginIsDisabled(account['status']?.toString())) {
      throw StateError('This responder login is disabled and cannot sign in.');
    }
    final hash = account['passwordHash']?.toString() ?? '';
    final salt = account['passwordSalt']?.toString() ?? '';
    final ok = PasswordUtils.verifyPassword(
      password: password,
      salt: salt,
      expectedHash: hash,
    );
    if (!ok) throw StateError('Invalid credentials.');
    final responderUnitId = account['responderUnitId']?.toString() ?? '';
    if (responderUnitId.isEmpty) {
      throw StateError('No unit is mapped to this account.');
    }
    final unitStatus = await _firebaseSync.getResponseUnitStatus(responderUnitId);
    if (!unitStatus.canSignIn) {
      throw StateError(unitStatus.signInBlockedMessage);
    }
    final sessionId = const Uuid().v4();
    final lockRes = await _firebaseSync.acquireResponderSessionLocks(
      loginId: cleanId,
      responderUnitId: responderUnitId,
      sessionId: sessionId,
      ttlMs: 120 * 1000,
      deviceInfo: kIsWeb ? 'web' : 'mobile',
    );
    if (!lockRes.success) {
      if (lockRes.reason == 'ACCOUNT_LOCKED') {
        await _firebaseSync.logAuditEvent(
          action: 'SESSION_LOGIN_BLOCKED_ACCOUNT_LOCK',
          performedBy: cleanId,
          targetId: responderUnitId,
          details: const {},
        );
        throw StateError(
          'This account is already signed in on another device/tab. Log out there or wait 30 seconds.',
        );
      }
      await _firebaseSync.logAuditEvent(
        action: 'SESSION_LOGIN_BLOCKED_UNIT_LOCK',
        performedBy: cleanId,
        targetId: responderUnitId,
        details: const {},
      );
      throw StateError(
        'This vehicle/unit is already in use by another active session. Log out there or wait 30 seconds.',
      );
    }
    _currentResponderUnitLoginId = cleanId;
    _currentResponderSessionId = sessionId;
    _currentResponderSessionUnitId = responderUnitId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kResponderUnitLoginIdKey, cleanId);
      await prefs.setString(_kResponderSessionIdKey, sessionId);
    } catch (_) {}
    await _firebaseSync.logAuditEvent(
      action: 'SESSION_LOGIN_GRANTED',
      performedBy: cleanId,
      targetId: responderUnitId,
      details: {'sessionId': sessionId},
    );
    await _startResponderSessionHeartbeat();
    return account;
  }

  void _resetGuestCounterIfNewDay() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final saved = _guestCounterDate == null
        ? null
        : DateTime(_guestCounterDate!.year, _guestCounterDate!.month, _guestCounterDate!.day);
    if (saved == null || saved != today) {
      _guestCounterDate = today;
      _guestSosCountToday = 0;
    }
  }

  Future<void> _persistGuestAccessState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kGuestSosCountTodayKey, _guestSosCountToday);
      await prefs.setInt(_kGuestStrikesKey, _guestStrikes);
      await prefs.setBool(_kGuestIsBannedKey, _guestIsBanned);
      if (_guestLastSosAt != null) {
        await prefs.setInt(
          _kGuestLastSosAtKey,
          _guestLastSosAt!.millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove(_kGuestLastSosAtKey);
      }
      if (_guestCounterDate != null) {
        await prefs.setString(_kGuestCounterDateKey, _guestCounterDate!.toIso8601String());
      }
    } catch (_) {}
  }

  ({bool allowed, String? reason}) _canGuestSendSosNow() {
    if (_guestIsBanned || _guestStrikes >= 3) {
      return (allowed: false, reason: 'Guest account is banned due to repeated false alarms.');
    }
    _resetGuestCounterIfNewDay();
    if (_guestSosCountToday >= 3) {
      return (allowed: false, reason: 'Guest daily SOS limit reached (3/day).');
    }
    final now = DateTime.now();
    if (_guestLastSosAt != null) {
      final sec = now.difference(_guestLastSosAt!).inSeconds;
      if (sec < 60) {
        return (
          allowed: false,
          reason: 'Please wait ${60 - sec}s before sending another guest SOS.'
        );
      }
    }
    return (allowed: true, reason: null);
  }

  // --- Active SOS tracking (citizen) ---

  Future<void> loadActiveSOS() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _activeSosId = prefs.getString(_kActiveSosId);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setActiveSOS(String sosId) async {
    _activeSosId = sosId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveSosId, sosId);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> clearActiveSOS() async {
    _activeSosId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kActiveSosId);
    } catch (_) {}
    notifyListeners();
  }

  /// Call when citizen cancels SOS: move to history as cancelled, remove from active, clear unit assignment, clear persisted state.
  Future<void> cancelCitizenSOS(String sosId) async {
    final request = _sosRequests.where((r) => r.id == sosId).firstOrNull;
    if (request != null) {
      if (_citizenAccessMode == CitizenAccessMode.guest &&
          request.assignedUnitId != null) {
        _guestStrikes = (_guestStrikes + 1).clamp(0, 3);
        if (_guestStrikes >= 3) _guestIsBanned = true;
        await _persistGuestAccessState();
      }
      await _firebaseSync.resolveSOS(request);
      // Clear the assigned unit so rescuer dashboard no longer shows this SOS.
      if (request.assignedUnitId != null) {
        final unit = _rescueUnits.where((u) => u.id == request.assignedUnitId).firstOrNull;
        if (unit != null) {
          unit.status = UnitStatus.idle;
          unit.assignedSOSId = null;
          await _firebaseSync.updateUnitLocation(unit);
        }
      }
    } else {
      await _firebaseSync.removeActiveSOS(sosId);
    }
    await clearActiveSOS();
    await clearResponderNavigationIfMatches(sosId);
    notifyListeners();
  }

  /// Responder aborts an active response (SOS becomes cancelled in history). Does not clear citizen local prefs.
  Future<void> responderAbortSOS({
    required String sosId,
    required String unitId,
  }) async {
    // Session lock can flake on web; never block cancel of our own assignment.
    if (_currentRole == UserRole.responder) {
      final lockOk = await ensureResponderSessionIsValid(
        unitId: unitId,
        logOnFailure: false,
      );
      if (!lockOk) {
        // Best-effort heartbeat; still proceed so Cancel always works.
        try {
          final loginId = _currentResponderUnitLoginId;
          final sessionId = _currentResponderSessionId;
          if (loginId != null && sessionId != null) {
            await _firebaseSync.heartbeatResponderSessionLocks(
              loginId: loginId,
              responderUnitId: unitId,
              sessionId: sessionId,
              ttlMs: 120 * 1000,
            );
          }
        } catch (_) {}
      }
    }

    var request = _sosRequests.where((r) => r.id == sosId).firstOrNull;
    request ??= await _firebaseSync.getActiveSOSById(sosId);

    if (request == null) {
      await _firebaseSync.removeActiveSOS(sosId);
      await _clearUnitAssignmentAfterAbort(unitId);
      _sosRequests = _sosRequests.where((r) => r.id != sosId).toList();
      clearRoute();
      await clearResponderNavigationIfMatches(sosId);
      _refreshRelocations();
      notifyListeners();
      return;
    }

    // Only block if clearly assigned to a *different* live unit.
    if (request.assignedUnitId != null &&
        request.assignedUnitId!.isNotEmpty &&
        request.assignedUnitId != unitId) {
      throw StateError(
        'This SOS is assigned to another unit (${request.assignedUnitId}).',
      );
    }

    await _firebaseSync.resolveSOS(request);
    await _clearUnitAssignmentAfterAbort(unitId);

    _sosRequests = _sosRequests.where((r) => r.id != sosId).toList();
    clearRoute();
    await clearResponderNavigationIfMatches(sosId);
    _refreshRelocations();
    notifyListeners();
  }

  Future<void> _clearUnitAssignmentAfterAbort(String unitId) async {
    final unit = _resolveUnitForDispatch(unitId);
    if (unit != null) {
      unit.status = UnitStatus.idle;
      unit.assignedSOSId = null;
      try {
        await _firebaseSync.updateUnitLocation(unit, force: true);
      } catch (_) {}
    } else {
      try {
        await _firebaseSync.clearUnitAssignment(unitId);
      } catch (_) {}
    }
    if (_currentResponderUnit?.id == unitId) {
      _currentResponderUnit?.status = UnitStatus.idle;
      _currentResponderUnit?.assignedSOSId = null;
    }
  }

  /// Call when rescuer arrives and victim is assisted: mark completed, move to history, remove from map.
  Future<void> completeSOS(SOSRequest request) async {
    final unitId = request.assignedUnitId ?? _currentResponderSessionUnitId;
    // Session lock can flake on web; never block completing our own assignment.
    if (_currentRole == UserRole.responder) {
      final lockOk = await ensureResponderSessionIsValid(
        unitId: unitId,
        logOnFailure: false,
      );
      if (!lockOk) {
        try {
          final loginId = _currentResponderUnitLoginId;
          final sessionId = _currentResponderSessionId;
          if (loginId != null && unitId != null && sessionId != null) {
            await _firebaseSync.heartbeatResponderSessionLocks(
              loginId: loginId,
              responderUnitId: unitId,
              sessionId: sessionId,
              ttlMs: 120 * 1000,
            );
          }
        } catch (_) {}
      }
    }

    // Prefer a fresh copy from Firebase in case the in-memory SOS is stale.
    var active = _sosRequests.where((r) => r.id == request.id).firstOrNull;
    active ??= await _firebaseSync.getActiveSOSById(request.id);
    final toComplete = active ?? request;

    if (toComplete.assignedUnitId != null &&
        toComplete.assignedUnitId!.isNotEmpty &&
        unitId != null &&
        toComplete.assignedUnitId != unitId &&
        _currentRole == UserRole.responder) {
      throw StateError(
        'This SOS is assigned to another unit (${toComplete.assignedUnitId}).',
      );
    }

    // Compute evaluation metrics for this incident.
    final now = DateTime.now();
    double? unitDistanceKm;
    final resolveId = toComplete.assignedUnitId ?? unitId;
    if (resolveId != null) {
      final unit = _resolveUnitForDispatch(resolveId);
      if (unit != null) {
        final dist = GeoUtils.haversineKm(unit.position, toComplete.location);
        unitDistanceKm = dist.isFinite ? dist : null;
        unit.status = UnitStatus.idle;
        unit.assignedSOSId = null;
        try {
          await _firebaseSync.updateUnitLocation(unit, force: true);
        } catch (_) {}
      } else {
        try {
          await _firebaseSync.clearUnitAssignment(resolveId);
        } catch (_) {}
      }
      if (_currentResponderUnit?.id == resolveId) {
        _currentResponderUnit?.status = UnitStatus.idle;
        _currentResponderUnit?.assignedSOSId = null;
      }
    }

    final responseTimeSeconds =
        now.difference(toComplete.createdAt).inSeconds.clamp(0, 24 * 60 * 60);
    final relocationStrategy =
        _relocationStrategyBySosId.remove(toComplete.id) ?? 'unknown';

    await _firebaseSync.completeSOS(
      toComplete,
      extraMetrics: {
        'responseTimeSeconds': responseTimeSeconds,
        if (unitDistanceKm != null)
          'unitDistanceKmAtCompletion': unitDistanceKm,
        'relocationStrategy': relocationStrategy,
        if (_osrmDistanceKm.isFinite) 'osrmDistanceKm': _osrmDistanceKm,
        if (_osrmEtaMinutes.isFinite) 'osrmEtaMinutes': _osrmEtaMinutes,
        if (_safeDistanceKm.isFinite) 'safeDistanceKm': _safeDistanceKm,
        if (_safeEtaMinutes.isFinite) 'safeEtaMinutes': _safeEtaMinutes,
        'osrmHazardCrossings': _osrmHazardCrossings,
        'safeHazardCrossings': _safeHazardCrossings,
      },
    );

    // Drop from local list immediately so markers/waypoints disappear without waiting for stream.
    _sosRequests = _sosRequests.where((r) => r.id != toComplete.id).toList();
    clearRoute();
    await clearResponderNavigationIfMatches(toComplete.id);
    _refreshRelocations();
    notifyListeners();
  }

  /// Persists active navigation so returning to dispatch can resume the map after app restarts.
  Future<void> persistResponderNavigation({
    required String sosId,
    required String unitId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kResponderNavSosId, sosId);
      await prefs.setString(_kResponderNavUnitId, unitId);
    } catch (_) {}
  }

  Future<void> clearResponderNavigation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kResponderNavSosId);
      await prefs.remove(_kResponderNavUnitId);
    } catch (_) {}
  }

  Future<void> clearResponderNavigationIfMatches(String sosId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_kResponderNavSosId) == sosId) {
        await prefs.remove(_kResponderNavSosId);
        await prefs.remove(_kResponderNavUnitId);
      }
    } catch (_) {}
  }

  /// Returns persisted navigation target, if any.
  Future<({String? sosId, String? unitId})> readResponderNavigation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (
        sosId: prefs.getString(_kResponderNavSosId),
        unitId: prefs.getString(_kResponderNavUnitId),
      );
    } catch (_) {
      return (sosId: null, unitId: null);
    }
  }

  Future<SOSRequest> createSOS({
    required String citizenId,
    required String citizenName,
    String? message,
    SOSPriority priority = SOSPriority.high,
    SOSType sosType = SOSType.medical,
    String? preferredFacilityId,
    String? preferredFacilityName,
    LatLng? preferredFacilityLocation,
  }) async {
    if (_currentPosition == null) {
      throw StateError('Location not available. Cannot create SOS.');
    }

    if (_citizenAccessMode == CitizenAccessMode.guest) {
      final gate = _canGuestSendSosNow();
      if (!gate.allowed) {
        throw StateError(gate.reason ?? 'Guest SOS blocked.');
      }
    }

    final lgBan = await _firebaseSync.getCitizenBanStatus(citizenId);
    if (lgBan.banned) {
      final msg = lgBan.reason != null && lgBan.reason!.trim().isNotEmpty
          ? 'Account suspended by LGU: ${lgBan.reason!.trim()}'
          : 'This account has been suspended by LGU.';
      throw StateError(msg);
    }

    // Prevent duplicate active SOS: if this citizen already has an active request, do not create another.
    if (_activeSosId != null) {
      final existing = _sosRequests.where((r) => r.id == _activeSosId && r.isActive).firstOrNull;
      if (existing != null) {
        throw StateError('You already have an active SOS. Cancel it first or wait for help.');
      }
    }

    final request = SOSRequest(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      location: _currentPosition!,
      citizenId: citizenId,
      citizenName: citizenName,
      message: message,
      priority: priority,
      sosType: sosType,
      createdAt: DateTime.now(),
      preferredFacilityId: preferredFacilityId,
      preferredFacilityName: preferredFacilityName,
      preferredFacilityLocation: preferredFacilityLocation,
      barangayId: kDefaultBarangayId,
    );

    await _firebaseSync.publishSOS(request);
    if (_citizenAccessMode == CitizenAccessMode.guest) {
      _resetGuestCounterIfNewDay();
      _guestSosCountToday += 1;
      _guestLastSosAt = DateTime.now();
      await _persistGuestAccessState();
    }
    await setActiveSOS(request.id);
    notifyListeners();
    return request;
  }

  /// Continuously update the citizen's location on their active SOS.
  /// When [pinLocation] is true, GPS still updates locally but does not move the SOS pin.
  void startCitizenLocationUpdates(String sosId, {bool pinLocation = false}) {
    _locationSub?.cancel();
    _locationSub = _locationService.positionStream.listen((pos) {
      _currentPosition = pos;
      if (!pinLocation) {
        _firebaseSync.updateSOSLocation(sosId, pos);
      }
      notifyListeners();
    });
  }

  /// Stops pushing location to the citizen's SOS. Call when leaving the citizen SOS screen.
  void stopCitizenLocationUpdates() {
    _locationSub?.cancel();
    _locationSub = null;
    // Smaller distance filter for smoother map movement.
    _locationService.startTracking(distanceFilterMeters: 2);
    _locationSub = _locationService.positionStream.listen((pos) {
      _currentPosition = pos;
      notifyListeners();
    });
  }

  /// Marks all SOS older than [olderThan] as completed (moves to history). Returns count moved.
  Future<int> markOldSOSAsCompleted({Duration olderThan = const Duration(hours: 24)}) async {
    final list = await _firebaseSync.getActiveSOSOnce();
    final cutoff = DateTime.now().subtract(olderThan);
    int count = 0;
    for (final request in list) {
      if (request.createdAt.isBefore(cutoff)) {
        await _firebaseSync.completeSOS(request);
        count++;
      }
    }
    if (count > 0) notifyListeners();
    return count;
  }

  // --- Dispatch & Routing ---

  /// Live GPS unit, else the in-memory responder session unit, else roster + GPS/station.
  RescueUnit? _resolveUnitForDispatch(String unitId) {
    final spoofPos = (isGpsSpoofEnabled && _gpsSpoofUnitId == unitId)
        ? _gpsSpoofPosition
        : null;
    final live = _rescueUnits.where((u) => u.id == unitId).firstOrNull;
    if (live != null) {
      if (spoofPos != null) {
        live.position = spoofPos;
      } else if (_currentPosition != null) {
        live.position = _currentPosition!;
      }
      return live;
    }
    if (_currentResponderUnit?.id == unitId) {
      final unit = _currentResponderUnit!;
      if (spoofPos != null) {
        unit.position = spoofPos;
      } else if (_currentPosition != null) {
        unit.position = _currentPosition!;
      }
      return unit;
    }
    final roster = _rescueUnitsRoster.where((u) => u.id == unitId).firstOrNull;
    if (roster == null) return null;
    return RescueUnit(
      id: roster.id,
      callSign: roster.callSign,
      type: roster.type,
      status: UnitStatus.idle,
      position: spoofPos ?? _currentPosition ?? roster.position,
      stationId: roster.stationId,
      barangayId: roster.barangayId,
    );
  }

  Future<void> acceptDispatch({
    required String unitId,
    required String sosId,
  }) async {
    if (_currentRole == UserRole.responder) {
      final lockOk = await ensureResponderSessionIsValid(unitId: unitId);
      if (!lockOk) {
        throw StateError(
          'Your responder session expired or is missing. '
          'Sign out and sign in again, then retry Accept.',
        );
      }
    }
    final unit = _resolveUnitForDispatch(unitId);
    final sos = _sosRequests.where((r) => r.id == sosId).firstOrNull;

    if (unit == null) {
      throw StateError('Rescue unit "$unitId" not found. '
          'Firebase may not have loaded yet.');
    }
    if (sos == null) {
      throw StateError('SOS request "$sosId" not found.');
    }
    final unitBarangay = normalizeBarangayId(unit.barangayId);
    if (!sos.isOwnedByBarangay(unitBarangay)) {
      if (!sos.isVisibleToBarangay(unitBarangay) ||
          !sos.allowsAssistingUnitType(unitBarangay, unit.type)) {
        throw StateError(
          'This SOS is not available to Barangay $unitBarangay. '
          'Mutual aid must be accepted by your command center first.',
        );
      }
    }
    if (!canUnitHandleSos(unit.type, sos.sosType)) {
      throw StateError(
        '${unitTypeLabel(unit.type)} unit cannot accept ${SOSTypeInfo.forType(sos.sosType).label.toLowerCase()} SOS.',
      );
    }
    final readiness = await _resolveResponseUnitStatus(unitId);
    if (!readiness.canTakeSos) {
      throw StateError(
        readiness.cannotTakeSosMessage.isNotEmpty
            ? readiness.cannotTakeSosMessage
            : 'This unit is not In service.',
      );
    }

    // Ensure the unit exists in live locations so accept/write and UI stay in sync.
    setCurrentResponderUnit(unit);
    if (!_rescueUnits.any((u) => u.id == unit.id)) {
      _rescueUnits = [..._rescueUnits, unit];
    }
    try {
      await _firebaseSync.updateUnitLocation(unit);
    } catch (_) {}

    // Remember whether this dispatch used a relocation suggestion (for evaluation).
    final usedSuggestion = _relocationSuggestions.containsKey(unit.id);
    _relocationStrategyBySosId[sosId] =
        usedSuggestion ? 'suggested' : 'none';

    unit.status = UnitStatus.enRoute;
    unit.assignedSOSId = sosId;
    sos.status = SOSStatus.dispatched;
    sos.assignedUnitId = unitId;

    await _firebaseSync.acceptDispatch(sosId: sosId, unit: unit);
    await _firebaseSync.logAuditEvent(
      action: sos.isOwnedByBarangay(unit.barangayId)
          ? 'UNIT_ACCEPT_DISPATCH'
          : 'MUTUAL_AID_UNIT_ACCEPT',
      performedBy: unit.callSign,
      targetId: sosId,
      details: {
        'unitId': unit.id,
        'unitBarangayId': normalizeBarangayId(unit.barangayId),
        'sosBarangayId': sos.barangayId,
      },
    );
    await _firebaseSync.updateDispatchProgress(
      sosId,
      status: 'enRoute',
      phase: 'enRouteToPatient',
      routingTo: 'sos',
      destinationName: 'SOS location',
      destinationLocation: sos.location,
    );

    // Do not block Accept on slow OSRM — route preview can compute/show when ready.
    unawaited(computeRoute(from: unit.position, to: sos.location));
    _refreshRelocations();
    notifyListeners();
  }

  Future<List<OsrmRouteResult>> _getOsrmRoutes(LatLng from, LatLng to) async {
    try {
      final list = await _osrmService.getRouteWithAlternatives(from, to);
      if (list.isNotEmpty) return list;
    } catch (_) {}
    try {
      final list = await _osrmService.getRouteWithAlternatives(from, to);
      if (list.isNotEmpty) return list;
    } catch (_) {}
    return [];
  }

  /// Mock traffic coloring by **distance along route** — congestion only on the last
  /// ~12–22% of the path (near SOS), not arbitrary thirds of polyline points.
  static List<RouteTrafficSegment> _buildTrafficSegments(List<LatLng> points) {
    if (points.length < 2) return [];
    final totalKm = RouteGeoUtils.polylineLengthKm(points);
    if (totalKm < 1e-9) return [];

    final t1 = totalKm * 0.78;
    final t2 = totalKm * 0.88;

    TrafficLevel levelAt(double distAlongKm) {
      if (distAlongKm <= t1) return TrafficLevel.clear;
      if (distAlongKm <= t2) return TrafficLevel.moderate;
      return TrafficLevel.heavy;
    }

    final cum = <double>[0];
    for (var i = 0; i < points.length - 1; i++) {
      cum.add(cum.last + GeoUtils.haversineKm(points[i], points[i + 1]));
    }

    final levels = cum.map((d) => levelAt(d)).toList();

    final segs = <RouteTrafficSegment>[];
    var segStart = 0;
    for (var k = 1; k < points.length; k++) {
      if (levels[k] != levels[segStart]) {
        final endExclusive = (k + 1).clamp(segStart + 2, points.length);
        if (endExclusive - segStart >= 2) {
          segs.add(RouteTrafficSegment(
            points: points.sublist(segStart, endExclusive),
            level: levels[segStart],
          ));
        }
        segStart = k;
      }
    }
    if (points.length - segStart >= 2) {
      segs.add(RouteTrafficSegment(
        points: points.sublist(segStart),
        level: levels[segStart],
      ));
    }
    if (segs.isEmpty && points.length >= 2) {
      return [
        RouteTrafficSegment(
          points: List<LatLng>.from(points),
          level: TrafficLevel.clear,
        ),
      ];
    }
    return segs;
  }

  /// Snaps the route end to the SOS point when OSRM ends short of the destination.
  static void _snapRouteEndToTarget(List<LatLng> points, LatLng target) {
    if (points.isEmpty) return;
    // Keep this extremely small so we don't draw a visible "off-road tail"
    // when the target is inside a building/compound.
    if (GeoUtils.haversineKm(points.last, target) > 0.005) {
      points.add(target);
    }
  }

  Future<void> computeRoute({required LatLng from, required LatLng to}) async {
    // Snap endpoints to nearest road to improve OSRM road accuracy and
    // avoid straight-line tails into non-routable coordinates.
    final snappedFrom = await _osrmService.nearest(from);
    final snappedTo = await _osrmService.nearest(to);
    _aStarRoute = _routingService.findRoute(
      start: snappedFrom,
      goal: snappedTo,
      hazardZones: _hazardZones,
    );

    // Compute basic metrics for the hazard-aware (A*) route.
    _safeDistanceKm = 0;
    _safeEtaMinutes = 0;
    _safeHazardCrossings = 0;
    if (_aStarRoute.length >= 2) {
      for (var i = 0; i < _aStarRoute.length - 1; i++) {
        _safeDistanceKm += GeoUtils.haversineKm(
          _aStarRoute[i],
          _aStarRoute[i + 1],
        );
      }
      // Simple ETA model: assume 0.5 km/min (~30 km/h) when no OSRM data.
      _safeEtaMinutes = _safeDistanceKm > 0 ? _safeDistanceKm / 0.5 : 0;
      _safeHazardCrossings = _countHazardCrossings(_aStarRoute);
    }

    final osrmList = await _getOsrmRoutes(snappedFrom, snappedTo);

    if (osrmList.isNotEmpty) {
      // Pick the OSRM route whose geometry is closest to the responder's current position.
      // This makes the thick "blue primary" line actually follow the responder
      // when rerouting / deviating (instead of always using OSRM's first route).
      var bestIndex = 0;
      var bestMinDistKm = double.infinity;
      for (var i = 0; i < osrmList.length; i++) {
        final points = osrmList[i].points;
        if (points.isEmpty) continue;
        final minDistKm = points
            .map((p) => GeoUtils.haversineKm(from, p))
            .reduce((a, b) => a < b ? a : b);
        if (minDistKm < bestMinDistKm) {
          bestMinDistKm = minDistKm;
          bestIndex = i;
        }
      }

      final primary = osrmList[bestIndex];
      final rest = <OsrmRouteResult>[
        for (var i = 0; i < osrmList.length; i++)
          if (i != bestIndex) osrmList[i],
      ];

      _osrmRoute = List<LatLng>.from(primary.points);
      // OSRM geometry should already end near snappedTo; only tiny snap if needed.
      _snapRouteEndToTarget(_osrmRoute, snappedTo);
      _osrmEtaMinutes = primary.durationMinutes;
      _osrmDistanceKm = primary.distanceKm;
      _osrmAlternates = rest.map((r) => r.points).toList();
      _navigationSteps = List<OsrmNavigationStep>.from(primary.navigationSteps);
      _routeTrafficSegments = _buildTrafficSegments(_osrmRoute);
    } else {
      _osrmRoute = [];
      _osrmAlternates = [];
      _routeTrafficSegments = [];
      _navigationSteps = [];
      final distKm = GeoUtils.haversineKm(from, to);
      _osrmDistanceKm = distKm;
      _osrmEtaMinutes = distKm / 0.5;
    }

    _osrmHazardCrossings = _countHazardCrossings(_osrmRoute);

    notifyListeners();
  }

  int _countHazardCrossings(List<LatLng> route) {
    if (route.isEmpty || _hazardZones.isEmpty) return 0;
    int crosses = 0;
    for (final zone in _hazardZones.where((z) => z.isActive)) {
      final inside = route.any(zone.containsPoint);
      if (inside) crosses++;
    }
    return crosses;
  }

  /// Selects which route is primary (0 = current primary, 1 = first alternate, etc.).
  void selectRouteByIndex(int index) {
    if (index <= 0 || _osrmAlternates.isEmpty) return;
    if (index <= _osrmAlternates.length) {
      final newPrimary = List<LatLng>.from(_osrmAlternates[index - 1]);
      final newAlternates = <List<LatLng>>[
        List<LatLng>.from(_osrmRoute),
        ..._osrmAlternates.asMap().entries
            .where((e) => e.key != index - 1)
            .map((e) => e.value),
      ];
      _osrmRoute = newPrimary;
      _osrmAlternates = newAlternates;
      _routeTrafficSegments = _buildTrafficSegments(_osrmRoute);
      _navigationSteps = [];
      notifyListeners();
    }
  }

  void clearRoute() {
    _aStarRoute = [];
    _osrmRoute = [];
    _osrmAlternates = [];
    _routeTrafficSegments = [];
    _navigationSteps = [];
    _osrmEtaMinutes = 0;
    _osrmDistanceKm = 0;
    notifyListeners();
  }

  // --- Hazard Zones (LGU) ---

  Future<void> addHazardZone(HazardZone zone) async {
    await _firebaseSync.publishHazardZone(zone);
    notifyListeners();
  }

  Future<void> resolveHazardZone(String zoneId) async {
    await _firebaseSync.resolveHazardZone(zoneId);
    notifyListeners();
  }

  // --- Units ---

  Future<bool> registerUnit(RescueUnit unit) async {
    if (_currentRole == UserRole.responder) {
      final lockOk = await ensureResponderSessionIsValid(unitId: unit.id);
      if (!lockOk) {
        throw StateError('Session is active elsewhere. Please sign in again.');
      }
    }
    final status = await _resolveResponseUnitStatus(unit.id);
    if (!status.canTakeSos) {
      await _firebaseSync.upsertUserAccount(
        userId: unit.id,
        role: 'responder',
        name: unit.callSign,
        isGuest: false,
        approvedByLgu: false,
        responseUnitStatus: status.wireName,
      );
      await _firebaseSync.upsertResponderAccount(
        userId: unit.id,
        callSign: unit.callSign,
        unitType: unit.type.name,
        approvedByLgu: false,
      );
      notifyListeners();
      return false;
    }
    await _firebaseSync.updateUnitLocation(unit);
    await _firebaseSync.upsertUserAccount(
      userId: unit.id,
      role: 'responder',
      name: unit.callSign,
      isGuest: false,
      approvedByLgu: true,
      responseUnitStatus: ResponseUnitStatus.inService.wireName,
    );
    await _firebaseSync.upsertResponderAccount(
      userId: unit.id,
      callSign: unit.callSign,
      unitType: unit.type.name,
      approvedByLgu: true,
    );
    notifyListeners();
    return true;
  }

  /// Updates a unit's operational status (e.g., AVAILABLE, EN ROUTE, ON SCENE).
  /// This change is pushed to Firebase so LGU and other clients see it.
  Future<void> updateUnitStatus(String unitId, UnitStatus status) async {
    if (_currentRole == UserRole.responder) {
      final lockOk = await ensureResponderSessionIsValid(unitId: unitId);
      if (!lockOk) {
        throw StateError('Session is active elsewhere. Please sign in again.');
      }
    }
    final unit = _resolveUnitForDispatch(unitId);
    if (unit == null) return;
    unit.status = status;
    await _firebaseSync.updateUnitLocation(unit, force: true);
    notifyListeners();
  }

  // --- Dynamic Relocation ---

  void _refreshRelocations() {
    _relocationSuggestions = _relocationService.suggestRelocations(
      allUnits: _rescueUnits,
      activeIncidents: _sosRequests,
      hazardZones: _hazardZones,
    );
  }

  // --- Seed demo data into Firebase ---

  Future<void> seedDemoData() async {
    // Keep demo seeding limited to hazard data.
    // Units should only appear in Firebase when a responder is actively online.
    final hazard = HazardZone(
      id: 'hz-1',
      name: 'Deparo Flood Zone',
      type: HazardType.flood,
      polygon: const [
        LatLng(14.7380, 121.0300),
        LatLng(14.7380, 121.0400),
        LatLng(14.7300, 121.0400),
        LatLng(14.7300, 121.0300),
      ],
      severityWeight: 50.0,
      reportedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
    await _firebaseSync.publishHazardZone(hazard);
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _stopResponderSessionHeartbeat();
    _locationService.dispose();
    _osrmService.dispose();
    stopFirebaseListeners();
    stopGpsUpload();
     _sosCleanupTimer?.cancel();
     _sosCleanupTimer = null;
    super.dispose();
  }
}
