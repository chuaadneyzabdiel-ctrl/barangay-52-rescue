import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/osrm_navigation_models.dart';
import '../models/rescue_models.dart';
import '../services/a_star_routing_service.dart';
import '../services/dynamic_relocation_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/location_service.dart';
import '../services/osrm_routing_service.dart';
import '../utils/geo_utils.dart';
import '../utils/route_geo_utils.dart';

const _kActiveSosId = 'active_sos_id';
const _kResponderNavSosId = 'responder_nav_sos_id';
const _kResponderNavUnitId = 'responder_nav_unit_id';
const _kPersistedRoleKey = 'persisted_user_role';
const _kResponderSessionUnitIdKey = 'responder_session_unit_id';
const _kGuestDeviceIdKey = 'guest_device_id';

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

  // GPS upload timer for responders
  Timer? _gpsUploadTimer;

  // Persisted active SOS (citizen) — restored when app reopens
  String? _activeSosId;

  // Persisted citizen profile (for naming SOS requests)
  String? _citizenName;
  String? _citizenId;
  CitizenAccessMode _citizenAccessMode = CitizenAccessMode.guest;
  String? _citizenEmail;
  String? _guestDeviceId;
  String? _citizenPhone;
  String? _citizenAddress;
  String? _citizenEmergencyContactName;
  String? _citizenEmergencyContactPhone;
  int _guestSosCountToday = 0;
  DateTime? _guestLastSosAt;
  DateTime? _guestCounterDate;
  int _guestStrikes = 0;
  bool _guestIsBanned = false;
  List<Map<String, dynamic>> _accountUsers = [];

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
  String? get guestDeviceId => _guestDeviceId;
  String? get citizenPhone => _citizenPhone;
  String? get citizenAddress => _citizenAddress;
  String? get citizenEmergencyContactName => _citizenEmergencyContactName;
  String? get citizenEmergencyContactPhone => _citizenEmergencyContactPhone;
  int get guestSosCountToday => _guestSosCountToday;
  DateTime? get guestLastSosAt => _guestLastSosAt;
  int get guestStrikes => _guestStrikes;
  bool get guestIsBanned => _guestIsBanned;
  bool get isCitizenGuest => _citizenAccessMode == CitizenAccessMode.guest;
  bool get isCitizenRegistered => _citizenAccessMode == CitizenAccessMode.registered;
  List<Map<String, dynamic>> get accountUsers => List.unmodifiable(_accountUsers);

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
  static final List<RescueUnit> _rescueUnitsRoster = [
    RescueUnit(
      id: 'unit-1',
      callSign: 'AMBULANCE-01',
      type: UnitType.ambulance,
      position: const LatLng(14.6544, 120.9840),
      stationId: 'station-south-1',
    ),
    RescueUnit(
      id: 'unit-2',
      callSign: 'FIRE-01',
      type: UnitType.fireTruck,
      position: const LatLng(14.7510, 121.0560),
      stationId: 'station-north-1',
    ),
    RescueUnit(
      id: 'unit-3',
      callSign: 'TANOD-01',
      type: UnitType.rescue,
      position: const LatLng(14.7350, 121.0350),
      stationId: 'station-north-2',
    ),
  ];

  /// When a responder selects a unit, we keep it so GPS upload can use it before Firebase stream delivers.
  RescueUnit? _currentResponderUnit;
  RescueUnit? get currentResponderUnit => _currentResponderUnit;
  void setCurrentResponderUnit(RescueUnit? unit) {
    _currentResponderUnit = unit;
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
  List<SOSRequest> get activeSosRequests =>
      _sosRequests.where((r) => r.isActive).toList();
  List<SOSRequest> get sosHistory => List.unmodifiable(_sosHistory);
  Map<String, StandbyPoint> get relocationSuggestions =>
      Map.unmodifiable(_relocationSuggestions);
  LocationService get locationService => _locationService;
  FirebaseSyncService get firebaseSync => _firebaseSync;
  List<SOSRequest> get pendingRequests =>
      _sosRequests.where((r) => r.status == SOSStatus.pending).toList();

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

  Future<void> clearPersistedSessionKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPersistedRoleKey);
      await prefs.remove(_kResponderSessionUnitIdKey);
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
      await prefs.remove(_kCitizenPhoneKey);
      await prefs.remove(_kCitizenAddressKey);
      await prefs.remove(_kCitizenEmergencyContactNameKey);
      await prefs.remove(_kCitizenEmergencyContactPhoneKey);
      await prefs.remove(_kGuestSosCountTodayKey);
      await prefs.remove(_kGuestLastSosAtKey);
      await prefs.remove(_kGuestCounterDateKey);
      await prefs.remove(_kGuestStrikesKey);
      await prefs.remove(_kGuestIsBannedKey);
      await prefs.remove(_kActiveSosId);
      await prefs.remove(_kGuestDeviceIdKey);
    } catch (_) {}
    _citizenName = null;
    _citizenId = null;
    _citizenAccessMode = CitizenAccessMode.guest;
    _citizenEmail = null;
    _guestDeviceId = null;
    _citizenPhone = null;
    _citizenAddress = null;
    _citizenEmergencyContactName = null;
    _citizenEmergencyContactPhone = null;
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
    // Preserve guest identity and anti-abuse counters across logout.
    if (_citizenAccessMode == CitizenAccessMode.registered) {
      await clearCitizenLocalPrefs();
      await clearResponderNavigation();
    } else {
      await clearActiveSOS();
      await clearResponderNavigation();
      _citizenAccessMode = CitizenAccessMode.guest;
    }
    _currentRole = UserRole.citizen;
    notifyListeners();
  }

  /// Ends responder session: offline unit, clear GPS upload, session keys.
  Future<void> responderLogout(String unitId) async {
    await goOffline(unitId);
    setCurrentResponderUnit(null);
    await clearPersistedSessionKeys();
    await clearResponderNavigation();
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
      (units) {
        _rescueUnits = units;
        _refreshRelocations();
        notifyListeners();
      },
      onError: (e, st) {
        _rescueUnits = [];
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
    _gpsUploadTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_currentPosition == null) return;
      RescueUnit? unit = knownUnit?.id == unitId ? knownUnit : _rescueUnits.where((u) => u.id == unitId).firstOrNull;
      if (unit == null) return;
      unit.position = _currentPosition!;
      _firebaseSync.updateUnitLocation(unit);
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
  static const _kCitizenPhoneKey = 'citizen_phone';
  static const _kCitizenAddressKey = 'citizen_address';
  static const _kCitizenEmergencyContactNameKey =
      'citizen_emergency_contact_name';
  static const _kCitizenEmergencyContactPhoneKey =
      'citizen_emergency_contact_phone';
  static const _kGuestSosCountTodayKey = 'guest_sos_count_today';
  static const _kGuestLastSosAtKey = 'guest_last_sos_at_ms';
  static const _kGuestCounterDateKey = 'guest_counter_date_yyyy_mm_dd';
  static const _kGuestStrikesKey = 'guest_strikes';
  static const _kGuestIsBannedKey = 'guest_is_banned';

  /// Loads citizen profile (name/id) from local storage.
  Future<void> loadCitizenProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _guestDeviceId = prefs.getString(_kGuestDeviceIdKey);
      if (_guestDeviceId == null || _guestDeviceId!.trim().isEmpty) {
        _guestDeviceId = 'gd-${DateTime.now().millisecondsSinceEpoch}';
        await prefs.setString(_kGuestDeviceIdKey, _guestDeviceId!);
      }
      _citizenName = prefs.getString(_kCitizenNameKey);
      _citizenId = prefs.getString(_kCitizenIdKey);
      final modeRaw = prefs.getString(_kCitizenModeKey);
      _citizenAccessMode = modeRaw == CitizenAccessMode.registered.name
          ? CitizenAccessMode.registered
          : CitizenAccessMode.guest;
      _citizenEmail = prefs.getString(_kCitizenEmailKey);
      _citizenPhone = prefs.getString(_kCitizenPhoneKey);
      _citizenAddress = prefs.getString(_kCitizenAddressKey);
      _citizenEmergencyContactName =
          prefs.getString(_kCitizenEmergencyContactNameKey);
      _citizenEmergencyContactPhone =
          prefs.getString(_kCitizenEmergencyContactPhoneKey);
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
      if (_citizenAccessMode == CitizenAccessMode.guest) {
        final stableGuestId = 'guest-${_guestDeviceId!}';
        if (_citizenId == null ||
            _citizenId!.trim().isEmpty ||
            !_citizenId!.startsWith('guest-')) {
          _citizenId = stableGuestId;
          await prefs.setString(_kCitizenIdKey, _citizenId!);
        }
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
    if (_citizenAccessMode == CitizenAccessMode.registered) {
      _citizenId ??= 'registered-${trimmed.hashCode}';
    } else {
      _guestDeviceId ??= 'gd-${DateTime.now().millisecondsSinceEpoch}';
      _citizenId = 'guest-${_guestDeviceId!}';
    }

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
    if (mode == CitizenAccessMode.guest) {
      _guestDeviceId ??= 'gd-${DateTime.now().millisecondsSinceEpoch}';
      _citizenId = 'guest-${_guestDeviceId!}';
    } else if (_citizenName != null && _citizenName!.isNotEmpty) {
      _citizenId = mode == CitizenAccessMode.registered
          ? 'registered-${_citizenName.hashCode}'
          : 'guest-${_citizenName.hashCode}';
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCitizenModeKey, mode.name);
      if (_guestDeviceId != null && _guestDeviceId!.trim().isNotEmpty) {
        await prefs.setString(_kGuestDeviceIdKey, _guestDeviceId!);
      }
      if (_citizenEmail != null && _citizenEmail!.trim().isNotEmpty) {
        await prefs.setString(_kCitizenEmailKey, _citizenEmail!.trim());
      } else {
        await prefs.remove(_kCitizenEmailKey);
      }
      if (mode == CitizenAccessMode.guest) {
        await prefs.remove(_kCitizenPhoneKey);
        await prefs.remove(_kCitizenAddressKey);
        await prefs.remove(_kCitizenEmergencyContactNameKey);
        await prefs.remove(_kCitizenEmergencyContactPhoneKey);
        _citizenPhone = null;
        _citizenAddress = null;
        _citizenEmergencyContactName = null;
        _citizenEmergencyContactPhone = null;
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

  /// Applies a registered citizen profile and persists it locally.
  Future<void> setCitizenProfileFromRegistered({
    required String uid,
    required String name,
    required String email,
    required String phone,
    required String address,
    String? emergencyContactName,
    String? emergencyContactPhone,
    bool syncRemote = true,
  }) async {
    _citizenAccessMode = CitizenAccessMode.registered;
    _citizenId = uid.trim();
    _citizenName = name.trim();
    _citizenEmail = email.trim();
    _citizenPhone = phone.trim();
    _citizenAddress = address.trim();
    _citizenEmergencyContactName = emergencyContactName?.trim().isEmpty == true
        ? null
        : emergencyContactName?.trim();
    _citizenEmergencyContactPhone =
        emergencyContactPhone?.trim().isEmpty == true
            ? null
            : emergencyContactPhone?.trim();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCitizenModeKey, CitizenAccessMode.registered.name);
      await prefs.setString(_kCitizenIdKey, _citizenId!);
      await prefs.setString(_kCitizenNameKey, _citizenName!);
      await prefs.setString(_kCitizenEmailKey, _citizenEmail!);
      await prefs.setString(_kCitizenPhoneKey, _citizenPhone!);
      await prefs.setString(_kCitizenAddressKey, _citizenAddress!);
      if (_citizenEmergencyContactName != null) {
        await prefs.setString(
          _kCitizenEmergencyContactNameKey,
          _citizenEmergencyContactName!,
        );
      } else {
        await prefs.remove(_kCitizenEmergencyContactNameKey);
      }
      if (_citizenEmergencyContactPhone != null) {
        await prefs.setString(
          _kCitizenEmergencyContactPhoneKey,
          _citizenEmergencyContactPhone!,
        );
      } else {
        await prefs.remove(_kCitizenEmergencyContactPhoneKey);
      }
    } catch (_) {}

    if (syncRemote) {
      await _firebaseSync.upsertCitizenProfile(
        userId: _citizenId!,
        name: _citizenName!,
        email: _citizenEmail!,
        phone: _citizenPhone!,
        address: _citizenAddress!,
        emergencyContactName: _citizenEmergencyContactName,
        emergencyContactPhone: _citizenEmergencyContactPhone,
      );
    }

    notifyListeners();
  }

  /// Loads registered citizen profile from RTDB by Firebase UID.
  Future<bool> loadRegisteredCitizenProfile(
    String uid, {
    String? fallbackEmail,
  }) async {
    final row = await _firebaseSync.getCitizenProfile(uid);
    if (row == null) return false;
    final name = (row['name']?.toString() ?? '').trim();
    final email = (row['email']?.toString() ?? fallbackEmail ?? '').trim();
    final phone = (row['phone']?.toString() ?? '').trim();
    final address = (row['address']?.toString() ?? '').trim();
    if (name.isEmpty || email.isEmpty) {
      return false;
    }
    await setCitizenProfileFromRegistered(
      uid: uid,
      name: name,
      email: email,
      phone: phone,
      address: address,
      emergencyContactName: row['emergencyContactName']?.toString(),
      emergencyContactPhone: row['emergencyContactPhone']?.toString(),
      syncRemote: false,
    );
    return true;
  }

  Future<bool> isResponderApproved(String responderId) async {
    final fromCache = _accountUsers
        .where((u) => (u['id']?.toString() ?? '') == responderId)
        .firstOrNull;
    if (fromCache != null) {
      return fromCache['approvedByLgu'] == true;
    }
    final remote = await _firebaseSync.getResponderApproval(responderId);
    return remote == true;
  }

  Future<void> setResponderApproval({
    required String responderId,
    required bool approved,
  }) async {
    await _firebaseSync.setResponderApproval(
      responderId: responderId,
      approved: approved,
    );
    _accountUsers = _accountUsers.map((u) {
      if ((u['id']?.toString() ?? '') != responderId) return u;
      final next = Map<String, dynamic>.from(u);
      next['approvedByLgu'] = approved;
      next['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      return next;
    }).toList();
    notifyListeners();
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
    final request = _sosRequests.where((r) => r.id == sosId).firstOrNull;
    if (request == null) return;
    if (request.assignedUnitId != unitId) return;

    await _firebaseSync.resolveSOS(request);

    final unit = _rescueUnits.where((u) => u.id == unitId).firstOrNull;
    if (unit != null) {
      unit.status = UnitStatus.idle;
      unit.assignedSOSId = null;
      await _firebaseSync.updateUnitLocation(unit);
    }
    if (_currentResponderUnit?.id == unitId) {
      _currentResponderUnit?.status = UnitStatus.idle;
      _currentResponderUnit?.assignedSOSId = null;
    }

    clearRoute();
    await clearResponderNavigationIfMatches(sosId);
    notifyListeners();
  }

  /// Call when rescuer arrives and victim is assisted: mark completed, move to history, remove from map.
  Future<void> completeSOS(SOSRequest request) async {
    // Compute evaluation metrics for this incident.
    final now = DateTime.now();
    double? unitDistanceKm;
    if (request.assignedUnitId != null) {
      final unit = _rescueUnits
          .where((u) => u.id == request.assignedUnitId)
          .firstOrNull;
      if (unit != null) {
        unitDistanceKm = GeoUtils.haversineKm(unit.position, request.location);
        unit.status = UnitStatus.idle;
        unit.assignedSOSId = null;
        await _firebaseSync.updateUnitLocation(unit);
      }
    }

    final responseTimeSeconds =
        now.difference(request.createdAt).inSeconds.clamp(0, 24 * 60 * 60);
    final relocationStrategy =
        _relocationStrategyBySosId.remove(request.id) ?? 'unknown';

    await _firebaseSync.completeSOS(
      request,
      extraMetrics: {
        'responseTimeSeconds': responseTimeSeconds,
        if (unitDistanceKm != null)
          'unitDistanceKmAtCompletion': unitDistanceKm,
        'relocationStrategy': relocationStrategy,
        'osrmDistanceKm': _osrmDistanceKm,
        'osrmEtaMinutes': _osrmEtaMinutes,
        'safeDistanceKm': _safeDistanceKm,
        'safeEtaMinutes': _safeEtaMinutes,
        'osrmHazardCrossings': _osrmHazardCrossings,
        'safeHazardCrossings': _safeHazardCrossings,
      },
    );

    clearRoute();
    await clearResponderNavigationIfMatches(request.id);
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
    LatLng? incidentLocation,
    bool locationIsPinned = false,
    String? reportedForName,
    String? callbackPhone,
    String? scenePhotoUrl,
  }) async {
    final loc = incidentLocation ?? _currentPosition;
    if (loc == null) {
      throw StateError(
        locationIsPinned
            ? 'Drop a pin on the map to set the incident location.'
            : 'Location not available. Cannot create SOS.',
      );
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

    final proxyName = reportedForName?.trim();
    final phone = callbackPhone?.trim();
    final request = SOSRequest(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      location: loc,
      citizenId: citizenId,
      citizenName: citizenName,
      message: message,
      priority: priority,
      sosType: sosType,
      createdAt: DateTime.now(),
      preferredFacilityId: preferredFacilityId,
      preferredFacilityName: preferredFacilityName,
      preferredFacilityLocation: preferredFacilityLocation,
      locationIsPinned: locationIsPinned,
      reportedForName: (proxyName != null && proxyName.isNotEmpty) ? proxyName : null,
      callbackPhone: (phone != null && phone.isNotEmpty) ? phone : null,
      scenePhotoUrl: (scenePhotoUrl != null && scenePhotoUrl.trim().isNotEmpty)
          ? scenePhotoUrl.trim()
          : null,
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
  /// When [pinLocation] is true, GPS still updates the reporter marker locally
  /// but must not move the incident pin in Firebase.
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

  Future<void> acceptDispatch({
    required String unitId,
    required String sosId,
  }) async {
    final unit = _rescueUnits.where((u) => u.id == unitId).firstOrNull;
    final sos = _sosRequests.where((r) => r.id == sosId).firstOrNull;

    if (unit == null) {
      throw StateError('Rescue unit "$unitId" not found. '
          'Firebase may not have loaded yet.');
    }
    if (sos == null) {
      throw StateError('SOS request "$sosId" not found.');
    }
    final approved = await isResponderApproved(unitId);
    if (!approved) {
      throw StateError('Responder is not approved by LGU yet.');
    }

    // Remember whether this dispatch used a relocation suggestion (for evaluation).
    final usedSuggestion = _relocationSuggestions.containsKey(unit.id);
    _relocationStrategyBySosId[sosId] =
        usedSuggestion ? 'suggested' : 'none';

    unit.status = UnitStatus.enRoute;
    unit.assignedSOSId = sosId;
    sos.status = SOSStatus.dispatched;
    sos.assignedUnitId = unitId;

    await _firebaseSync.acceptDispatch(sosId: sosId, unit: unit);
    await _firebaseSync.updateDispatchProgress(
      sosId,
      status: 'enRoute',
      phase: 'enRouteToPatient',
      routingTo: 'sos',
      destinationName: 'SOS location',
      destinationLocation: sos.location,
    );

    await computeRoute(from: unit.position, to: sos.location);
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
    final approved = await isResponderApproved(unit.id);
    if (!approved) {
      await _firebaseSync.upsertUserAccount(
        userId: unit.id,
        role: 'responder',
        name: unit.callSign,
        isGuest: false,
        approvedByLgu: false,
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
    final unit = _rescueUnits.where((u) => u.id == unitId).firstOrNull;
    if (unit == null) return;
    unit.status = status;
    await _firebaseSync.updateUnitLocation(unit);
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
    _locationService.dispose();
    _osrmService.dispose();
    stopFirebaseListeners();
    stopGpsUpload();
     _sosCleanupTimer?.cancel();
     _sosCleanupTimer = null;
    super.dispose();
  }
}
