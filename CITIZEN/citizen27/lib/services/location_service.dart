import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Result of checking whether location can be used for accurate tracking.
class LocationStatus {
  final bool serviceEnabled;
  final bool permissionGranted;
  final bool canTrack;

  const LocationStatus({
    required this.serviceEnabled,
    required this.permissionGranted,
    required this.canTrack,
  });

  bool get needsPrompt => !canTrack;
}

/// Wraps [Geolocator] to provide a reactive GPS stream for live tracking.
/// Uses best accuracy and frequent updates for accurate user/rescuer location.
class LocationService {
  StreamSubscription<Position>? _positionSub;
  final _controller = StreamController<LatLng>.broadcast();
  Position? _lastPosition;

  Stream<LatLng> get positionStream => _controller.stream;

  /// Last reported speed in m/s. Null if unknown or not yet available.
  double? get lastSpeedMps => _lastPosition?.speed;

  /// GPS course in degrees (0–360), when available. Some devices report -1 when invalid.
  double? get lastHeadingDeg {
    final h = _lastPosition?.heading;
    if (h == null || h < 0) return null;
    return h % 360.0;
  }

  /// Check if location is enabled and permission granted.
  Future<LocationStatus> getLocationStatus() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    final permissionGranted = permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
    return LocationStatus(
      serviceEnabled: serviceEnabled,
      permissionGranted: permissionGranted,
      canTrack: serviceEnabled && permissionGranted,
    );
  }

  /// Opens the device location settings so the user can turn on location.
  Future<bool> openLocationSettings() async {
    return Geolocator.openLocationSettings();
  }

  /// Opens app settings (e.g. to grant location permission).
  Future<bool> openAppSettings() async {
    return Geolocator.openAppSettings();
  }

  Future<bool> requestPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;

    return true;
  }

  Future<LatLng?> getCurrentPosition() async {
    final granted = await requestPermission();
    if (!granted) return null;

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
      ),
    );
    _lastPosition = pos;
    return LatLng(pos.latitude, pos.longitude);
  }

  /// Start tracking with best accuracy and frequent updates for accurate live location.
  void startTracking({
    int distanceFilterMeters = 5,
    LocationAccuracy accuracy = LocationAccuracy.best,
  }) {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilterMeters,
      ),
    ).listen(
      (pos) {
        _lastPosition = pos;
        _controller.add(LatLng(pos.latitude, pos.longitude));
      },
      onError: (e) => _controller.addError(e),
    );
  }

  void stopTracking() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  void dispose() {
    stopTracking();
    _controller.close();
  }
}
