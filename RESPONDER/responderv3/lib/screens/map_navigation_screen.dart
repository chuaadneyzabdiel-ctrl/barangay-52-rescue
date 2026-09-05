import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../map/barangay_coverage.dart';
import '../map/rescue_map_tiles.dart';
import '../models/map_layer_models.dart';
import '../models/rescue_models.dart';
import '../providers/map_theme_provider.dart';
import '../providers/rescue_provider.dart';
import '../services/map_layer_data_service.dart';
import '../services/navigation_eta_calculator.dart';
import '../utils/facility_search_utils.dart';
import '../utils/geo_utils.dart';
import '../utils/navigation_guidance.dart';
import '../utils/route_geo_utils.dart';
import '../widgets/chat_fab_with_badge.dart';
import '../widgets/lgu_responder_chat_panel.dart';
import '../widgets/map_layers_sheet.dart';
import '../widgets/sos_chat_panel.dart';
import 'session_bootstrap_screen.dart';

/// Full-screen navigation view used by Responders after accepting a dispatch.
///
/// Uses [FlutterMap] with OpenStreetMap tiles. Shows:
/// - Live responder position (streamed from GPS)
/// - Citizen SOS location (streamed from Firebase — moves if citizen moves)
/// - A* hazard-aware route (dashed orange)
/// - OSRM road-following route (solid blue)
/// - Hazard zone polygons
class MapNavigationScreen extends StatefulWidget {
  final SOSRequest sosRequest;
  final RescueUnit responderUnit;

  const MapNavigationScreen({
    super.key,
    required this.sosRequest,
    required this.responderUnit,
  });

  @override
  State<MapNavigationScreen> createState() => _MapNavigationScreenState();
}

class _MapNavigationScreenState extends State<MapNavigationScreen> {
  static const String _kResponderVoiceEnabledKey = 'responder_voice_enabled';
  final MapController _mapController = MapController();
  StreamSubscription? _citizenLocationSub;
  LatLng? _citizenLivePosition;
  bool _arrived = false;
  bool _sosEnded = false;
  String? _sosEndedReason; // 'cancelled' | 'completed'
  bool _cameraFollowsDriver = true;
  StreamSubscription<LatLng>? _driverPosSub;
  Timer? _rerouteDebounce;
  bool _isComputingRoute = false;
  LatLng? _lastRerouteDriverPos;
  LatLng? _lastRerouteTarget;
  DateTime? _lastRerouteComputedAt;
  LatLng? _lastCameraCenter;
  DateTime? _lastCameraMoveAt;

  /// Seconds with low/no GPS speed — drives stopped-time ETA creep.
  int _secondsStopped = 0;
  Timer? _etaTimer;
  StreamSubscription<bool>? _approvalSub;
  bool _revokedHandled = false;
  bool _chatSheetOpen = false;
  double _mapZoom = 14;
  double _mapRotationDeg = 0;
  final FlutterTts _tts = FlutterTts();
  String? _lastSpokenInstruction;
  int? _lastSpokenMeter;
  int _lastStraightBucket = -1;
  bool _arrivedVoiceSpoken = false;
  bool _voiceEnabled = true;
  bool _isCompleting = false;
  bool _isCancelling = false;
  List<MapLayerPOI> _medicalFacilities = const [];
  String _facilityTypeFilter = 'all';
  String _facilityOwnershipFilter = 'all';
  bool _facilityEmergencyOnly = false;
  MapLayerPOI? _selectedFacility;
  bool _routingToFacility = false;
  bool _pickupConfirmed = false;
  bool _atFacility = false;

  String _formatKmh(double? speedMps) {
    if (speedMps == null) return '—';
    final kmh = (speedMps * 3.6);
    if (kmh.isNaN || kmh.isInfinite) return '—';
    return kmh < 10 ? kmh.toStringAsFixed(1) : kmh.toStringAsFixed(0);
  }

  bool get _isAmbulance => widget.responderUnit.type == UnitType.ambulance;

  Future<void> _handleResponderActionError(Object error) async {
    if (!mounted) return;
    final msg = error.toString().replaceFirst('Bad state: ', '');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red,
      ),
    );
    final lower = msg.toLowerCase();
    final sessionInvalid = lower.contains('session is active elsewhere') ||
        lower.contains('please sign in again');
    if (!sessionInvalid) return;
    await context.read<RescueProvider>().clearPersistedSessionKeys();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const SessionBootstrapScreen()),
      (_) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadVoicePreference();
    _loadMedicalFacilities();
    _configureTts();
    _citizenLivePosition = widget.sosRequest.location;
    if (_isAmbulance &&
        widget.sosRequest.preferredFacilityLocation != null &&
        widget.sosRequest.preferredFacilityName != null) {
      _selectedFacility = MapLayerPOI(
        id: widget.sosRequest.preferredFacilityId ?? 'citizen-preferred-facility',
        name: widget.sosRequest.preferredFacilityName!,
        position: widget.sosRequest.preferredFacilityLocation!,
        layerType: MapLayerType.hospitals,
        subtitle: 'Citizen preferred destination',
        facilityType: 'hospital',
      );
    }
    _watchCitizenLocation();
    _watchDriverPositionForReroute();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<RescueProvider>();

      _approvalSub?.cancel();
      _approvalSub = provider.firebaseSync
          .watchResponderApproval(widget.responderUnit.id)
          .listen((approved) async {
        if (!approved && mounted && !_revokedHandled) {
          _revokedHandled = true;
          await provider.responderLogout(widget.responderUnit.id);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('LGU revoked this responder. You have been logged out.'),
              backgroundColor: Colors.orange,
            ),
          );
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(builder: (_) => const SessionBootstrapScreen()),
            (_) => false,
          );
        }
      });

      await provider.persistResponderNavigation(
        sosId: widget.sosRequest.id,
        unitId: widget.responderUnit.id,
      );
      // Ensure Firebase status is reset to EN ROUTE for this navigation run.
      // updateUnitStatus() only works if the unit is already loaded in provider.
      final unitId = widget.responderUnit.id;
      final unitInProvider = provider.rescueUnits.where((u) => u.id == unitId).firstOrNull;
      if (unitInProvider == null) {
        widget.responderUnit.status = UnitStatus.enRoute;
        widget.responderUnit.assignedSOSId = widget.sosRequest.id;
        widget.responderUnit.position = provider.currentPosition ?? widget.responderUnit.position;
        final ok = await provider.registerUnit(widget.responderUnit);
        if (!ok) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Responder account pending LGU approval.'),
                backgroundColor: Colors.orange,
              ),
            );
            Navigator.of(context).pop();
          }
          return;
        }
      } else {
        await provider.updateUnitStatus(unitId, UnitStatus.enRoute);
      }
      if (mounted) {
        _fitMapToRoute();
        await _syncDispatchProgress(provider);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _etaTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final provider = context.read<RescueProvider>();
        final spd = provider.currentSpeedMps ?? 0;
        _speakNavigationGuidance(provider);
        _syncDispatchProgress(provider);
        setState(() {
          if (spd >= NavigationEtaCalculator.movingThresholdMps) {
            _secondsStopped = 0;
          } else {
            _secondsStopped += 1;
          }
        });
      });
    });
  }

  /// Debounced, deviation-triggered rerouting. Does not run on a fixed interval.
  void _watchDriverPositionForReroute() {
    final provider = context.read<RescueProvider>();
    _driverPosSub?.cancel();
    _driverPosSub = provider.locationService.positionStream.listen((pos) {
      if (!mounted) return;
      if (_sosEnded) return;
      _checkArrival(pos);
      // Debounce frequent GPS updates so "Rerouting..." isn't spammy.
      _rerouteDebounce?.cancel();
      _rerouteDebounce = Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        _maybeReroute(pos);
      });
    });
  }

  Future<void> _maybeReroute(LatLng driverPos) async {
    if (!mounted || _arrived || _sosEnded) return;
    if (_isComputingRoute) return;
    final provider = context.read<RescueProvider>();
    final route = provider.osrmRoute;
    final target = _routingToFacility && _selectedFacility != null
        ? _selectedFacility!.position
        : (_citizenLivePosition ?? widget.sosRequest.location);

    // Hard throttle: don't recompute routes too frequently.
    final lastAt = _lastRerouteComputedAt;
    if (lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 6)) {
      return;
    }

    final distToTargetKm = GeoUtils.haversineKm(driverPos, target);

    // Deviation-based trigger: distance from driver to closest point in current OSRM route.
    double? minDistToRouteKm;
    if (route.length >= 2) {
      minDistToRouteKm = route
          .map((p) => GeoUtils.haversineKm(driverPos, p))
          .reduce((a, b) => a < b ? a : b);
    }

    // Movement-based trigger: avoids "stuck" due to GPS snapping to the same geometry.
    final movedKm = _lastRerouteDriverPos == null
        ? double.infinity
        : GeoUtils.haversineKm(_lastRerouteDriverPos!, driverPos);

    // Target-based trigger: if the SOS location moved far, reroute so the route end follows it.
    final targetMovedKm = _lastRerouteTarget == null
        ? double.infinity
        : GeoUtils.haversineKm(_lastRerouteTarget!, target);

    // Very close to target: only reroute on meaningful target movement (ignore jitter).
    if (distToTargetKm < 0.05 && targetMovedKm <= 0.03) return;

    final shouldReroute = route.length < 2 ||
        minDistToRouteKm == null ||
        minDistToRouteKm > 0.03 || // ~30m deviation
        movedKm > 0.03 || // moved more than ~30m since last reroute
        targetMovedKm > 0.03; // target moved more than ~30m

    if (!shouldReroute) return;

    setState(() => _isComputingRoute = true);
    _lastRerouteDriverPos = driverPos;
    _lastRerouteTarget = target;
    _lastRerouteComputedAt = DateTime.now();
    try {
      await provider.computeRoute(from: driverPos, to: target);
    } finally {
      if (mounted) setState(() => _isComputingRoute = false);
    }
  }

  /// GPS heading when moving; otherwise bearing along the OSRM polyline.
  double? _resolveBearingDeg(RescueProvider provider, LatLng? driverPos) {
    if (driverPos == null) return null;
    final spd = provider.currentSpeedMps ?? 0;
    final h = provider.locationService.lastHeadingDeg;
    if (h != null && spd > 0.5) {
      return h;
    }
    if (provider.osrmRoute.length >= 2) {
      return _routeArrowInfo(provider.osrmRoute, driverPos).bearingDeg;
    }
    return null;
  }

  /// Picks a point along [route] close to [driverPos] and returns:
  /// (index of closest point, bearing to next segment).
  ({int index, double bearingDeg}) _routeArrowInfo(
    List<LatLng> route,
    LatLng driverPos,
  ) {
    var bestIndex = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < route.length; i++) {
      final d = GeoUtils.haversineKm(driverPos, route[i]);
      if (d < bestDist) {
        bestDist = d;
        bestIndex = i;
      }
    }

    // Compute bearing along the route direction from the closest point.
    final nextIndex = (bestIndex + 1 < route.length) ? bestIndex + 1 : bestIndex;
    final bearingDeg = bestIndex < route.length - 1
        ? GeoUtils.bearing(route[bestIndex], route[nextIndex])
        : GeoUtils.bearing(route[bestIndex - 1], route[bestIndex]);
    return (index: bestIndex, bearingDeg: bearingDeg);
  }

  String _normalizeSearchToken(String value) {
    final lower = value.toLowerCase().trim();
    final withoutDash = lower.replaceAll('-', '');
    final withoutSpace = withoutDash.replaceAll(RegExp(r'\s+'), '');
    return withoutSpace
        .replaceAll('ñ', 'n')
        .replaceAll('–', '')
        .replaceAll('—', '');
  }

  bool _matchesFacilityQuery(MapLayerPOI poi, String qNorm) {
    if (qNorm.isEmpty) return true;
    final nameNorm = _normalizeSearchToken(poi.name);
    final subtitleNorm = _normalizeSearchToken(poi.subtitle ?? '');
    final typeNorm = _normalizeSearchToken(poi.facilityType ?? _facilityTypeOf(poi));
    final cityNorm = _normalizeSearchToken(poi.city ?? '');
    if (nameNorm.contains(qNorm) ||
        subtitleNorm.contains(qNorm) ||
        typeNorm.contains(qNorm) ||
        cityNorm.contains(qNorm)) {
      return true;
    }
    final isLyingIn = (poi.facilityType ?? _facilityTypeOf(poi)) == 'lying_in';
    final isObGyne = (poi.facilityType ?? _facilityTypeOf(poi)) == 'ob_gyne';
    if (isLyingIn &&
        (qNorm.contains('bahaypaanakan') ||
            qNorm.contains('paanakan') ||
            qNorm.contains('birthing'))) {
      return true;
    }
    if (isObGyne && (qNorm == 'obgyne' || qNorm == 'obgyn')) {
      return true;
    }
    return false;
  }

  List<({LatLng point, double bearingDeg})> _staticRouteArrowMarkers(
    List<LatLng> route,
  ) {
    if (route.length < 2) return const [];
    const everyKm = 0.18; // about every 180m
    final totalKm = RouteGeoUtils.polylineLengthKm(route);
    if (totalKm < everyKm) return const [];
    final out = <({LatLng point, double bearingDeg})>[];
    var nextMarkKm = everyKm;
    var acc = 0.0;
    for (var i = 0; i < route.length - 1 && nextMarkKm < totalKm; i++) {
      final a = route[i];
      final b = route[i + 1];
      final segKm = GeoUtils.haversineKm(a, b);
      if (segKm <= 1e-9) continue;
      while (nextMarkKm <= acc + segKm && nextMarkKm < totalKm) {
        final t = ((nextMarkKm - acc) / segKm).clamp(0.0, 1.0);
        out.add((
          point: LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          ),
          bearingDeg: GeoUtils.bearing(a, b),
        ));
        nextMarkKm += everyKm;
      }
      acc += segKm;
    }
    return out;
  }

  Future<void> _syncDispatchProgress(RescueProvider provider) async {
    final driver = provider.currentPosition;
    if (driver == null || _sosEnded) return;
    final target = _routingToFacility && _selectedFacility != null
        ? _selectedFacility!.position
        : (_citizenLivePosition ?? widget.sosRequest.location);
    final distanceMeters = (GeoUtils.haversineKm(driver, target) * 1000).round();
    final guidance = computeNavigationGuidance(
      steps: provider.navigationSteps,
      driver: driver,
      route: provider.osrmRoute,
    );
    final etaMinutes = provider.osrmEtaMinutes > 0 && provider.osrmRoute.length > 1
        ? NavigationEtaCalculator.computeLiveEtaMinutes(
            osrmRoute: provider.osrmRoute,
            trafficSegments: provider.routeTrafficSegments,
            osrmEtaMinutes: provider.osrmEtaMinutes,
            osrmDistanceKm: provider.osrmDistanceKm,
            driverPosition: driver,
            speedMps: provider.currentSpeedMps,
            secondsStopped: _secondsStopped.toDouble(),
          ).round().clamp(0, 9999)
        : null;
    final phase = _routingToFacility
        ? (_atFacility ? 'atFacility' : 'enRouteToFacility')
        : (_arrived ? 'onScene' : 'enRouteToPatient');
    final status = _sosEnded
        ? 'ended'
        : (_routingToFacility ? 'transporting' : (_arrived ? 'onScene' : 'enRoute'));
    await provider.firebaseSync.updateDispatchProgress(
      widget.sosRequest.id,
      status: status,
      phase: phase,
      etaMinutes: etaMinutes,
      distanceMeters: distanceMeters,
      nextInstruction: guidance?.nextInstruction,
      routingTo: _routingToFacility ? 'facility' : 'sos',
      destinationName: _routingToFacility
          ? (_selectedFacility?.name ?? 'Selected facility')
          : 'SOS location',
      destinationLocation: target,
    );
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.48);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(false);
  }

  Future<void> _loadVoicePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_kResponderVoiceEnabledKey);
      if (!mounted || value == null) return;
      setState(() => _voiceEnabled = value);
    } catch (_) {}
  }

  Future<void> _toggleVoiceEnabled() async {
    final next = !_voiceEnabled;
    setState(() => _voiceEnabled = next);
    if (!next) {
      await _tts.stop();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kResponderVoiceEnabledKey, next);
    } catch (_) {}
  }

  void _loadMedicalFacilities() {
    final rows = [
      ...MapLayerDataService.getLayerData(MapLayerType.hospitals),
      ...MapLayerDataService.getLayerData(MapLayerType.threeSCenters),
    ];
    _medicalFacilities = List<MapLayerPOI>.from(rows);
  }

  String _facilityTypeOf(MapLayerPOI poi) {
    if (poi.layerType == MapLayerType.threeSCenters) return '3s_center';
    final n = poi.name.toLowerCase();
    final s = (poi.subtitle ?? '').toLowerCase();
    if (n.contains('clinic') || s.contains('clinic')) return 'clinic';
    if (n.contains('health center') || s.contains('health center')) return 'health_center';
    return 'hospital';
  }

  List<MapLayerPOI> _filterFacilities(String query) {
    final qNorm = _normalizeSearchToken(query);
    final rows = _medicalFacilities.where((f) {
      final type = f.facilityType ?? _facilityTypeOf(f);
      final typeOk = _facilityTypeFilter == 'all' || type == _facilityTypeFilter;
      if (!typeOk) return false;
      final own = f.ownership ?? 'private';
      if (_facilityOwnershipFilter != 'all' && own != _facilityOwnershipFilter) {
        return false;
      }
      if (_facilityEmergencyOnly && f.emergencyCapable != true) return false;
      return _matchesFacilityQuery(f, qNorm);
    });
    return FacilitySearchUtils.sortedByDistance(
      widget.sosRequest.location,
      rows,
    );
  }

  List<MapLayerPOI> _hospitalCandidates() {
    final hospitals = MapLayerDataService.getLayerData(MapLayerType.hospitals);
    if (hospitals.isNotEmpty) return hospitals;
    return _medicalFacilities
        .where((f) => (f.facilityType ?? _facilityTypeOf(f)) == 'hospital')
        .toList();
  }

  Future<void> _suggestNearbyHospital() async {
    final scene = widget.sosRequest.location;
    final nearest = FacilitySearchUtils.nearestTo(scene, _hospitalCandidates());
    if (nearest == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hospitals found.')),
      );
      return;
    }
    final dist = FacilitySearchUtils.formatDistanceKm(
      GeoUtils.haversineKm(scene, nearest.position),
    );
    await _routeToFacility(nearest, announce: false);
    if (!mounted) return;
    final afterPickup = _isAmbulance && !_pickupConfirmed
        ? ' Route switches after pickup.'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Nearby: ${nearest.name} • $dist from scene.$afterPickup')),
    );
  }

  String _facilityOpenLabel(MapLayerPOI poi) {
    if ((poi.openStatusText ?? '').trim().isNotEmpty) return poi.openStatusText!.trim();
    if (poi.isOpenNow == true) return 'Open now';
    if (poi.isOpenNow == false) return 'Closed now';
    return 'Status unknown';
  }

  Future<void> _routeToFacility(MapLayerPOI facility, {bool announce = true}) async {
    setState(() {
      _selectedFacility = facility;
    });
    if (_isAmbulance && !_pickupConfirmed) {
      if (!mounted) return;
      if (announce) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Planned destination set: ${facility.name}. Route switches after pickup.',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    await _beginFacilityTransport(facility);
  }

  Future<void> _routeToNearestFacility() async {
    final provider = context.read<RescueProvider>();
    final from = provider.currentPosition ?? widget.responderUnit.position;
    if (_medicalFacilities.isEmpty) return;
    final rows = List<MapLayerPOI>.from(_medicalFacilities);
    rows.sort((a, b) =>
        GeoUtils.haversineKm(from, a.position).compareTo(GeoUtils.haversineKm(from, b.position)));
    final top = rows.take(8).toList();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: const Color(0xFF1B2838),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Nearby facilities',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final f in top)
                ListTile(
                  leading: const Icon(Icons.near_me, color: Colors.white70),
                  title: Text(f.name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    '${(GeoUtils.haversineKm(from, f.position) * 1000).round()} m • ${f.city ?? ''}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _routeToFacility(f);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _beginFacilityTransport(MapLayerPOI facility) async {
    final provider = context.read<RescueProvider>();
    final from = provider.currentPosition ?? widget.responderUnit.position;
    setState(() {
      _routingToFacility = true;
      _arrived = false;
      _atFacility = false;
      _arrivedVoiceSpoken = false;
      _lastSpokenInstruction = null;
      _lastSpokenMeter = null;
      _lastStraightBucket = -1;
    });
    await provider.computeRoute(from: from, to: facility.position);
    await _syncDispatchProgress(provider);
    if (!mounted) return;
    _fitMapToRoute();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Patient on board. Rerouting to ${facility.name}.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openFacilitySearchSheet() async {
    final controller = TextEditingController();
    String query = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B2838),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final rows = _filterFacilities(query);
            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Find hospital or clinic',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                    TextField(
                      controller: controller,
                      onChanged: (v) => setLocal(() => query = v),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search facility name...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.white10,
                        prefixIcon: const Icon(Icons.search, color: Colors.white70),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final f in const [
                          'all',
                          'hospital',
                          'clinic',
                          'health_center',
                          'ob_gyne',
                          'lying_in',
                          '3s_center'
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(
                                switch (f) {
                                  'all' => 'All',
                                  'hospital' => 'Hospitals',
                                  'clinic' => 'Clinics',
                                  'health_center' => 'Health Center',
                                  'ob_gyne' => 'OB-GYN',
                                  '3s_center' => '3S Centers',
                                  _ => 'Lying-in',
                                },
                              ),
                              selected: _facilityTypeFilter == f,
                              onSelected: (_) => setLocal(() => _facilityTypeFilter = f),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (final f in const ['all', 'public', 'private'])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(
                                switch (f) {
                                  'all' => 'Any ownership',
                                  'public' => 'Public',
                                  _ => 'Private',
                                },
                              ),
                              selected: _facilityOwnershipFilter == f,
                              onSelected: (_) =>
                                  setLocal(() => _facilityOwnershipFilter = f),
                            ),
                          ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _facilityEmergencyOnly,
                      onChanged: (v) => setLocal(() => _facilityEmergencyOnly = v),
                      title: const Text(
                        'Emergency-capable only',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 0,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _suggestNearbyHospital();
                          },
                          icon: const Icon(Icons.near_me, size: 18),
                          label: const Text('Suggest nearby'),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _routeToNearestFacility();
                          },
                          icon: const Icon(Icons.my_location, size: 18),
                          label: const Text('Nearest to me'),
                        ),
                        Text(
                          '${rows.length} result(s)',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 280,
                      child: ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final it = rows[i];
                          return ListTile(
                            leading: const Icon(Icons.local_hospital, color: Colors.redAccent),
                            title: Text(it.name, style: const TextStyle(color: Colors.white)),
                            subtitle: Text(
                              '${FacilitySearchUtils.formatDistanceKm(GeoUtils.haversineKm(widget.sosRequest.location, it.position))} from scene • ${it.city ?? ''} • ${it.facilityType ?? _facilityTypeOf(it)} • ${it.ownership ?? 'private'}\n'
                              '${_facilityOpenLabel(it)}${it.phone != null ? ' • ${it.phone}' : ''}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            isThreeLine: true,
                            onTap: () async {
                              Navigator.pop(ctx);
                              await _routeToFacility(it);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    controller.dispose();
  }

  Future<void> _openProblemReportDialog() async {
    if (_sosEnded) return;
    final controller = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark a problem'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Describe the problem (e.g. vehicle breakdown, blocked road)...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Send to LGU'),
          ),
        ],
      ),
    );
    final trimmed = msg?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    await context
        .read<RescueProvider>()
        .firebaseSync
        .reportResponderProblem(widget.sosRequest.id, trimmed);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Problem marked and sent to LGU.')),
    );
  }

  Future<void> _speakNavigationGuidance(RescueProvider provider) async {
    if (!_voiceEnabled) return;
    final pos = provider.currentPosition;
    final route = provider.osrmRoute;
    if (pos == null || route.length < 2) return;

    final navTarget = _routingToFacility && _selectedFacility != null
        ? _selectedFacility!.position
        : widget.sosRequest.location;
    final distToSosM = (GeoUtils.haversineKm(pos, navTarget) * 1000).round();
    if (distToSosM <= 10) {
      if (!_arrivedVoiceSpoken) {
        _arrivedVoiceSpoken = true;
        await _tts.speak('Arrived at the SOS location.');
      }
      return;
    }

    final guidance = computeNavigationGuidance(
      driver: pos,
      route: route,
      steps: provider.navigationSteps,
    );
    if (guidance == null) return;

    final instruction = guidance.nextInstruction.trim();
    final meterToTurn =
        (guidance.distanceToNextManeuverKm * 1000).round().clamp(0, 200000);

    if (_lastSpokenInstruction != instruction) {
      _lastSpokenInstruction = instruction;
      _lastSpokenMeter = meterToTurn;
      _lastStraightBucket = -1;
      await _tts.speak('In $meterToTurn meters, $instruction');
      return;
    }

    if (meterToTurn <= 10 && meterToTurn >= 1 && _lastSpokenMeter != meterToTurn) {
      _lastSpokenMeter = meterToTurn;
      await _tts.speak('$meterToTurn meters, $instruction');
      return;
    }

    final lower = instruction.toLowerCase();
    if (lower.startsWith('continue') && meterToTurn > 10) {
      final bucket = meterToTurn ~/ 30;
      if (bucket != _lastStraightBucket && bucket >= 1) {
        _lastStraightBucket = bucket;
        await _tts.speak('Continue straight. $meterToTurn meters remaining.');
      }
    }
  }

  void _fitMapToRoute() {
    final provider = context.read<RescueProvider>();
    final driverPos = provider.currentPosition;
    final points = <LatLng>[
      widget.sosRequest.location,
      if (_citizenLivePosition != null) _citizenLivePosition!,
      if (_selectedFacility != null) _selectedFacility!.position,
      if (driverPos != null) driverPos,
      ...provider.osrmRoute,
    ];
    if (points.length < 2) return;
    try {
      final bounds = LatLngBounds.fromPoints(points);
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(80)),
      );
    } catch (_) {}
  }

  void _watchCitizenLocation() {
    final provider = context.read<RescueProvider>();
    _citizenLocationSub = provider.firebaseSync
        .watchSOS(widget.sosRequest.id)
        .listen((sos) {
      if (!mounted) return;
      if (sos == null ||
          sos.status == SOSStatus.cancelled ||
          sos.status == SOSStatus.completed ||
          sos.completedAt != null) {
        _rerouteDebounce?.cancel();
        unawaited(context
            .read<RescueProvider>()
            .clearResponderNavigationIfMatches(widget.sosRequest.id));
        setState(() {
          _sosEnded = true;
          _sosEndedReason = sos?.status == SOSStatus.cancelled ? 'cancelled' : 'completed';
        });
        return;
      }
      setState(() {
        _citizenLivePosition = sos.location;
      });
    });
  }

  void _checkArrival(LatLng driverPos) {
    final target = _routingToFacility
        ? _selectedFacility?.position
        : _citizenLivePosition;
    if (target == null) return;
    final dist = GeoUtils.haversineKm(driverPos, target);
    // Auto-arrive when within ~30 meters of the latest target.
    if (dist < 0.03 && !_arrived) {
      setState(() {
        _arrived = true;
        if (_routingToFacility) _atFacility = true;
      });
      if (!_routingToFacility) {
        unawaited(context
            .read<RescueProvider>()
            .updateUnitStatus(widget.responderUnit.id, UnitStatus.onScene));
      }
      unawaited(_syncDispatchProgress(context.read<RescueProvider>()));
    }
  }

  Future<void> _markArrivedManually() async {
    if (_sosEnded) return;
    final target = _routingToFacility
        ? (_selectedFacility?.position ?? widget.sosRequest.location)
        : (_citizenLivePosition ?? widget.sosRequest.location);
    final driver = context.read<RescueProvider>().currentPosition;
    if (driver != null) {
      final dKm = GeoUtils.haversineKm(driver, target);
      if (dKm > 0.2) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Far from SOS?'),
            content: Text(
              'You are about ${(dKm * 1000).round()} m from the SOS pin. '
              'Only tap Arrive when you are actually on scene.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not yet'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Arrive anyway'),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }
    }
    if (!mounted) return;
    if (_isAmbulance && !_pickupConfirmed) {
      if (_selectedFacility == null) {
        await _openFacilitySearchSheet();
        if (_selectedFacility == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Select destination clinic/hospital before pickup.'),
            ),
          );
          return;
        }
      }
      setState(() {
        _pickupConfirmed = true;
        _arrived = false;
        _citizenLivePosition = null;
      });
      final provider = context.read<RescueProvider>();
      await provider.updateUnitStatus(widget.responderUnit.id, UnitStatus.onScene);
      // Push dispatch phase immediately so citizen view switches to facility mode
      // even before route computation completes.
      await _syncDispatchProgress(provider);
      await _beginFacilityTransport(_selectedFacility!);
      return;
    }

    setState(() {
      _arrived = true;
      if (_routingToFacility) _atFacility = true;
    });
    if (!_routingToFacility) {
      await context
          .read<RescueProvider>()
          .updateUnitStatus(widget.responderUnit.id, UnitStatus.onScene);
    }
    await _syncDispatchProgress(context.read<RescueProvider>());
  }

  Future<void> _confirmCancelResponse() async {
    if (_isCancelling) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this response?'),
        content: const Text(
          'This cancels the SOS for the citizen and returns your unit to available. '
          'Only use if you cannot continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade800,
            ),
            child: const Text('Cancel response'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _isCancelling = true);
    try {
      await context.read<RescueProvider>().responderAbortSOS(
            sosId: widget.sosRequest.id,
            unitId: widget.responderUnit.id,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      await _handleResponderActionError(e);
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  LatLng _midpointOf(List<LatLng> pts) {
    if (pts.isEmpty) return widget.sosRequest.location;
    return pts[pts.length ~/ 2];
  }

  @override
  void dispose() {
    _etaTimer?.cancel();
    _rerouteDebounce?.cancel();
    _driverPosSub?.cancel();
    _citizenLocationSub?.cancel();
    _approvalSub?.cancel();
    _tts.stop();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _confirmLeaveNavigation() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave navigation map?'),
        content: const Text(
          'Your unit stays EN ROUTE and GPS keeps updating. Open this response again from the dispatch screen when you return. Use Complete SOS when the rescue is finished.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave map'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmLeaveNavigation();
      },
      child: Scaffold(
        body: Stack(
        children: [
          Consumer<MapThemeProvider>(
            builder: (context, mapTheme, _) {
              return Consumer<RescueProvider>(
                builder: (context, provider, _) {
              final driverPos = provider.currentPosition;

              // Smooth-follow throttle: only move camera if user hasn't panned
              // and responder moved enough since last camera move.
              if (driverPos != null &&
                  _cameraFollowsDriver &&
                  !_sosEnded &&
                  (_lastCameraCenter == null ||
                      GeoUtils.haversineKm(_lastCameraCenter!, driverPos) > 0.003) &&
                  (_lastCameraMoveAt == null ||
                      DateTime.now().difference(_lastCameraMoveAt!) >
                          const Duration(milliseconds: 250))) {
                _lastCameraCenter = driverPos;
                _lastCameraMoveAt = DateTime.now();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _cameraFollowsDriver && !_sosEnded) {
                    final bearing = _resolveBearingDeg(provider, driverPos);
                    final rotation = bearing == null ? _mapRotationDeg : -bearing;
                    _mapRotationDeg = rotation;
                    _mapController.moveAndRotate(
                      driverPos,
                      _mapController.camera.zoom,
                      rotation,
                    );
                  }
                });
              }

              return FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: widget.sosRequest.location,
                  initialZoom: 14,
                  interactionOptions: kRescueMapInteractions,
                  keepAlive: true,
                  onPositionChanged: (MapCamera camera, bool hasGesture) {
                    if (!mounted) return;
                    final z = camera.zoom;
                    if (hasGesture) {
                      setState(() {
                        _mapZoom = z;
                        _cameraFollowsDriver = false;
                      });
                    } else if ((z - _mapZoom).abs() > 0.08) {
                      setState(() => _mapZoom = z);
                    }
                  },
                ),
                children: [
                  mapTheme.buildTileLayer(),
                  ...BarangayCoverage.mapLayers(),

                  // Hazard zone polygons
                  PolygonLayer(
                    polygons: provider.hazardZones
                        .where((h) => h.isActive)
                        .map((h) => Polygon(
                              points: h.polygon,
                              color: _hazardColor(h.type).withValues(alpha: 0.25),
                              borderColor: _hazardColor(h.type),
                              borderStrokeWidth: 2,
                            ))
                        .toList(),
                  ),

                  if (!_arrived && !_sosEnded) ...[
                    // Road route: mock traffic colors (clear=blue, heavy=red) or solid blue.
                    if (provider.osrmRoute.length >= 2) ...[
                      // Keep a continuous base line to avoid visual breaks between traffic segments.
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: provider.osrmRoute,
                            color: const Color(0xFF1565C0),
                            strokeWidth: 8,
                          ),
                        ],
                      ),
                      if (mapTheme.showRouteTrafficOverlay &&
                          provider.routeTrafficSegments.isNotEmpty)
                        for (final seg in provider.routeTrafficSegments)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: seg.points,
                                color: Colors.black.withValues(alpha: 0.55),
                                strokeWidth: 11,
                              ),
                              Polyline(
                                points: seg.points,
                                color: _trafficSegmentColor(seg.level),
                                strokeWidth: 8,
                              ),
                            ],
                          )
                      else
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: provider.osrmRoute,
                              color: const Color(0xFF1565C0),
                              strokeWidth: 10,
                            ),
                          ],
                        ),
                    ],
                  ],

                  if (!_arrived && !_sosEnded && provider.osrmRoute.length >= 2)
                    Builder(
                      builder: (_) {
                        final arrows = _staticRouteArrowMarkers(provider.osrmRoute);
                        if (arrows.isEmpty) return const SizedBox.shrink();
                        return MarkerLayer(
                          markers: [
                            for (final arrow in arrows)
                              Marker(
                                point: arrow.point,
                                width: 16,
                                height: 16,
                                child: IgnorePointer(
                                  child: Transform.rotate(
                                    // `arrow_forward_rounded` points to the right (east) at 0 rad.
                                    // Route bearings are 0=north, so subtract 90deg to align.
                                    angle: (arrow.bearingDeg - 90.0) * 3.14159265 / 180.0,
                                    child: Icon(
                                      Icons.arrow_forward_rounded,
                                      size: 14,
                                      color: _uiPrimaryColor(mapTheme.style)
                                          .withValues(alpha: _isComputingRoute ? 0.55 : 0.9),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),

                  // Simulated congestion markers (visible when zoomed in; not live traffic).
                  if (!_arrived &&
                      !_sosEnded &&
                      mapTheme.showRouteTrafficOverlay &&
                      _mapZoom >= 14)
                    MarkerLayer(
                      markers: [
                        for (final seg in provider.routeTrafficSegments)
                          if (seg.level == TrafficLevel.heavy &&
                              seg.points.length >= 2)
                            Marker(
                              point: _midpointOf(seg.points),
                              width: 32,
                              height: 32,
                              child: Tooltip(
                                message:
                                    'Simulated heavy delay on this part of the route (not live traffic)',
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade800,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.red.withValues(alpha: 0.5),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.traffic,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),

                  // Markers
                  MarkerLayer(
                    markers: [
                      // Responder live position
                      if (driverPos != null)
                        Marker(
                          point: driverPos,
                          width: 50,
                          height: 50,
                          child: _ResponderMarkerIcon(
                            type: widget.responderUnit.type,
                            bearingDeg: _resolveBearingDeg(provider, driverPos),
                          ),
                        ),

                      // Citizen SOS position (live from Firebase)
                      if (_citizenLivePosition != null)
                        Marker(
                          point: _citizenLivePosition!,
                          width: 50,
                          height: 50,
                          child: const _SOSMarkerIcon(),
                        ),
                      if (_selectedFacility != null && _routingToFacility)
                        Marker(
                          point: _selectedFacility!.position,
                          width: 44,
                          height: 44,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.red.shade700,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.red.withValues(alpha: 0.45),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.local_hospital,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
          _buildTopBar(),
          if (_arrived && (!_isAmbulance || _atFacility)) _buildArrivalBanner(),
          if (_sosEnded) _buildSOSEndedBanner(),
          if (_isComputingRoute)
            Positioned(
              top: MediaQuery.of(context).padding.top + 140,
              left: 16,
              right: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Rerouting...',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + ((_arrived || _sosEnded) ? 100 : 28),
            left: 16,
            child: Consumer<RescueProvider>(
              builder: (context, provider, _) {
                final keepPickupActionVisible =
                    _isAmbulance && !_pickupConfirmed && _arrived && !_routingToFacility;
                if (_sosEnded || (_arrived && !keepPickupActionVisible)) {
                  return const SizedBox.shrink();
                }
                final target = _routingToFacility && _selectedFacility != null
                    ? _selectedFacility!.position
                    : (_citizenLivePosition ?? widget.sosRequest.location);
                final driverPos = provider.currentPosition;
                final distKm = driverPos != null
                    ? GeoUtils.haversineKm(driverPos, target)
                    : double.infinity;
                final isAmbulancePickupStep = _isAmbulance && !_pickupConfirmed;
                final pickupReady = isAmbulancePickupStep && distKm <= 0.02; // 20m
                final arriveReady = !isAmbulancePickupStep && distKm <= 0.03;
                final showArrive = pickupReady || arriveReady;
                final glow = showArrive;

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: glow
                        ? [
                            BoxShadow(
                              color: Colors.lightGreenAccent.withValues(alpha: 0.85),
                              blurRadius: 20,
                              spreadRadius: 1,
                            ),
                            BoxShadow(
                              color: Colors.green.withValues(alpha: 0.5),
                              blurRadius: 12,
                            ),
                          ]
                        : null,
                  ),
                  child: FloatingActionButton.extended(
                    heroTag: 'arrive-or-cancel',
                    onPressed: showArrive
                        ? _markArrivedManually
                        : (_isCancelling ? null : _confirmCancelResponse),
                    backgroundColor:
                        showArrive ? Colors.green.shade500 : Colors.red.shade600,
                    icon: Icon(
                      showArrive
                          ? (isAmbulancePickupStep ? Icons.personal_injury : Icons.flag)
                          : Icons.cancel,
                      color: Colors.white,
                    ),
                    label: Text(
                      showArrive
                          ? (isAmbulancePickupStep
                              ? 'Pickup Patient'
                              : (_routingToFacility ? 'Arrive Facility' : 'Arrive'))
                          : (_routingToFacility ? 'Cancel Hospital Route' : 'Cancel'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 220,
            bottom: MediaQuery.of(context).padding.bottom + 20,
            right: 16,
            child: Consumer<MapThemeProvider>(
              builder: (context, mapTheme, _) {
                final primary = _uiPrimaryColor(mapTheme.style);
                final shadow = _uiShadowColor(mapTheme.style);
                return SizedBox(
                  width: 56,
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            if (!_arrived && !_sosEnded) ...[
                              _transparentMapControl(
                                icon: Icons.layers_outlined,
                                color: primary,
                                shadowColor: shadow,
                                onTap: () => showMapLayersSheet(context),
                              ),
                              const SizedBox(height: 12),
                            ],
                            _transparentMapControl(
                              icon: Icons.zoom_out_map,
                              color: primary,
                              shadowColor: shadow,
                              onTap: _fitMapToRoute,
                            ),
                            const SizedBox(height: 12),
                            if (!_sosEnded) ...[
                              _transparentMapControl(
                                icon: Icons.search,
                                color: primary,
                                shadowColor: shadow,
                                onTap: _openFacilitySearchSheet,
                              ),
                              const SizedBox(height: 12),
                              if (_selectedFacility != null) ...[
                                _transparentMapControl(
                                  icon: Icons.swap_horiz,
                                  color: primary,
                                  shadowColor: shadow,
                                  onTap: _openFacilitySearchSheet,
                                ),
                                const SizedBox(height: 12),
                              ],
                            ],
                            if (!_sosEnded) ...[
                              _transparentMapControl(
                                icon: Icons.report_problem_outlined,
                                color: primary,
                                shadowColor: shadow,
                                onTap: _openProblemReportDialog,
                              ),
                              const SizedBox(height: 12),
                            ],
                            _transparentMapControl(
                              icon: _voiceEnabled ? Icons.volume_up : Icons.volume_off,
                              color: primary,
                              shadowColor: shadow,
                              onTap: _toggleVoiceEnabled,
                            ),
                            const SizedBox(height: 12),
                            ChatFabWithBadge(
                      sosId: widget.sosRequest.id,
                      myRole: 'responder',
                      suppressNotifications: _chatSheetOpen,
                      onPressed: () {
                        setState(() => _chatSheetOpen = true);
                        showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: const Color(0xFF1B2838),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                                top: Radius.circular(16)),
                          ),
                          builder: (_) => DraggableScrollableSheet(
                            initialChildSize: 0.6,
                            minChildSize: 0.3,
                            maxChildSize: 0.95,
                            expand: false,
                            builder: (_, __) => Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    'Message citizen',
                                    style: TextStyle(
                                      color: Colors.grey[300],
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SOSChatPanel(
                                    sosId: widget.sosRequest.id,
                                    senderRole: 'responder',
                                    senderId: widget.responderUnit.id,
                                    senderDisplayName:
                                        widget.responderUnit.callSign,
                                    completedAt: widget.sosRequest.completedAt,
                                    otherPartyPhoneNumber:
                                        widget.sosRequest.callbackPhone,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ).whenComplete(() {
                          if (mounted) setState(() => _chatSheetOpen = false);
                        });
                      },
                            ),
                            const SizedBox(height: 12),
                            _transparentMapControl(
                              icon: Icons.support_agent_outlined,
                              color: primary,
                              shadowColor: shadow,
                              onTap: () {
                                showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  backgroundColor: const Color(0xFF1B2838),
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(16),
                                    ),
                                  ),
                                  builder: (_) => DraggableScrollableSheet(
                                    initialChildSize: 0.6,
                                    minChildSize: 0.3,
                                    maxChildSize: 0.95,
                                    expand: false,
                                    builder: (_, __) => Column(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Text(
                                            'Message LGU',
                                            style: TextStyle(
                                              color: Colors.grey[300],
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: LguResponderChatPanel(
                                            sosId: widget.sosRequest.id,
                                            senderRole: 'responder',
                                            senderId: widget.responderUnit.id,
                                            senderDisplayName:
                                                widget.responderUnit.callSign,
                                            completedAt:
                                                widget.sosRequest.completedAt,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 12),
                            _transparentMapControl(
                              icon: Icons.my_location,
                              color: primary,
                              shadowColor: shadow,
                              onTap: _recenterMap,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        ),
      ),
    );
  }

  void _recenterMap() {
    final pos = context.read<RescueProvider>().currentPosition;
    if (pos != null) {
      setState(() => _cameraFollowsDriver = true);
      final bearing = _resolveBearingDeg(context.read<RescueProvider>(), pos);
      final rotation = bearing == null ? _mapRotationDeg : -bearing;
      _mapRotationDeg = rotation;
      _mapController.moveAndRotate(pos, _mapController.camera.zoom, rotation);
    }
  }

  String _formatRemDistance(double remKm) {
    if (remKm <= 0) return '—';
    if (remKm < 1) return '${(remKm * 1000).round()} m';
    return '${remKm.toStringAsFixed(2)} km';
  }

  bool _isDarkMapStyle(RescueMapStyle style) {
    return style == RescueMapStyle.dark || style == RescueMapStyle.satellite;
  }

  Color _uiPrimaryColor(RescueMapStyle style) {
    return _isDarkMapStyle(style) ? Colors.white : const Color(0xFF0D243A);
  }

  Color _uiShadowColor(RescueMapStyle style) {
    return _isDarkMapStyle(style)
        ? Colors.black.withValues(alpha: 0.9)
        : Colors.white.withValues(alpha: 0.95);
  }

  Widget _outlinedMapIcon({
    required IconData icon,
    required Color color,
    required Color shadowColor,
    double size = 27,
  }) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.translate(
            offset: const Offset(0.8, 0.8),
            child: Icon(icon, color: shadowColor, size: size),
          ),
          Icon(icon, color: color, size: size),
        ],
      ),
    );
  }

  Widget _transparentMapControl({
    required IconData icon,
    required Color color,
    required Color shadowColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.38),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Center(
            child: _outlinedMapIcon(
              icon: icon,
              color: color,
              shadowColor: shadowColor,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: Consumer2<RescueProvider, MapThemeProvider>(
        builder: (context, provider, mapTheme, _) {
          final primary = _uiPrimaryColor(mapTheme.style);
          final shadow = _uiShadowColor(mapTheme.style);
          final isDark = _isDarkMapStyle(mapTheme.style);
          final cardColor = const Color(0xFF1B3A5C).withValues(
            alpha: isDark ? 0.92 : 0.95,
          );
          final cardPrimary = Colors.white;
          final cardSecondary = Colors.white70;
          final driverPos = provider.currentPosition;
          double liveEta = provider.osrmEtaMinutes;
          if (driverPos != null &&
              provider.osrmRoute.length >= 2 &&
              provider.osrmDistanceKm > 0) {
            liveEta = NavigationEtaCalculator.computeLiveEtaMinutes(
              osrmRoute: provider.osrmRoute,
              trafficSegments: provider.routeTrafficSegments,
              osrmEtaMinutes: provider.osrmEtaMinutes,
              osrmDistanceKm: provider.osrmDistanceKm,
              driverPosition: driverPos,
              speedMps: provider.currentSpeedMps,
              secondsStopped: _secondsStopped.toDouble(),
            );
          }
          final eta = liveEta > 0 ? liveEta.toStringAsFixed(1) : '—';
          final remKm = driverPos != null && provider.osrmRoute.length >= 2
              ? RouteGeoUtils.remainingDistanceKm(driverPos, provider.osrmRoute)
              : provider.osrmDistanceKm;
          final dist = _formatRemDistance(remKm);
          final navTarget = _routingToFacility && _selectedFacility != null
              ? _selectedFacility!.position
              : (_citizenLivePosition ?? widget.sosRequest.location);
          final distToSosM = driverPos != null
              ? (GeoUtils.haversineKm(driverPos, navTarget) * 1000).round()
              : 999999;
          final arrivedByDistance = distToSosM <= 10;
          final guidance = driverPos != null &&
                  provider.navigationSteps.isNotEmpty &&
                  provider.osrmRoute.length >= 2
              ? computeNavigationGuidance(
                  driver: driverPos,
                  route: provider.osrmRoute,
                  steps: provider.navigationSteps,
                )
              : null;
          final spd = provider.currentSpeedMps ?? 0;
          final stoppedHint = spd < NavigationEtaCalculator.movingThresholdMps &&
                  _secondsStopped > NavigationEtaCalculator.stoppedGraceSeconds
              ? ' • Stopped (ETA adjusts)'
              : '';

          return Card(
            elevation: 6,
            color: cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _transparentMapControl(
                    icon: Icons.arrow_back,
                    color: primary,
                    shadowColor: shadow,
                    onTap: _confirmLeaveNavigation,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _routingToFacility && _selectedFacility != null
                              ? 'ETA: $eta min  •  to ${_selectedFacility!.name}$stoppedHint'
                              : 'ETA: $eta min  •  left $dist$stoppedHint',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cardPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: 0.55),
                                blurRadius: 3,
                                offset: const Offset(0.6, 0.6),
                              ),
                            ],
                          ),
                        ),
                        if (_isAmbulance && !_sosEnded)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 0,
                              children: [
                                TextButton.icon(
                                  onPressed: _suggestNearbyHospital,
                                  icon: const Icon(Icons.near_me, size: 16),
                                  label: const Text('Suggest nearby'),
                                ),
                                TextButton.icon(
                                  onPressed: _openFacilitySearchSheet,
                                  icon: const Icon(Icons.search, size: 16),
                                  label: const Text('Choose'),
                                ),
                              ],
                            ),
                          ),
                        if (_isAmbulance &&
                            !_routingToFacility &&
                            _selectedFacility != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Next after pickup: ${_selectedFacility!.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cardSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    blurRadius: 2,
                                    offset: const Offset(0.5, 0.5),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_selectedFacility != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              '${_facilityOpenLabel(_selectedFacility!)}${_selectedFacility!.phone != null ? ' • ${_selectedFacility!.phone}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cardSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    blurRadius: 2,
                                    offset: const Offset(0.5, 0.5),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (arrivedByDistance || guidance != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              arrivedByDistance
                                  ? 'Arrived at the location'
                                  : '${guidance!.distanceToNextLabel}: ${guidance.nextInstruction}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cardPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    blurRadius: 3,
                                    offset: const Offset(0.8, 0.8),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _routingToFacility && _selectedFacility != null
                                ? 'Facility pin: ${navTarget.latitude.toStringAsFixed(6)}, ${navTarget.longitude.toStringAsFixed(6)}'
                                : 'SOS pin: ${navTarget.latitude.toStringAsFixed(6)}, ${navTarget.longitude.toStringAsFixed(6)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cardSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  blurRadius: 2,
                                  offset: const Offset(0.5, 0.5),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                            color: isDark
                          ? Colors.white.withValues(alpha: 0.12)
                          : Colors.black.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed, color: cardPrimary, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          '${_formatKmh(provider.currentSpeedMps)} km/h',
                          style: TextStyle(
                            color: cardPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSOSEndedBanner() {
    final isCancelled = _sosEndedReason == 'cancelled';
    return Positioned(
      bottom: 32,
      left: 24,
      right: 24,
      child: Card(
        color: isCancelled ? Colors.orange.shade800 : Colors.green.shade700,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    isCancelled ? Icons.cancel : Icons.check_circle,
                    color: Colors.white,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isCancelled
                          ? 'This SOS was cancelled by the citizen.'
                          : 'This response is complete.',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, size: 20),
                  label: const Text('Back to dispatch'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: isCancelled ? Colors.orange.shade900 : Colors.green.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArrivalBanner() {
    return Positioned(
      bottom: 32,
      left: 24,
      right: 24,
      child: Card(
        color: Colors.green,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Arrived — victim assisted? Mark as Completed to remove from map.',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              ElevatedButton(
                onPressed: _isCompleting
                    ? null
                    : () async {
                        setState(() => _isCompleting = true);
                        try {
                          await context
                              .read<RescueProvider>()
                              .firebaseSync
                              .updateDispatchProgress(
                                widget.sosRequest.id,
                                status: 'completed',
                                phase: 'completed',
                              );
                          await context
                              .read<RescueProvider>()
                              .completeSOS(widget.sosRequest);
                          if (context.mounted) Navigator.pop(context, true);
                        } catch (e) {
                          await _handleResponderActionError(e);
                        } finally {
                          if (mounted) setState(() => _isCompleting = false);
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.green,
                ),
                child: const Text('Complete SOS'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _hazardColor(HazardType type) {
    return switch (type) {
      HazardType.flood => Colors.blue,
      HazardType.fire => Colors.red,
      HazardType.structuralCollapse => Colors.brown,
      HazardType.roadBlock => Colors.orange,
      HazardType.chemicalSpill => Colors.purple,
      HazardType.other => Colors.grey,
    };
  }

  Color _trafficSegmentColor(TrafficLevel level) {
    return switch (level) {
      TrafficLevel.clear => const Color(0xFF2EAD63),
      TrafficLevel.moderate => const Color(0xFFF9A825),
      TrafficLevel.heavy => const Color(0xFFD8433E),
    };
  }
}

// --- Custom marker widgets ---

class _ResponderMarkerIcon extends StatelessWidget {
  final UnitType type;
  final double? bearingDeg;

  const _ResponderMarkerIcon({
    required this.type,
    this.bearingDeg,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (type) {
      UnitType.ambulance => (Icons.local_hospital, Colors.red),
      UnitType.fireTruck => (Icons.local_fire_department, Colors.orange),
      UnitType.policeUnit => (Icons.local_police, Colors.blue),
      UnitType.rescue => (Icons.health_and_safety, Colors.green),
    };

    final marker = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: -8,
          child: Icon(
            Icons.navigation,
            size: 16,
            color: color,
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ],
    );

    if (bearingDeg == null) return marker;
    final bearingRad = bearingDeg! * 3.14159265 / 180.0;
    return Transform.rotate(
      angle: bearingRad,
      child: marker,
    );
  }
}

class _SOSMarkerIcon extends StatelessWidget {
  const _SOSMarkerIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(color: Colors.red.withValues(alpha: 0.5), blurRadius: 8),
        ],
      ),
      child: const Icon(Icons.sos, color: Colors.white, size: 24),
    );
  }
}
