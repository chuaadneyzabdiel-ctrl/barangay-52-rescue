import 'package:latlong2/latlong.dart';

/// Emergency map layer types (toggle on/off).
enum MapLayerType {
  evacuationRoutes,
  hospitals,
  threeSCenters,
  policeStations,
  fireStations,
  evacuationCenters,
  floodProneAreas,
  landslideProneAreas,
  roadBlockages,
  trafficConditions,
  safeZones,
  emergencyHotlines,
  incidentReports,
  bridgeConditions,
  riverLevels,
  searchRescueLocations,
  supplyPoints,
  hazardZones,
  gpsVictims,
  weatherAlerts,
}

/// Single POI or line for a map layer.
class MapLayerPOI {
  final String id;
  final String name;
  final LatLng position;
  final MapLayerType layerType;
  final String? subtitle;
  final List<LatLng>? polyline; // for routes / areas
  final String? level; // e.g. "Moderate", "High" for flood/traffic
  final String? city;
  final String? facilityType; // hospital | clinic | health_center | lying_in
  final String? ownership; // public | private
  final bool? emergencyCapable;
  final String? address;
  final String? phone;
  final String? openStatusText; // e.g. "Open 24 hours", "Closed - Opens 8 AM"
  final bool? isOpenNow;

  const MapLayerPOI({
    required this.id,
    required this.name,
    required this.position,
    required this.layerType,
    this.subtitle,
    this.polyline,
    this.level,
    this.city,
    this.facilityType,
    this.ownership,
    this.emergencyCapable,
    this.address,
    this.phone,
    this.openStatusText,
    this.isOpenNow,
  });
}
