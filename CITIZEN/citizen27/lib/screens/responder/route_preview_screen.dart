import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../map/rescue_map_tiles.dart';
import '../../widgets/map_layers_sheet.dart';
import '../../widgets/rescue_map_tile_layer.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_provider.dart';
import '../map_navigation_screen.dart';

/// Shows route options to the SOS location before the rescuer starts navigation.
/// Rescuer can tap an alternate route to select it, then Start Navigation.
class RoutePreviewScreen extends StatelessWidget {
  final SOSRequest sosRequest;
  final RescueUnit responderUnit;

  const RoutePreviewScreen({
    super.key,
    required this.sosRequest,
    required this.responderUnit,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
        title: const Text('Route to SOS'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.layers),
            tooltip: 'Map type & details',
            onPressed: () => showMapLayersSheet(context),
          ),
        ],
      ),
      body: Consumer<RescueProvider>(
        builder: (context, provider, _) {
          final driverPos = provider.currentPosition ?? responderUnit.position;
          final allRoutes = <List<LatLng>>[
            if (provider.osrmRoute.length >= 2) provider.osrmRoute,
            ...provider.osrmAlternates.where((r) => r.length >= 2),
          ];
          final hasRoutes = allRoutes.isNotEmpty;

          return Column(
            children: [
              Expanded(
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: sosRequest.location,
                    initialZoom: 14,
                    interactionOptions: kRescueMapInteractions,
                    keepAlive: true,
                  ),
                  children: [
                    const RescueMapTileLayer(),
                    // Alternate routes (lighter)
                    ...allRoutes.asMap().entries.skip(1).map((e) {
                      final idx = e.key;
                      final routeColor = idx == 1
                          ? Colors.orange
                          : Colors.green.shade700;
                      return PolylineLayer(
                        polylines: [
                          Polyline(
                            points: e.value,
                            color: routeColor.withValues(alpha: 0.7),
                            strokeWidth: 6,
                          ),
                        ],
                      );
                    }),
                    // Primary route (thick blue)
                    if (provider.osrmRoute.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: provider.osrmRoute,
                            color: const Color(0xFF1565C0),
                            strokeWidth: 10,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: sosRequest.location,
                          width: 48,
                          height: 48,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: Colors.white, width: 3),
                            ),
                            child:
                                const Icon(Icons.sos, color: Colors.white, size: 24),
                          ),
                        ),
                        Marker(
                          point: driverPos,
                          width: 48,
                          height: 48,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: Colors.white, width: 3),
                            ),
                            child: const Icon(Icons.navigation,
                                color: Colors.white, size: 24),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: const Color(0xFF1B2838),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasRoutes)
                      Text(
                        '${provider.osrmEtaMinutes.toStringAsFixed(1)} min • ${provider.osrmDistanceKm.toStringAsFixed(1)} km',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (allRoutes.length > 1) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Tap a route to select it:',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: List.generate(allRoutes.length, (i) {
                            final isPrimary = i == 0;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilterChip(
                                label: Text(
                                  'Route ${i + 1}${isPrimary ? ' (selected)' : ''}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                selected: isPrimary,
                                onSelected: isPrimary
                                    ? null
                                    : (_) => provider.selectRouteByIndex(i),
                                selectedColor: const Color(0xFF1565C0),
                                checkmarkColor: Colors.white,
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MapNavigationScreen(
                              sosRequest: sosRequest,
                              responderUnit: responderUnit,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.navigation),
                      label: const Text('Start Navigation'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2ECC71),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
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
}
