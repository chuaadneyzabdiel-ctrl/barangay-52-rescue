import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Reverse-geocodes GPS to a street address via OpenStreetMap Nominatim (no API key).
class ReverseGeocodingService {
  ReverseGeocodingService._();
  static final ReverseGeocodingService instance = ReverseGeocodingService._();

  static const _endpoint = 'https://nominatim.openstreetmap.org/reverse';

  final http.Client _client = http.Client();
  final Map<String, String> _cache = {};
  DateTime? _lastRequest;
  Future<void> _gate = Future.value();

  static String coordinatesLabel(LatLng point) =>
      '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';

  String _cacheKey(LatLng point) =>
      '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}';

  /// Human-readable address, or coordinates if lookup fails.
  Future<String> addressFor(LatLng point) {
    final key = _cacheKey(point);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);

    _gate = _gate.then((_) => _lookup(point, key));
    return _gate.then((_) => _cache[key] ?? coordinatesLabel(point));
  }

  Future<void> _lookup(LatLng point, String key) async {
    if (_cache.containsKey(key)) return;
    if (_lastRequest != null) {
      final wait = const Duration(milliseconds: 1100) -
          DateTime.now().difference(_lastRequest!);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
    try {
      final uri = Uri.parse(_endpoint).replace(queryParameters: {
        'lat': '${point.latitude}',
        'lon': '${point.longitude}',
        'format': 'jsonv2',
        'zoom': '18',
        'addressdetails': '1',
      });
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent': 'CaloocanRescue/1.0 (com.caloocan.rescue)',
              'Accept-Language': 'en-PH,en,fil',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        _cache[key] = coordinatesLabel(point);
        return;
      }
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) {
        _cache[key] = coordinatesLabel(point);
        return;
      }
      final formatted = _formatAddress(json);
      _cache[key] =
          formatted.isNotEmpty ? formatted : coordinatesLabel(point);
    } catch (_) {
      _cache[key] = coordinatesLabel(point);
    }
  }

  String _formatAddress(Map<String, dynamic> json) {
    final raw = json['address'];
    if (raw is Map) {
      final a = Map<String, dynamic>.from(raw);
      final roadBits = <String>[];
      final house = a['house_number']?.toString().trim();
      final road = a['road']?.toString().trim();
      if (house != null && house.isNotEmpty) roadBits.add(house);
      if (road != null && road.isNotEmpty) roadBits.add(road);
      final parts = <String>[];
      if (roadBits.isNotEmpty) parts.add(roadBits.join(' '));
      for (final key in [
        'neighbourhood',
        'suburb',
        'village',
        'quarter',
        'city_district',
        'city',
        'municipality',
        'town',
      ]) {
        final v = a[key]?.toString().trim();
        if (v != null && v.isNotEmpty && !parts.contains(v)) parts.add(v);
      }
      if (parts.isNotEmpty) return parts.join(', ');
    }
    final display = json['display_name']?.toString().trim();
    return display ?? '';
  }
}
