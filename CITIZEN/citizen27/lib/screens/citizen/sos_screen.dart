import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../map/barangay_coverage.dart';
import '../../map/rescue_map_tiles.dart';
import '../../models/map_layer_models.dart';
import '../../models/rescue_models.dart';
import '../../widgets/chat_fab_with_badge.dart';
import '../../widgets/map_layers_sheet.dart';
import '../../widgets/rescue_map_tile_layer.dart';
import '../../providers/rescue_provider.dart';
import '../../services/osrm_routing_service.dart';
import '../../services/local_notification_service.dart';
import '../../services/map_layer_data_service.dart';
import '../../utils/geo_utils.dart';
import '../../utils/route_geo_utils.dart';
import '../../utils/facility_search_utils.dart';
import '../../widgets/sos_chat_panel.dart';
import '../../widgets/sos_scene_photo.dart';
import '../dashboard/account_center_screen.dart';

enum _CitizenLiveStatusType { enRoute, nearby, transporting, arrived }

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key});

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

class _SOSScreenState extends State<SOSScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const String _kQueuedSosKey = 'queued_sos_request';
  static const String _kCallbackPhoneKey = 'guest_callback_phone';
  bool _sending = false;
  SOSType _selectedSosType = SOSType.medical;
  SOSRequest? _lastRequest;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  StreamSubscription? _dispatchSub;
  StreamSubscription? _responderLocationSub;
  StreamSubscription? _restoreSosSub;
  StreamSubscription? _sosCompletedSub;
  Map<String, dynamic>? _dispatchInfo;
  LatLng? _responderPosition;
  final MapController _mapController = MapController();
  bool _trackingMapUserInteracted = false;
  bool _trackingMapAutoFitDone = false;

  List<LatLng> _routeToMe = [];
  double _routeDistanceKm = 0;
  double _routeEtaMinutes = 0;
  Timer? _routeRefreshTimer;
  Timer? _routeDebounce;
  LatLng? _lastRoutedFrom;
  DateTime? _lastRouteAt;
  bool _routeRefreshInFlight = false;
  bool _routeRefreshPending = false;
  Timer? _cancelPromptTimer;
  final OsrmRoutingService _osrm = OsrmRoutingService();

  bool _userMapExpanded = false;
  bool _userMapVisible = true;
  bool _citizenMapFullScreen = false;
  bool _chatSheetOpen = false;
  bool _showRescueCompleteOverlay = false;
  Timer? _rescueCompleteOverlayTimer;
  bool _notifiedResponderAssigned = false;
  bool _notifiedResponderNearby30m = false;
  bool _notifiedPickupStarted = false;
  bool _notifiedArrivedFacility = false;
  String? _liveStatusTitle;
  String? _liveStatusSubtitle;
  _CitizenLiveStatusType _liveStatusType = _CitizenLiveStatusType.enRoute;
  bool _liveStatusVisible = false;
  LatLng? _dispatchDestinationPosition;
  String? _dispatchDestinationName;
  String? _dispatchRoutingTo;
  final MapController _userMapController = MapController();
  final TextEditingController _detailsController = TextEditingController();
  final TextEditingController _reportedForController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  String? _scenePhotoUrl;
  bool _pickingPhoto = false;
  List<MapLayerPOI> _citizenMedicalFacilities = const [];
  MapLayerPOI? _preferredMedicalFacility;
  bool _usePinnedLocation = false;
  bool _forSomeoneElse = false;
  LatLng? _pinnedLocation;
  bool _locationWatchStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _citizenMedicalFacilities = MapLayerDataService.getLayerData(MapLayerType.hospitals);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<RescueProvider>();
      await provider.persistSessionRole(UserRole.citizen);
      await provider.refreshLocationStatus();
      provider.initLocation();
      if (!mounted) return;
      await provider.loadCitizenProfile();
      if (!mounted) return;
      await _prefillCallbackPhone(provider);
      await provider.loadActiveSOS();
      if (!mounted) return;
      final id = provider.activeSosId;
      if (id != null) _restoreActiveSOS(id);
      // Try to send any SOS that was queued while offline.
      await _trySendQueuedSOS();
    });
  }

  Future<void> _prefillCallbackPhone(RescueProvider provider) async {
    if (_phoneController.text.trim().isNotEmpty) return;
    final profile = provider.citizenPhone?.trim() ?? '';
    if (profile.isNotEmpty) {
      _phoneController.text = profile;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kCallbackPhoneKey)?.trim() ?? '';
      if (saved.isNotEmpty && mounted) {
        _phoneController.text = saved;
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _lastRequest != null &&
        _dispatchInfo == null) {
      _showCancelPendingPromptDialog();
    }
  }

  void _restoreActiveSOS(String sosId) {
    final provider = context.read<RescueProvider>();

    _restoreSosSub?.cancel();
    _restoreSosSub = provider.firebaseSync.watchSOS(sosId).listen((sos) async {
      if (sos != null && mounted) {
        if (!_locationWatchStarted) {
          _locationWatchStarted = true;
          provider.startCitizenLocationUpdates(
            sosId,
            pinLocation: sos.locationIsPinned,
          );
        }
        setState(() => _lastRequest = sos);
        _startCancelPromptTimer();
      } else if (sos == null && mounted) {
        await _handleSosEnded(sosId);
      }
    });

    _dispatchSub?.cancel();
    _dispatchSub = provider.firebaseSync.watchDispatch(sosId).listen((info) {
      if (info == null) {
        if (mounted) {
          setState(() {
            _dispatchInfo = null;
            _dispatchDestinationPosition = null;
            _dispatchDestinationName = null;
            _dispatchRoutingTo = null;
          });
          _resetDispatchMilestoneFlags();
          _resetLiveDispatchStatus();
        }
        return;
      }
      if (mounted) {
        final routingTo = info['routingTo'] as String?;
        final destinationName = info['destinationName'] as String?;
        final dLat = (info['destinationLat'] as num?)?.toDouble();
        final dLng = (info['destinationLng'] as num?)?.toDouble();
        setState(() {
          _dispatchInfo = info;
          _dispatchRoutingTo = routingTo;
          _dispatchDestinationName = destinationName;
          _dispatchDestinationPosition =
              (dLat != null && dLng != null) ? LatLng(dLat, dLng) : null;
        });
        if (!_notifiedResponderAssigned) {
          _notifiedResponderAssigned = true;
          LocalNotificationService().showResponderAssigned(
            info['unitCallSign'] as String? ?? 'Responder',
          );
        }
        _updateLiveStatusFromDispatch(info);
        _handleCitizenDispatchMilestones(info);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _responderPosition == null) return;
          if (!_trackingMapUserInteracted && !_trackingMapAutoFitDone) {
            _trackingMapAutoFitDone = true;
            _fitBothMarkers();
          }
        });
        final unitId = info['unitId'] as String?;
        if (unitId != null && _responderLocationSub == null) {
          _startResponderTracking(provider, unitId);
        }
      }
    });
  }

  void _resetDispatchMilestoneFlags() {
    _notifiedResponderNearby30m = false;
    _notifiedPickupStarted = false;
    _notifiedArrivedFacility = false;
  }

  void _resetLiveDispatchStatus() {
    _liveStatusTitle = null;
    _liveStatusSubtitle = null;
    _liveStatusType = _CitizenLiveStatusType.enRoute;
    _liveStatusVisible = false;
  }

  void _updateLiveStatusFromDispatch(Map<String, dynamic> info) {
    final phase = info['phase'] as String?;
    final routingTo = info['routingTo'] as String?;
    final destinationName = info['destinationName'] as String?;
    final distanceMeters = _safeInt(info['distanceMeters']);
    final etaMinutes = _safeInt(info['etaMinutes']);

    _CitizenLiveStatusType nextType = _CitizenLiveStatusType.enRoute;
    String nextTitle = 'Responder en route';
    String nextSubtitle = 'Responder is heading to your SOS location.';

    if (phase == 'atFacility') {
      nextType = _CitizenLiveStatusType.arrived;
      nextTitle = 'Arrived at facility';
      nextSubtitle = destinationName != null && destinationName.trim().isNotEmpty
          ? 'Arrived at ${destinationName.trim()}.'
          : 'Responder has reached the destination facility.';
    } else if (phase == 'enRouteToFacility') {
      nextType = _CitizenLiveStatusType.transporting;
      nextTitle = 'Patient picked up';
      nextSubtitle = destinationName != null && destinationName.trim().isNotEmpty
          ? 'En route to ${destinationName.trim()}.'
          : 'En route to the nearest hospital/clinic.';
    } else if (routingTo == 'sos' &&
        distanceMeters != null &&
        distanceMeters <= 30) {
      nextType = _CitizenLiveStatusType.nearby;
      nextTitle = 'Responder is nearby';
      nextSubtitle = '${distanceMeters.clamp(0, 30)}m away - please be ready.';
    } else {
      final parts = <String>[];
      if (distanceMeters != null) {
        parts.add(distanceMeters >= 1000
            ? '${(distanceMeters / 1000).toStringAsFixed(1)} km away'
            : '${distanceMeters}m away');
      }
      if (etaMinutes != null) {
        parts.add('ETA ${etaMinutes} min');
      }
      if (parts.isNotEmpty) {
        nextSubtitle = parts.join(' • ');
      }
    }

    final shouldShow = _dispatchInfo != null;
    final changed = _liveStatusVisible != shouldShow ||
        _liveStatusType != nextType ||
        _liveStatusTitle != nextTitle ||
        _liveStatusSubtitle != nextSubtitle;
    if (!changed) return;
    if (!mounted) return;
    setState(() {
      _liveStatusVisible = shouldShow;
      _liveStatusType = nextType;
      _liveStatusTitle = nextTitle;
      _liveStatusSubtitle = nextSubtitle;
    });
  }

  void _handleCitizenDispatchMilestones(Map<String, dynamic> info) {
    final phase = info['phase'] as String?;
    final routingTo = info['routingTo'] as String?;
    final destinationName = info['destinationName'] as String?;
    final distanceMeters = _safeInt(info['distanceMeters']);

    if (!_notifiedResponderNearby30m &&
        routingTo == 'sos' &&
        distanceMeters != null &&
        distanceMeters <= 30) {
      _notifiedResponderNearby30m = true;
      final meters = distanceMeters.clamp(0, 30);
      LocalNotificationService().showResponderNearby(meters: meters);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Responder is nearby (${meters}m). Please be ready outside.',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }

    if (!_notifiedPickupStarted && phase == 'enRouteToFacility') {
      _notifiedPickupStarted = true;
      LocalNotificationService()
          .showPickupStarted(destinationName: destinationName);
      if (mounted) {
        final msg = destinationName != null && destinationName.trim().isNotEmpty
            ? 'Patient picked up. Now on route to ${destinationName.trim()}.'
            : 'Patient picked up. Now on route to nearest hospital/clinic.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }

    if (!_notifiedArrivedFacility && phase == 'atFacility') {
      _notifiedArrivedFacility = true;
      LocalNotificationService()
          .showArrivedAtFacility(destinationName: destinationName);
      if (mounted) {
        final msg = destinationName != null && destinationName.trim().isNotEmpty
            ? 'Arrived at ${destinationName.trim()}.'
            : 'Arrived at destination facility.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// Cancel flow: different copy if a responder has already accepted.
  void _showCancelSOSDialog() {
    if (_lastRequest == null || !mounted) return;
    if (_dispatchInfo != null) {
      _showCancelAfterDispatchDialog();
    } else {
      _showCancelPendingPromptDialog();
    }
  }

  void _showCancelPendingPromptDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('SOS still active'),
        content: const Text(
          'Your SOS is still active. Do you want to cancel it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('No, keep it'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cancelSOS();
            },
            child: const Text('Yes, cancel SOS'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCancelAfterDispatchDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Responder is en route'),
        content: const Text(
          'A rescue unit is already assigned and may be traveling to you. '
          'Cancelling will stop the response and notify dispatch systems.\n\n'
          'Are you sure you want to cancel this SOS?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep SOS'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel SOS anyway'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Final confirmation'),
        content: const Text(
          'This cannot be undone. Cancel the emergency request now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade900),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, cancel'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await _cancelSOS();
    }
  }

  void _startCancelPromptTimer() {
    _cancelPromptTimer?.cancel();
    _cancelPromptTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) {
        if (mounted && _lastRequest != null && _dispatchInfo == null) {
          _showCancelPendingPromptDialog();
        }
      },
    );
  }

  void _cleanupEndedSosState() {
    if (!mounted) return;
    final provider = context.read<RescueProvider>();
    _dispatchSub?.cancel();
    _responderLocationSub?.cancel();
    _restoreSosSub?.cancel();
    _sosCompletedSub?.cancel();
    _routeRefreshTimer?.cancel();
    _routeDebounce?.cancel();
    _cancelPromptTimer?.cancel();
    provider.clearActiveSOS();
    provider.stopCitizenLocationUpdates();
    _locationWatchStarted = false;
    _dispatchDestinationPosition = null;
    _dispatchDestinationName = null;
    _dispatchRoutingTo = null;
    _resetDispatchMilestoneFlags();
    _resetLiveDispatchStatus();
  }

  void _handleRescueCompleted() {
    if (!mounted) return;
    _cleanupEndedSosState();
    setState(() {
      _lastRequest = null;
      _dispatchInfo = null;
      _responderPosition = null;
      _routeToMe = [];
      _lastRoutedFrom = null;
      _lastRouteAt = null;
      _showRescueCompleteOverlay = true;
    });
    _rescueCompleteOverlayTimer?.cancel();
    _rescueCompleteOverlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showRescueCompleteOverlay = false);
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Rescue completed. Thank you!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _handleSosEnded(String sosId) async {
    final provider = context.read<RescueProvider>();
    final status = await provider.firebaseSync.getSOSHistoryStatus(sosId);
    if (!mounted) return;
    if (status == SOSStatus.completed) {
      _handleRescueCompleted();
      return;
    }

    _cleanupEndedSosState();
    setState(() {
      _lastRequest = null;
      _dispatchInfo = null;
      _responderPosition = null;
      _routeToMe = [];
      _lastRoutedFrom = null;
      _lastRouteAt = null;
      _showRescueCompleteOverlay = false;
    });
    _rescueCompleteOverlayTimer?.cancel();
  }

  Future<void> _cancelSOS() async {
    if (_lastRequest == null) return;
    final sosId = _lastRequest!.id;
    final provider = context.read<RescueProvider>();

    _dispatchSub?.cancel();
    _responderLocationSub?.cancel();
    _restoreSosSub?.cancel();
    _sosCompletedSub?.cancel();
    _routeRefreshTimer?.cancel();
    _routeDebounce?.cancel();
    _cancelPromptTimer?.cancel();
    _rescueCompleteOverlayTimer?.cancel();

    await provider.cancelCitizenSOS(sosId);

    if (!mounted) return;
    setState(() {
      _lastRequest = null;
      _dispatchInfo = null;
      _responderPosition = null;
      _routeToMe = [];
      _lastRoutedFrom = null;
      _lastRouteAt = null;
      _dispatchDestinationPosition = null;
      _dispatchDestinationName = null;
      _dispatchRoutingTo = null;
      _notifiedResponderAssigned = false;
    });
    _resetDispatchMilestoneFlags();
    _resetLiveDispatchStatus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('SOS cancelled.'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _sendSOS() async {
    if (_sending) return;

    if (_usePinnedLocation) {
      if (_pinnedLocation == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tap the map to drop the incident pin first.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      if (_forSomeoneElse && _reportedForController.text.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter the name of the person who needs help.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
    }

    final provider = context.read<RescueProvider>();
    // Ensure citizen profile is loaded (in case screen was opened directly).
    await provider.loadCitizenProfile();

    if (!_usePinnedLocation && provider.currentPosition == null) {
      await provider.initLocation();
    }
    if (!mounted) return;

    final target =
        _usePinnedLocation ? _pinnedLocation : provider.currentPosition;
    final homeBarangayId = provider.citizenBarangayId;
    if (target != null &&
        !BarangayCoverage.contains(target, barangayId: homeBarangayId)) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Outside Barangay $homeBarangayId'),
          content: Text(
            'This location is outside Barangay $homeBarangayId coverage. Send the SOS anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final confirmSend = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Send SOS?'),
        content: const Text(
          'Only send if this is a real emergency. '
          'Responders and the barangay command center will be alerted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send SOS'),
          ),
        ],
      ),
    );
    if (confirmSend != true || !mounted) return;

    setState(() => _sending = true);

    try {

      final name = provider.citizenName ?? 'Citizen User';
      final id = provider.citizenId ?? 'citizen-${name.hashCode}';

      final details = _detailsController.text.trim();
      final preferred = _selectedSosType == SOSType.medical
          ? _preferredMedicalFacility
          : null;
      final request = await provider.createSOS(
        citizenId: id,
        citizenName: name,
        message: details.isEmpty ? null : details,
        priority: SOSPriority.high,
        sosType: _selectedSosType,
        preferredFacilityId: preferred?.id,
        preferredFacilityName: preferred?.name,
        preferredFacilityLocation: preferred?.position,
        incidentLocation: _usePinnedLocation ? _pinnedLocation : null,
        locationIsPinned: _usePinnedLocation,
        reportedForName:
            _forSomeoneElse ? _reportedForController.text.trim() : null,
        callbackPhone: _phoneController.text.trim(),
        scenePhotoUrl: _scenePhotoUrl,
      );
      _detailsController.clear();
      final typedPhone = _phoneController.text.trim();
      if (typedPhone.isNotEmpty) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kCallbackPhoneKey, typedPhone);
        } catch (_) {}
      }

      _locationWatchStarted = true;
      provider.startCitizenLocationUpdates(
        request.id,
        pinLocation: request.locationIsPinned,
      );

      setState(() {
        _lastRequest = request;
        _sending = false;
        _notifiedResponderAssigned = false;
      });
      _resetDispatchMilestoneFlags();
      _resetLiveDispatchStatus();

      _watchForDispatch(request.id);
      _sosCompletedSub?.cancel();
      _sosCompletedSub = provider.firebaseSync.watchSOS(request.id).listen((sos) async {
        if (sos == null && mounted) {
          await _handleSosEnded(request.id);
        }
      });
      _startCancelPromptTimer();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SOS Sent! Help is on the way.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _sending = false);
      if (mounted) {
        // Queue the SOS locally so it can be retried when the network is available.
        await _queueSOSForRetry();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to send SOS — it will be queued and retried when your connection is back.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> _queueSOSForRetry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final provider = context.read<RescueProvider>();
      final pos = _usePinnedLocation ? _pinnedLocation : provider.currentPosition;
      final payload = <String, Object?>{
        'sosType': _selectedSosType.name,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'locationIsPinned': _usePinnedLocation,
        if (_forSomeoneElse) 'reportedForName': _reportedForController.text.trim(),
        if (_phoneController.text.trim().isNotEmpty)
          'callbackPhone': _phoneController.text.trim(),
        if (pos != null) 'lat': pos.latitude,
        if (pos != null) 'lng': pos.longitude,
        if (_preferredMedicalFacility != null)
          'preferredFacilityId': _preferredMedicalFacility!.id,
        if (_preferredMedicalFacility != null)
          'preferredFacilityName': _preferredMedicalFacility!.name,
        if (_preferredMedicalFacility != null)
          'preferredFacilityLat': _preferredMedicalFacility!.position.latitude,
        if (_preferredMedicalFacility != null)
          'preferredFacilityLng': _preferredMedicalFacility!.position.longitude,
      };
      await prefs.setString(_kQueuedSosKey, jsonEncode(payload));
    } catch (_) {
      // Best-effort only; ignore failures.
    }
  }

  LatLng? _sceneLocationForHospital(RescueProvider provider) {
    if (_usePinnedLocation && _pinnedLocation != null) return _pinnedLocation;
    return provider.currentPosition;
  }

  String? _hospitalDistanceLabel(MapLayerPOI poi) {
    final scene = _sceneLocationForHospital(context.read<RescueProvider>());
    if (scene == null) return null;
    return FacilitySearchUtils.formatDistanceKm(
      GeoUtils.haversineKm(scene, poi.position),
    );
  }

  void _suggestNearbyHospital() {
    final provider = context.read<RescueProvider>();
    final scene = _sceneLocationForHospital(provider);
    if (scene == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set the incident location first.')),
      );
      return;
    }
    final nearest = FacilitySearchUtils.nearestTo(
      scene,
      _citizenMedicalFacilities,
    );
    if (nearest == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hospitals found.')),
      );
      return;
    }
    setState(() => _preferredMedicalFacility = nearest);
    final dist = FacilitySearchUtils.formatDistanceKm(
      GeoUtils.haversineKm(scene, nearest.position),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Nearby: ${nearest.name} • $dist')),
    );
  }

  Future<void> _openPreferredFacilitySheet() async {
    final controller = TextEditingController();
    String query = '';
    final scene = _sceneLocationForHospital(context.read<RescueProvider>());
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
            final q = query.trim();
            var rows = _citizenMedicalFacilities.where((f) {
              return FacilitySearchUtils.matches(f, q);
            });
            final list = scene == null
                ? rows.toList()
                : FacilitySearchUtils.sortedByDistance(scene, rows);
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
                    const Text(
                      'Preferred hospital or clinic (optional)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Search hospital / clinic',
                        hintStyle: TextStyle(color: Colors.white54),
                        prefixIcon: Icon(Icons.search, color: Colors.white70),
                      ),
                      onChanged: (v) => setLocal(() => query = v),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 280,
                      child: ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final it = list[i];
                          final dist = scene == null
                              ? null
                              : FacilitySearchUtils.formatDistanceKm(
                                  GeoUtils.haversineKm(scene, it.position),
                                );
                          return ListTile(
                            leading: const Icon(Icons.local_hospital, color: Colors.redAccent),
                            title: Text(
                              it.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              '${dist != null ? '$dist • ' : ''}${it.city ?? ''} • ${it.facilityType ?? 'hospital'}\n'
                              '${_facilityOpenLabel(it)}${it.phone != null ? ' • ${it.phone}' : ''}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            isThreeLine: true,
                            onTap: () {
                              setState(() => _preferredMedicalFacility = it);
                              Navigator.pop(ctx);
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

  String _facilityOpenLabel(MapLayerPOI poi) {
    if ((poi.openStatusText ?? '').trim().isNotEmpty) return poi.openStatusText!.trim();
    if (poi.isOpenNow == true) return 'Open now';
    if (poi.isOpenNow == false) return 'Closed now';
    return 'Status unknown';
  }

  Future<void> _trySendQueuedSOS() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kQueuedSosKey);
      if (raw == null || raw.isEmpty) return;

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final typeName = data['sosType'] as String?;
      final type = typeName != null
          ? SOSType.values.firstWhere(
              (t) => t.name == typeName,
              orElse: () => SOSType.medical,
            )
          : SOSType.medical;

      final provider = context.read<RescueProvider>();
      await provider.loadCitizenProfile();
      if (provider.currentPosition == null) {
        await provider.initLocation();
      }

      final name = provider.citizenName ?? 'Citizen User';
      final id = provider.citizenId ?? 'citizen-${name.hashCode}';

      // If there is already an active SOS, don't send another; keep queued.
      if (provider.activeSosId != null) return;

      final queuedPinned = data['locationIsPinned'] == true;
      LatLng? queuedPin;
      if (data['lat'] is num && data['lng'] is num) {
        queuedPin = LatLng(
          (data['lat'] as num).toDouble(),
          (data['lng'] as num).toDouble(),
        );
      }

      final request = await provider.createSOS(
        citizenId: id,
        citizenName: name,
        message: 'Emergency! Need immediate assistance (queued).',
        priority: SOSPriority.high,
        sosType: type,
        preferredFacilityId: data['preferredFacilityId'] as String?,
        preferredFacilityName: data['preferredFacilityName'] as String?,
        preferredFacilityLocation: (data['preferredFacilityLat'] is num &&
                data['preferredFacilityLng'] is num)
            ? LatLng(
                (data['preferredFacilityLat'] as num).toDouble(),
                (data['preferredFacilityLng'] as num).toDouble(),
              )
            : null,
        incidentLocation: queuedPinned ? queuedPin : null,
        locationIsPinned: queuedPinned,
        reportedForName: data['reportedForName'] as String?,
        callbackPhone: data['callbackPhone'] as String?,
      );

      _locationWatchStarted = true;
      provider.startCitizenLocationUpdates(
        request.id,
        pinLocation: request.locationIsPinned,
      );
      _lastRequest = request;
      _sending = false;
      _watchForDispatch(request.id);
      _sosCompletedSub?.cancel();
      _sosCompletedSub =
          provider.firebaseSync.watchSOS(request.id).listen((sos) async {
        if (sos == null && mounted) {
          await _handleSosEnded(request.id);
        }
      });
      _startCancelPromptTimer();

      await prefs.remove(_kQueuedSosKey);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Queued SOS has been sent.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (_) {
      // If retry fails, keep the queued SOS for a future attempt.
    }
  }

  void _watchForDispatch(String sosId) {
    final provider = context.read<RescueProvider>();

    _dispatchSub = provider.firebaseSync.watchDispatch(sosId).listen((info) {
      if (info == null) {
        if (mounted) {
          setState(() {
            _dispatchInfo = null;
            _dispatchDestinationPosition = null;
            _dispatchDestinationName = null;
            _dispatchRoutingTo = null;
          });
          _resetDispatchMilestoneFlags();
          _resetLiveDispatchStatus();
        }
        return;
      }
      if (!mounted) return;

      final routingTo = info['routingTo'] as String?;
      final destinationName = info['destinationName'] as String?;
      final dLat = (info['destinationLat'] as num?)?.toDouble();
      final dLng = (info['destinationLng'] as num?)?.toDouble();
      setState(() {
        _dispatchInfo = info;
        _dispatchRoutingTo = routingTo;
        _dispatchDestinationName = destinationName;
        _dispatchDestinationPosition =
            (dLat != null && dLng != null) ? LatLng(dLat, dLng) : null;
      });
      if (!_notifiedResponderAssigned) {
        _notifiedResponderAssigned = true;
        LocalNotificationService().showResponderAssigned(
          info['unitCallSign'] as String? ?? 'Responder',
        );
      }
      _updateLiveStatusFromDispatch(info);
      _handleCitizenDispatchMilestones(info);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _responderPosition == null) return;
        if (!_trackingMapUserInteracted && !_trackingMapAutoFitDone) {
          _trackingMapAutoFitDone = true;
          _fitBothMarkers();
        }
      });

      final unitId = info['unitId'] as String?;
      if (unitId != null && _responderLocationSub == null) {
        _startResponderTracking(provider, unitId);
      }
    });
  }

  LatLng? _incidentTarget(RescueProvider provider) {
    if (_lastRequest != null) return _lastRequest!.location;
    if (_usePinnedLocation) return _pinnedLocation;
    return provider.currentPosition;
  }

  Marker _reporterMarker(LatLng point) {
    return Marker(
      point: point,
      width: 48,
      height: 48,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.blue.withValues(alpha: 0.5),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(Icons.person, color: Colors.white, size: 22),
      ),
    );
  }

  Marker _incidentMarker(LatLng point) {
    return Marker(
      point: point,
      width: 48,
      height: 48,
      child: const Icon(Icons.location_pin, color: Colors.red, size: 48),
    );
  }

  List<Marker> _citizenIncidentMarkers(RescueProvider provider) {
    final gps = provider.currentPosition;
    final incident = _incidentTarget(provider);
    final pinned = _lastRequest?.locationIsPinned == true ||
        (_lastRequest == null && _usePinnedLocation);
    final markers = <Marker>[];
    if (pinned) {
      if (incident != null) markers.add(_incidentMarker(incident));
      if (gps != null) markers.add(_reporterMarker(gps));
    } else if (gps != null) {
      markers.add(_reporterMarker(gps));
    } else if (incident != null) {
      markers.add(_incidentMarker(incident));
    }
    return markers;
  }

  /// Live GPS + route polyline that follows the responder (trim-ahead like responder nav).
  void _startResponderTracking(RescueProvider provider, String unitId) {
    _responderLocationSub?.cancel();
    _responderLocationSub =
        provider.firebaseSync.watchUnitLocation(unitId).listen((pos) {
      if (pos == null || !mounted) return;
      setState(() => _responderPosition = pos);
      // Trim is instant via [_routeAhead]; only OSRM-rebuild when off the line.
      _scheduleCitizenRouteRefresh();
    });

    _routeRefreshTimer?.cancel();
    _routeRefreshTimer =
        Timer.periodic(const Duration(seconds: 12), (_) => _refreshRoute());
    unawaited(_refreshRoute(force: true));
  }

  /// Drawn route ahead of the live responder pin (no wait for OSRM).
  List<LatLng> get _routeAhead {
    final pos = _responderPosition;
    if (_routeToMe.length < 2) return const [];
    final clean = <LatLng>[
      for (final p in _routeToMe)
        if (p.latitude.isFinite && p.longitude.isFinite) p,
    ];
    if (clean.length < 2) return const [];
    if (pos == null ||
        !pos.latitude.isFinite ||
        !pos.longitude.isFinite) {
      return clean;
    }
    try {
      final ahead = RouteGeoUtils.remainingPolyline(pos, clean);
      return [
        for (final p in ahead)
          if (p.latitude.isFinite && p.longitude.isFinite) p,
      ];
    } catch (_) {
      return clean;
    }
  }

  static double _finiteOr(double value, [double fallback = 0]) {
    if (value.isNaN || value.isInfinite) return fallback;
    return value;
  }

  static int? _safeInt(dynamic value) {
    if (value is! num) return null;
    if (value.isNaN || value.isInfinite) return null;
    return value.round();
  }

  void _scheduleCitizenRouteRefresh() {
    final pos = _responderPosition;
    if (pos == null) return;

    var farOff = _routeToMe.length < 2;
    if (_routeToMe.length >= 2) {
      var minDist = double.infinity;
      for (final p in _routeToMe) {
        final d = GeoUtils.haversineKm(pos, p);
        if (d < minDist) minDist = d;
      }
      farOff = minDist > 0.08; // ~80m off the polyline → rebuild via OSRM
    } else if (_lastRoutedFrom != null) {
      farOff = GeoUtils.haversineKm(_lastRoutedFrom!, pos) > 0.05;
    }

    // While on-route, trimming is enough — don't spam OSRM.
    if (!farOff && _routeToMe.length >= 2) return;

    _routeDebounce?.cancel();
    _routeDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_refreshRoute(force: true)),
    );
  }

  Future<void> _refreshRoute({bool force = false}) async {
    final provider = context.read<RescueProvider>();
    final fallbackCitizenPos = _incidentTarget(provider);
    final target = _dispatchRoutingTo == 'facility' &&
            _dispatchDestinationPosition != null
        ? _dispatchDestinationPosition!
        : fallbackCitizenPos;
    if (_responderPosition == null || target == null) return;
    if (_routeRefreshInFlight) {
      _routeRefreshPending = true;
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastRouteAt != null &&
        now.difference(_lastRouteAt!) < const Duration(seconds: 3) &&
        _lastRoutedFrom != null &&
        GeoUtils.haversineKm(_lastRoutedFrom!, _responderPosition!) < 0.05) {
      return;
    }

    _routeRefreshInFlight = true;
    try {
      final from = _responderPosition!;
      final result = await _osrm.getRoute(from, target);
      if (!mounted) return;
      if (!result.isEmpty) {
        setState(() {
          _routeToMe = [
            for (final p in result.points)
              if (p.latitude.isFinite && p.longitude.isFinite) p,
          ];
          if (_routeToMe.length < 2) {
            _routeToMe = [from, target];
          }
          _routeDistanceKm = _finiteOr(result.distanceKm, GeoUtils.haversineKm(from, target));
          _routeEtaMinutes = _finiteOr(
            result.durationMinutes,
            _routeDistanceKm / 0.5,
          );
          _lastRoutedFrom = from;
          _lastRouteAt = DateTime.now();
        });
      } else {
        final dist = _finiteOr(GeoUtils.haversineKm(from, target));
        setState(() {
          _routeToMe = [from, target];
          _routeDistanceKm = dist;
          _routeEtaMinutes = dist / 0.5;
          _lastRoutedFrom = from;
          _lastRouteAt = DateTime.now();
        });
      }
    } catch (_) {
      if (!mounted) return;
      final from = _responderPosition!;
      if (!from.latitude.isFinite ||
          !from.longitude.isFinite ||
          !target.latitude.isFinite ||
          !target.longitude.isFinite) {
        return;
      }
      final dist = _finiteOr(GeoUtils.haversineKm(from, target));
      setState(() {
        _routeToMe = [from, target];
        _routeDistanceKm = dist;
        _routeEtaMinutes = dist / 0.5;
        _lastRoutedFrom = from;
        _lastRouteAt = DateTime.now();
      });
    } finally {
      _routeRefreshInFlight = false;
      if (_routeRefreshPending && mounted) {
        _routeRefreshPending = false;
        unawaited(_refreshRoute(force: true));
      }
    }
  }

  void _fitBothMarkers() {
    final provider = context.read<RescueProvider>();
    final incident = _incidentTarget(provider);
    if (_responderPosition == null || incident == null) return;

    final bounds = LatLngBounds.fromPoints([incident, _responderPosition!]);
    try {
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(80)),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _dispatchSub?.cancel();
    _responderLocationSub?.cancel();
    _restoreSosSub?.cancel();
    _sosCompletedSub?.cancel();
    _routeRefreshTimer?.cancel();
    _routeDebounce?.cancel();
    _cancelPromptTimer?.cancel();
    _rescueCompleteOverlayTimer?.cancel();
    try {
      final provider = context.read<RescueProvider>();
      // While an SOS is still active, keep streaming location to Firebase even if this screen is closed.
      if (provider.activeSosId == null) {
        provider.stopCitizenLocationUpdates();
      }
    } catch (_) {}
    _mapController.dispose();
    _userMapController.dispose();
    _detailsController.dispose();
    _reportedForController.dispose();
    _phoneController.dispose();
    _osrm.dispose();
    super.dispose();
  }

  Future<void> _confirmBackToMain(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go back to main screen?'),
        content: const Text(
          'You will leave this screen. Your citizen session stays signed in until you use '
          'Account Center → Log out.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, go back'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final provider = context.read<RescueProvider>();
      await provider.logDashboardExit(
        role: 'citizen',
        screen: 'sos',
        sosId: _lastRequest?.id,
      );
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmBackToMain(context);
      },
      child: Stack(
        children: [
          Builder(
            builder: (context) {
              if (_lastRequest != null && _dispatchInfo != null) {
                return _buildTrackingView();
              }
              if (_lastRequest != null) {
                return _buildWaitingView();
              }
              return _buildSOSView();
            },
          ),
          if (_citizenMapFullScreen) _buildCitizenFullScreenMapOverlay(),
          if (_showRescueCompleteOverlay) _buildRescueCompleteOverlay(),
        ],
      ),
    );
  }

  Widget _buildRescueCompleteOverlay() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.92, end: 1.0),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, scale, child) => Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: scale.clamp(0, 1),
              child: child,
            ),
          ),
          child: Container(
            width: 320,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: Color(0xFFE8F5E9),
                  child: Icon(
                    Icons.check_circle,
                    color: Color(0xFF2E7D32),
                    size: 34,
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  'Rescue completed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF1B3A5C),
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    decoration: TextDecoration.none,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Thank you',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF607D8B),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCitizenFullScreenMapOverlay() {
    return Material(
      color: const Color(0xFF0D1B2A),
      child: Stack(
        children: [
          Consumer<RescueProvider>(
            builder: (context, provider, _) {
              if (_lastRequest != null && _dispatchInfo != null) {
                return _buildTrackingMapContent(provider);
              }
              if (_lastRequest != null) {
                return _buildWaitingMapContent(provider);
              }
              return const SizedBox.shrink();
            },
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filled(
                      icon: const Icon(Icons.layers),
                      onPressed: () => showMapLayersSheet(context),
                      tooltip: 'Map type & details',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.fullscreen_exit),
                      onPressed: () =>
                          setState(() => _citizenMapFullScreen = false),
                      tooltip: 'Shrink map',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            right: 16,
            child: IconButton.filled(
              icon: const Icon(Icons.my_location),
              tooltip: 'Recenter',
              onPressed: () {
                setState(() {
                  _trackingMapUserInteracted = false;
                  _trackingMapAutoFitDone = false;
                });
                _fitBothMarkers();
              },
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingMapContent(RescueProvider provider) {
    final incident = _incidentTarget(provider);
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: incident ??
            provider.currentPosition ??
            const LatLng(14.6544, 120.9840),
        initialZoom: 15,
        interactionOptions: kRescueMapInteractions,
        keepAlive: true,
      ),
      children: [
        const RescueMapTileLayer(),
        ...BarangayCoverage.mapLayers(
          barangayId: provider.citizenBarangayId,
        ),
        MarkerLayer(markers: _citizenIncidentMarkers(provider)),
      ],
    );
  }

  Widget _buildTrackingMapContent(RescueProvider provider) {
    final unitType = _dispatchInfo?['unitType'] ?? 'rescue';
    final unitIcon = switch (unitType) {
      'ambulance' => Icons.local_hospital,
      'fireTruck' => Icons.local_fire_department,
      'policeUnit' => Icons.local_police,
      _ => Icons.health_and_safety,
    };
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _incidentTarget(provider) ??
            provider.currentPosition ??
            _lastRequest!.location,
        initialZoom: 14,
        interactionOptions: kRescueMapInteractions,
        keepAlive: true,
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && !_trackingMapUserInteracted) {
            setState(() => _trackingMapUserInteracted = true);
          }
        },
      ),
      children: [
        const RescueMapTileLayer(),
        ...BarangayCoverage.mapLayers(
          barangayId: provider.citizenBarangayId,
        ),
        if (_routeAhead.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routeAhead,
                color: Colors.blue,
                strokeWidth: 5,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            ..._citizenIncidentMarkers(provider),
            if (_responderPosition != null)
              Marker(
                point: _responderPosition!,
                width: 56,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withValues(alpha: 0.6),
                        blurRadius: 14,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: Icon(unitIcon, color: Colors.white, size: 26),
                ),
              ),
            if (_dispatchRoutingTo == 'facility' &&
                _dispatchDestinationPosition != null)
              Marker(
                point: _dispatchDestinationPosition!,
                width: 56,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withValues(alpha: 0.55),
                        blurRadius: 14,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.local_hospital,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── SOS home ──

  static const Color _navy = Color(0xFF1B3A5C);

  BoxDecoration get _sosCardDecoration => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6EDF4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      );

  Widget _sosHomeCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: padding ?? const EdgeInsets.all(16),
      decoration: _sosCardDecoration,
      child: child,
    );
  }

  Widget _sosSectionHeader(IconData icon, String title, {String? subtitle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF4FA),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: _navy, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: _navy,
                ),
              ),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(color: Colors.grey[600], fontSize: 12, height: 1.35),
          ),
        ],
      ],
    );
  }

  Widget _buildSOSView() {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        title: const Text('Caloocan City Integrated Rescue Operations'),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle),
            tooltip: 'Account Center',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AccountCenterScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<RescueProvider>(
        builder: (context, provider, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              children: [
                _buildLocationBanner(provider),
                _buildLocationModeSection(provider),
                _buildUserMapSection(provider),
                _buildSOSTypeSection(),
                _buildAvailableRescuers(provider),
                _buildCallbackPhoneField(),
                _buildScenePhotoField(),
                _buildSOSButton(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildLocationBanner(RescueProvider provider) {
    final status = provider.locationStatus;
    if (status == null || !status.needsPrompt) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.shade700,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.location_off, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Turn on Location',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _usePinnedLocation
                      ? 'GPS is optional when you drop a pin for someone else.'
                      : 'Keep location on so rescuers can find you accurately.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              final opened = await provider.locationService.openLocationSettings();
              if (!opened) await provider.locationService.openAppSettings();
              if (mounted) provider.refreshLocationStatus();
            },
            child: const Text('Turn on', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationModeSection(RescueProvider provider) {
    final gps = provider.currentPosition;
    final incident = _incidentTarget(provider);
    final usingPin = _usePinnedLocation;
    final shown = usingPin ? incident : gps;
    final statusTitle = usingPin
        ? (incident != null ? 'Pin set' : 'Drop a pin on the map')
        : (gps != null ? 'GPS ready' : 'Getting GPS…');
    return _sosHomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sosSectionHeader(
            Icons.place_outlined,
            'Incident location',
            subtitle:
                'Use your GPS, or drop a pin if a relative needs help somewhere else.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _locationModeChip(
                  label: 'My GPS',
                  icon: Icons.my_location,
                  selected: !usingPin,
                  onTap: () {
                    setState(() {
                      _usePinnedLocation = false;
                      _forSomeoneElse = false;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _locationModeChip(
                  label: 'Another location',
                  icon: Icons.push_pin_outlined,
                  selected: usingPin,
                  onTap: () {
                    setState(() {
                      _usePinnedLocation = true;
                      _userMapVisible = true;
                      _userMapExpanded = true;
                      _pinnedLocation ??= provider.currentPosition;
                    });
                    final seed = _pinnedLocation ?? provider.currentPosition;
                    if (seed != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        try {
                          _userMapController.move(seed, 16);
                        } catch (_) {}
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F7FB),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  shown != null
                      ? (usingPin ? Icons.push_pin : Icons.location_on)
                      : Icons.location_searching,
                  color: shown != null ? Colors.green.shade700 : Colors.orange.shade700,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: _navy,
                        ),
                      ),
                      if (shown != null)
                        Text(
                          '${shown.latitude.toStringAsFixed(5)}, ${shown.longitude.toStringAsFixed(5)}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      if (shown != null &&
                          !BarangayCoverage.contains(
                            shown,
                            barangayId: provider.citizenBarangayId,
                          ))
                        Text(
                          'Outside Barangay ${provider.citizenBarangayId}.',
                          style: TextStyle(
                            color: Colors.orange.shade800,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (usingPin) ...[
            const SizedBox(height: 8),
            Text(
              _pinnedLocation == null
                  ? 'Tap the map below to drop the incident pin.'
                  : 'Pin set. Tap the map again to move it.',
              style: TextStyle(
                color: _pinnedLocation == null
                    ? Colors.orange.shade800
                    : Colors.green.shade800,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _forSomeoneElse,
              onChanged: (v) => setState(() => _forSomeoneElse = v ?? false),
              title: const Text(
                'This SOS is for someone else',
                style: TextStyle(fontSize: 13),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_forSomeoneElse)
              TextField(
                controller: _reportedForController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name of person who needs help',
                  hintText: 'e.g. Maria (sister)',
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _locationModeChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? _navy : const Color(0xFFF4F7FB),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: selected ? Colors.white : _navy),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: selected ? Colors.white : _navy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserMapSection(RescueProvider provider) {
    final gps = provider.currentPosition;
    final pin = _pinnedLocation;
    if (!_userMapVisible) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() {
              _userMapVisible = true;
              _userMapExpanded = true;
            }),
            icon: const Icon(Icons.map),
            label: Text(
              _usePinnedLocation
                  ? 'Show map to drop a pin'
                  : (gps == null
                      ? 'Waiting for your GPS location...'
                      : 'Show your location on map'),
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _sosCardDecoration,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _userMapExpanded = !_userMapExpanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.map,
                    color: const Color(0xFF1B3A5C),
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Incident map',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: Color(0xFF1B3A5C),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF1B3A5C)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        _userMapVisible = false;
                        _userMapExpanded = false;
                      });
                    },
                  ),
                  Icon(
                    _userMapExpanded ? Icons.expand_less : Icons.expand_more,
                    color: const Color(0xFF1B3A5C),
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
          if (_userMapExpanded) ...[
            const Divider(height: 1),
            SizedBox(
              height: 280,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                    child: FlutterMap(
                      mapController: _userMapController,
                      options: MapOptions(
                        initialCenter: pin ??
                            gps ??
                            const LatLng(14.6544, 120.9840),
                        initialZoom: 15,
                        interactionOptions: kRescueMapInteractions,
                        keepAlive: true,
                        onTap: _usePinnedLocation
                            ? (tap, point) {
                                setState(() => _pinnedLocation = point);
                              }
                            : null,
                        onMapReady: () {
                          final center = pin ?? gps;
                          if (center != null) {
                            _userMapController.move(center, 16);
                          }
                        },
                      ),
                      children: [
                        const RescueMapTileLayer(),
                        ...BarangayCoverage.mapLayers(
                          barangayId: provider.citizenBarangayId,
                        ),
                        MarkerLayer(
                          markers: [
                            if (gps != null)
                              Marker(
                                point: gps,
                                width: 44,
                                height: 44,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.blue,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 3),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.blue
                                            .withValues(alpha: 0.5),
                                        blurRadius: 10,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(Icons.person,
                                      color: Colors.white, size: 22),
                                ),
                              ),
                            if (_usePinnedLocation && pin != null)
                              Marker(
                                point: pin,
                                width: 48,
                                height: 48,
                                child: const Icon(
                                  Icons.location_pin,
                                  color: Colors.red,
                                  size: 48,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (gps != null || pin != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: IconButton(
                        icon: const Icon(Icons.my_location,
                            color: Color(0xFF1B3A5C)),
                        onPressed: () {
                          final center = _usePinnedLocation
                              ? (pin ?? gps)
                              : (gps ?? pin);
                          if (center != null) {
                            _userMapController.move(center, 16);
                          }
                        },
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSOSTypeSection() {
    final selectedInfo = SOSTypeInfo.forType(_selectedSosType);
    return _sosHomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sosSectionHeader(
            Icons.emergency_outlined,
            'What type of emergency?',
            subtitle: selectedInfo.description,
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final tileW = (constraints.maxWidth - gap * 2) / 3;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: SOSType.values.map((type) {
                  final selected = _selectedSosType == type;
                  final color = _colorForSOSType(type);
                  return SizedBox(
                    width: tileW,
                    child: Material(
                      color: selected ? color.withValues(alpha: 0.14) : const Color(0xFFF4F7FB),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: () => setState(() => _selectedSosType = type),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
                          child: Column(
                            children: [
                              Icon(
                                _iconForSOSType(type),
                                size: 26,
                                color: selected ? color : Colors.blueGrey.shade600,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _shortSosLabel(type),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: selected ? color : _navy,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _detailsController,
            maxLines: 2,
            style: const TextStyle(color: Colors.black87, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Additional details (optional)',
              hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
              filled: true,
              fillColor: const Color(0xFFF4F7FB),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (_selectedSosType == SOSType.medical) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF5FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Preferred destination hospital (optional)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _navy,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _preferredMedicalFacility == null
                        ? 'Not selected. Responder can still choose nearest.'
                        : '${_preferredMedicalFacility!.name}'
                            '${_hospitalDistanceLabel(_preferredMedicalFacility!) != null ? ' • ${_hospitalDistanceLabel(_preferredMedicalFacility!)}' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: _preferredMedicalFacility == null
                          ? Colors.grey[700]
                          : _navy,
                      fontWeight: _preferredMedicalFacility == null
                          ? FontWeight.w500
                          : FontWeight.w700,
                    ),
                  ),
                  if (_preferredMedicalFacility != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${_facilityOpenLabel(_preferredMedicalFacility!)}${_preferredMedicalFacility!.phone != null ? ' • ${_preferredMedicalFacility!.phone}' : ''}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.blueGrey[700],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _suggestNearbyHospital,
                        icon: const Icon(Icons.near_me, size: 16),
                        label: const Text('Suggest nearby'),
                      ),
                      FilledButton.icon(
                        onPressed: _openPreferredFacilitySheet,
                        icon: const Icon(Icons.search, size: 16),
                        label: const Text('Choose'),
                      ),
                      if (_preferredMedicalFacility != null)
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _preferredMedicalFacility = null),
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Clear'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAvailableRescuers(RescueProvider provider) {
    final units = provider.unitsForDisplay
        .where((u) => provider.isUnitOnline(u.id) && u.isAvailable)
        .toList();

    if (units.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'No rescue units are currently available.\nYour SOS will be queued as soon as a unit comes online.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 12),
        ),
      );
    }

    return _sosHomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sosSectionHeader(Icons.local_shipping_outlined, 'Available rescue units nearby'),
          const SizedBox(height: 8),
          ...units.map((u) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (u.type) {
                    UnitType.ambulance => Icons.local_hospital,
                    UnitType.fireTruck => Icons.local_fire_department,
                    UnitType.policeUnit => Icons.local_police,
                    UnitType.rescue => Icons.health_and_safety,
                  },
                  color: Colors.green,
                ),
                title: Text(
                  u.callSign,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'AVAILABLE',
                  style: TextStyle(color: Colors.green, fontSize: 12),
                ),
              )),
        ],
      ),
    );
  }

  IconData _iconForSOSType(SOSType type) {
    return switch (type) {
      SOSType.medical => Icons.local_hospital,
      SOSType.fire => Icons.local_fire_department,
      SOSType.accident => Icons.car_crash,
      SOSType.flood => Icons.water_drop,
      SOSType.violence => Icons.shield,
      SOSType.other => Icons.help_outline,
    };
  }

  String _shortSosLabel(SOSType type) {
    return switch (type) {
      SOSType.medical => 'Medical',
      SOSType.fire => 'Fire',
      SOSType.accident => 'Accident',
      SOSType.flood => 'Flood',
      SOSType.violence => 'Violence',
      SOSType.other => 'Other',
    };
  }

  Color _colorForSOSType(SOSType type) {
    return switch (type) {
      SOSType.medical => const Color(0xFFC62828),
      SOSType.fire => const Color(0xFFE65100),
      SOSType.accident => const Color(0xFFF9A825),
      SOSType.flood => const Color(0xFF1565C0),
      SOSType.violence => const Color(0xFF6A1B9A),
      SOSType.other => const Color(0xFF455A64),
    };
  }

  String _unitTypeLabelForCitizen(String raw) {
    return switch (raw) {
      'ambulance' => 'AMBULANCE',
      'fireTruck' => 'FIRE TRUCK',
      'policeUnit' => 'POLICE',
      'rescue' => 'BARANGAY TANOD',
      _ => raw.toUpperCase(),
    };
  }

  Widget _buildCallbackPhoneField() {
    return _sosHomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sosSectionHeader(
            Icons.phone_outlined,
            'Your phone number',
            subtitle:
                'Optional. SOS still sends if this is empty. Add a number if you want responders to call you.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              hintText: '09XXXXXXXXX',
              prefixIcon: const Icon(Icons.call),
              filled: true,
              fillColor: const Color(0xFFF4F7FB),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickScenePhoto() async {
    if (_pickingPhoto) return;
    setState(() => _pickingPhoto = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 720,
        maxHeight: 720,
        imageQuality: 55,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      if (bytes.length > 250000) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo is too large. Pick a smaller image.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      setState(() {
        _scenePhotoUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not add photo. SOS can still be sent without one.'),
          backgroundColor: Colors.orange,
        ),
      );
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  Widget _buildScenePhotoField() {
    return _sosHomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sosSectionHeader(
            Icons.photo_camera_outlined,
            'Scene photo',
            subtitle:
                'Optional. Helps LGU and responders check the emergency. SOS still sends without a photo.',
          ),
          const SizedBox(height: 12),
          if (_scenePhotoUrl != null) SosScenePhotoThumb(photoUrl: _scenePhotoUrl),
          if (_scenePhotoUrl != null) const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _pickingPhoto ? null : _pickScenePhoto,
                icon: _pickingPhoto
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_a_photo, size: 16),
                label: Text(_scenePhotoUrl == null ? 'Add photo' : 'Change photo'),
              ),
              if (_scenePhotoUrl != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _scenePhotoUrl = null),
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('Remove'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSOSButton() {
    final hint = _usePinnedLocation
        ? 'Pinned location will be sent to dispatch. Phone and photo are optional.'
        : 'Your GPS location will be sent to dispatch. Phone and photo are optional.';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: 1.0 + ((_pulseAnimation.value - 1.0) * 0.025),
                child: child,
              );
            },
            child: Semantics(
              button: true,
              label: 'Send SOS emergency alert',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _sending ? null : _sendSOS,
                  borderRadius: BorderRadius.circular(18),
                  child: Ink(
                    width: double.infinity,
                    height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: const LinearGradient(
                        colors: [Color(0xFFE53935), Color(0xFFB71C1C)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withValues(alpha: 0.28),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Center(
                      child: _sending
                          ? const SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.6,
                              ),
                            )
                          : const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'SOS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 3,
                                    height: 1,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Tap to send alert',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  static const Color _mapNavy = Color(0xFF0D1B2A);
  static const Color _sheetNavy = Color(0xFF152536);

  String _sosRequestNumber() {
    final id = _lastRequest?.id ?? '';
    final tail = id.length <= 6 ? id.toUpperCase() : id.substring(id.length - 6).toUpperCase();
    return 'CALSOS-$tail';
  }

  String _clockLabel(DateTime time) {
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  Future<void> _callPhone(String phone) async {
    final uri = Uri.parse('tel:${phone.trim()}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String? _unitPhoneNumber() {
    final info = _dispatchInfo;
    if (info == null) return null;
    for (final key in ['unitPhone', 'contactPhone', 'phone', 'responderPhone']) {
      final value = info[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  void _openCitizenChatSheet() {
    final provider = context.read<RescueProvider>();
    setState(() => _chatSheetOpen = true);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetNavy,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Message rescuer',
                style: TextStyle(
                  color: Colors.grey[300],
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: SOSChatPanel(
                sosId: _lastRequest!.id,
                senderRole: 'citizen',
                senderId: provider.citizenId ?? 'citizen',
                senderDisplayName: provider.citizenName ?? 'Citizen',
                completedAt: null,
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _chatSheetOpen = false);
    });
  }

  Widget _mapCircleButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: const Color(0xFF1E3348),
      shape: const CircleBorder(),
      elevation: 4,
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  Widget _sheetHandle() {
    return Center(
      child: Container(
        width: 42,
        height: 5,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }

  Widget _darkInfoTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Waiting View ──

  Widget _buildWaitingView() {
    return Scaffold(
      backgroundColor: _mapNavy,
      body: Consumer<RescueProvider>(
        builder: (context, provider, _) {
          return Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _incidentTarget(provider) ??
                            provider.currentPosition ??
                            const LatLng(14.6544, 120.9840),
                        initialZoom: 15,
                        interactionOptions: kRescueMapInteractions,
                        keepAlive: true,
                      ),
                      children: [
                        const RescueMapTileLayer(),
                        ...BarangayCoverage.mapLayers(
                          barangayId: provider.citizenBarangayId,
                        ),
                        MarkerLayer(markers: _citizenIncidentMarkers(provider)),
                      ],
                    ),
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8,
                      right: 16,
                      child: Column(
                        children: [
                          _mapCircleButton(
                            icon: Icons.layers,
                            tooltip: 'Map type & details',
                            onPressed: () => showMapLayersSheet(context),
                          ),
                          const SizedBox(height: 10),
                          _mapCircleButton(
                            icon: Icons.crop_free,
                            tooltip: 'Expand map',
                            onPressed: () =>
                                setState(() => _citizenMapFullScreen = true),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(
                  20,
                  12,
                  20,
                  16 + MediaQuery.of(context).padding.bottom,
                ),
                decoration: const BoxDecoration(
                  color: _sheetNavy,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _sheetHandle(),
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        color: Color(0xFFE53935),
                        strokeWidth: 3.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'SOS Sent — Waiting for Responder',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Please stay on the line. Help is on the way.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    _darkInfoTile(
                      icon: Icons.description_outlined,
                      iconColor: const Color(0xFFE53935),
                      label: 'Request number',
                      value: _sosRequestNumber(),
                    ),
                    const SizedBox(height: 10),
                    _darkInfoTile(
                      icon: Icons.phone_outlined,
                      iconColor: const Color(0xFFE53935),
                      label: 'Callback phone',
                      value: _lastRequest!.hasCallbackPhone
                          ? _lastRequest!.callbackPhone!.trim()
                          : 'Not provided',
                    ),
                    if (_lastRequest!.locationIsPinned) ...[
                      const SizedBox(height: 10),
                      Text(
                        _lastRequest!.isProxyReport
                            ? 'Pinned for ${_lastRequest!.reportedForName}'
                            : 'Pinned incident location',
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (_lastRequest!.hasScenePhoto) ...[
                      const SizedBox(height: 10),
                      SosScenePhotoThumb(
                        photoUrl: _lastRequest!.scenePhotoUrl,
                        height: 96,
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (_dispatchInfo == null)
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton.icon(
                          onPressed: () => _showCancelSOSDialog(),
                          icon: const Icon(Icons.close),
                          label: const Text(
                            'Cancel SOS',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFE53935),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Live Tracking View ──

  Widget _buildTrackingView() {
    final unitCallSign = _dispatchInfo?['unitCallSign'] ?? 'Unknown';
    final unitType = _dispatchInfo?['unitType'] ?? 'rescue';
    final dispatchPhase = _dispatchInfo?['phase'] as String?;
    final nextInstruction = _dispatchInfo?['nextInstruction'] as String?;
    final destinationName =
        (_dispatchInfo?['destinationName'] as String?) ?? _dispatchDestinationName;
    final progressEta = _safeInt(_dispatchInfo?['etaMinutes']);
    final progressDistanceM = _safeInt(_dispatchInfo?['distanceMeters']);

    final IconData unitIcon = switch (unitType) {
      'ambulance' => Icons.local_hospital,
      'fireTruck' => Icons.local_fire_department,
      'policeUnit' => Icons.local_police,
      _ => Icons.health_and_safety,
    };
    final (Color statusBg, Color statusIconColor, IconData statusIcon) =
        switch (_liveStatusType) {
      _CitizenLiveStatusType.enRoute => (
          const Color(0xFF1565C0),
          const Color(0xFFBBDEFB),
          Icons.directions_car,
        ),
      _CitizenLiveStatusType.nearby => (
          const Color(0xFFEF6C00),
          const Color(0xFFFFE0B2),
          Icons.near_me,
        ),
      _CitizenLiveStatusType.transporting => (
          const Color(0xFF5E35B1),
          const Color(0xFFD1C4E9),
          Icons.local_hospital,
        ),
      _CitizenLiveStatusType.arrived => (
          const Color(0xFF2E7D32),
          const Color(0xFFC8E6C9),
          Icons.check_circle,
        ),
    };

    String distText = '';
    String etaText = '';
    if (_responderPosition != null) {
      final provider = context.read<RescueProvider>();
      final citizenPos = _incidentTarget(provider);
      if (citizenPos != null) {
        var liveKm = _routeToMe.length >= 2
            ? RouteGeoUtils.remainingDistanceKm(
                _responderPosition!,
                _routeToMe,
              )
            : (_routeDistanceKm > 0
                ? _routeDistanceKm
                : GeoUtils.haversineKm(_responderPosition!, citizenPos));
        liveKm = _finiteOr(liveKm);
        var liveEta = _routeDistanceKm > 0.001 &&
                _routeEtaMinutes > 0 &&
                _routeDistanceKm.isFinite &&
                _routeEtaMinutes.isFinite
            ? _routeEtaMinutes * (liveKm / _routeDistanceKm)
            : liveKm / 0.5;
        liveEta = _finiteOr(liveEta);
        distText = liveKm < 1
            ? '${(liveKm * 1000).round()}m'
            : '${liveKm.toStringAsFixed(1)} km';
        etaText = liveEta < 1
            ? 'Less than 1 min'
            : '${liveEta.round()} min';
      }
    }

    final sosType = _lastRequest?.sosType ?? SOSType.medical;
    final typeColor = _colorForSOSType(sosType);
    final unitPhone = _unitPhoneNumber();
    int? etaMinutes = progressEta;
    if (etaMinutes == null &&
        etaText.endsWith(' min') &&
        !etaText.startsWith('Less')) {
      etaMinutes = int.tryParse(etaText.split(' ').first);
    }
    final arrivingBy = etaMinutes == null
        ? null
        : _clockLabel(DateTime.now().add(Duration(minutes: etaMinutes)));

    return Scaffold(
      backgroundColor: _mapNavy,
      body: Column(
        children: [
          Container(
            color: _mapNavy,
            padding: EdgeInsets.fromLTRB(
              4,
              MediaQuery.of(context).padding.top + 4,
              12,
              8,
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => _confirmBackToMain(context),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Live Tracking',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Responder is on the way',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                _mapCircleButton(
                  icon: Icons.layers,
                  tooltip: 'Map type & details',
                  onPressed: () => showMapLayersSheet(context),
                ),
                const SizedBox(width: 8),
                _mapCircleButton(
                  icon: Icons.crop_free,
                  tooltip: 'Expand map',
                  onPressed: () =>
                      setState(() => _citizenMapFullScreen = true),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Consumer<RescueProvider>(
                  builder: (context, provider, _) {
                    return FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _incidentTarget(provider) ??
                            provider.currentPosition ??
                            _lastRequest!.location,
                        initialZoom: 14,
                        interactionOptions: kRescueMapInteractions,
                        keepAlive: true,
                      ),
                      children: [
                        const RescueMapTileLayer(),
                        ...BarangayCoverage.mapLayers(
                          barangayId: provider.citizenBarangayId,
                        ),
                        if (_routeAhead.length >= 2)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _routeAhead,
                                color: const Color(0xFF64B5F6).withValues(alpha: 0.35),
                                strokeWidth: 12,
                              ),
                              Polyline(
                                points: _routeAhead,
                                color: const Color(0xFF2196F3),
                                strokeWidth: 5,
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            ..._citizenIncidentMarkers(provider),
                            if (_responderPosition != null)
                              Marker(
                                point: _responderPosition!,
                                width: 56,
                                height: 56,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 3),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.green.withValues(alpha: 0.6),
                                        blurRadius: 14,
                                        spreadRadius: 3,
                                      ),
                                    ],
                                  ),
                                  child: Icon(unitIcon, color: Colors.white, size: 26),
                                ),
                              ),
                            if (_dispatchRoutingTo == 'facility' &&
                                _dispatchDestinationPosition != null)
                              Marker(
                                point: _dispatchDestinationPosition!,
                                width: 56,
                                height: 56,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 3),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.red.withValues(alpha: 0.55),
                                        blurRadius: 14,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.local_hospital,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                if (_lastRequest != null)
                  Positioned(
                    left: 16,
                    bottom: 16,
                    child: Material(
                      color: const Color(0xFFE53935),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: () => _showCancelSOSDialog(),
                        borderRadius: BorderRadius.circular(14),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.cancel_outlined, color: Colors.white, size: 18),
                              SizedBox(width: 6),
                              Text(
                                'Cancel SOS',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChatFabWithBadge(
                        sosId: _lastRequest!.id,
                        myRole: 'citizen',
                        suppressNotifications: _chatSheetOpen,
                        onPressed: _openCitizenChatSheet,
                      ),
                      const SizedBox(height: 10),
                      _mapCircleButton(
                        icon: Icons.open_with,
                        tooltip: 'Fit map',
                        onPressed: _fitBothMarkers,
                      ),
                      const SizedBox(height: 10),
                      _mapCircleButton(
                        icon: Icons.my_location,
                        tooltip: 'My location',
                        onPressed: () {
                          final pos =
                              context.read<RescueProvider>().currentPosition;
                          if (pos != null) _mapController.move(pos, 16);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              20,
              10,
              20,
              12 + MediaQuery.of(context).padding.bottom,
            ),
            decoration: const BoxDecoration(
              color: _sheetNavy,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                    ),
                    child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sheetHandle(),
                  const Text(
                    'Help is on the way',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _liveStatusSubtitle ??
                        _liveStatusTitle ??
                        'Responder accepted your SOS',
                    style: const TextStyle(
                      color: Color(0xFF81C784),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: statusBg.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(statusIcon, color: statusIconColor, size: 26),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: typeColor.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  _shortSosLabel(sosType).toUpperCase(),
                                  style: TextStyle(
                                    color: typeColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                unitCallSign.toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                _responderPosition == null
                                    ? 'Locating responder...'
                                    : 'Responding to your location',
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (dispatchPhase != null ||
                      nextInstruction != null ||
                      (destinationName != null && destinationName.isNotEmpty)) ...[
                    const SizedBox(height: 10),
                    if (dispatchPhase != null)
                      Text(
                        'Status: $dispatchPhase',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (destinationName != null && destinationName.isNotEmpty)
                      Text(
                        'Destination: $destinationName',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    if (nextInstruction != null && nextInstruction.isNotEmpty)
                      Text(
                        nextInstruction,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(Icons.schedule, color: Color(0xFF4FC3F7), size: 22),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ETA',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            etaText.isNotEmpty
                                ? etaText.replaceAll(' min', ' min')
                                : (progressEta != null ? '$progressEta min' : '--'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      if (arrivingBy != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'Arriving by',
                              style: TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                            Text(
                              arrivingBy,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        )
                      else if (distText.isNotEmpty || progressDistanceM != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'Distance',
                              style: TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                            Text(
                              distText.isNotEmpty
                                  ? distText
                                  : '${progressDistanceM}m',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (_lastRequest!.hasScenePhoto) ...[
                    const SizedBox(height: 10),
                    SosScenePhotoThumb(
                      photoUrl: _lastRequest!.scenePhotoUrl,
                      height: 80,
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: Material(
                      color: const Color(0xFF2E7D32),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: unitPhone == null
                            ? _openCitizenChatSheet
                            : () => _callPhone(unitPhone),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                unitPhone == null ? Icons.chat : Icons.phone,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 10),
                              Column(
                                children: [
                                  Text(
                                    unitPhone ?? 'Message rescuer',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    unitPhone == null
                                        ? 'Chat is available now'
                                        : 'Tap to call ${_unitTypeLabelForCitizen(unitType.toString()).toLowerCase()}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
        ],
      ),
    );
  }
}
