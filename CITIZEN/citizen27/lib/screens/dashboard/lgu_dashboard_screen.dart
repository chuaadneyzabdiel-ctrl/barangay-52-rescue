import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../models/map_layer_models.dart';
import '../../models/rescue_models.dart';
import '../../models/response_unit_status.dart';
import '../../map/rescue_map_tiles.dart';
import '../../providers/rescue_provider.dart';
import '../../widgets/map_layers_sheet.dart';
import '../../widgets/rescue_map_tile_layer.dart';
import '../../services/map_layer_data_service.dart';
import '../../widgets/sos_chat_panel.dart';
import 'account_center_screen.dart';

/// LGU Command Center web dashboard for monitoring all rescue assets,
/// viewing active SOS requests, and manually tagging hazard zones.
///
/// All data streams in real-time from Firebase.
/// Map can be opened/closed; when closed, real-time elements are hidden.
class LGUDashboardScreen extends StatefulWidget {
  const LGUDashboardScreen({super.key});

  @override
  State<LGUDashboardScreen> createState() => _LGUDashboardScreenState();
}

class _LGUDashboardScreenState extends State<LGUDashboardScreen> {
  final MapController _mapController = MapController();
  bool _isAddingHazard = false;
  final List<LatLng> _hazardPolygonPoints = [];
  HazardType _selectedHazardType = HazardType.flood;
  final _hazardNameController = TextEditingController();
  /// When false, command center map is hidden (no real-time elements shown).
  bool _commandMapOpen = false;
  /// Map flex (desktop): higher = larger map. Clamped 1..8.
  int _mapFlex = 3;
  bool _mapFullScreen = false;

  static const _caloocanCenter = LatLng(14.6990, 121.0200);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final provider = context.read<RescueProvider>();
        provider.startFirebaseListeners();
        await provider.refreshLocationStatus();
        provider.initLocation();
        final count = await provider.markOldSOSAsCompleted(olderThan: const Duration(hours: 2));
        if (mounted && count > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$count old SOS marked as completed.')),
          );
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _hazardNameController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _confirmBackToMain(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave command center?'),
        content: const Text(
          'Are you sure you want to go back to the main screen?',
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
      await context.read<RescueProvider>().logDashboardExit(
            role: 'lguAdmin',
            screen: 'lgu_dashboard',
          );
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  static const _compactBreakpoint = 800.0;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < _compactBreakpoint;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _confirmBackToMain(context),
        ),
        title: const Text('LGU Command Center'),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AccountCenterScreen(),
                ),
              );
            },
            tooltip: 'Account Center',
          ),
        ],
      ),
      body: Stack(
        children: [
          isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildCompactStatsStrip(),
                    Expanded(
                      child: _commandMapOpen
                          ? (_mapFullScreen
                              ? const SizedBox.shrink()
                              : _buildMapArea())
                          : _buildMapPlaceholder(),
                    ),
                    _buildCompactTabbedPanel(),
                  ],
                )
              : Row(
                  children: [
                    _buildSidebar(),
                    _buildResizeBar(
                      onDrag: (dx) {
                        setState(() {
                          _mapFlex =
                              (_mapFlex + (dx > 0 ? -1 : 1)).clamp(1, 8);
                        });
                      },
                    ),
                    Expanded(
                      flex: _mapFlex,
                      child: _commandMapOpen
                          ? (_mapFullScreen
                              ? const SizedBox.shrink()
                              : _buildMapArea())
                          : _buildMapPlaceholder(),
                    ),
                    _buildRightPanel(),
                  ],
                ),
          if (_mapFullScreen && _commandMapOpen) _buildFullScreenMapOverlay(),
        ],
      ),
    );
  }

  Widget _buildFullScreenMapOverlay() {
    return Material(
      color: const Color(0xFF0D1B2A),
      child: Stack(
        children: [
          Consumer<RescueProvider>(
            builder: (context, provider, _) => _buildMapLayers(provider),
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
                      onPressed: () => setState(() => _mapFullScreen = false),
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
        ],
      ),
    );
  }

  Widget _buildMapLayers(RescueProvider provider) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _caloocanCenter,
        initialZoom: 13,
        interactionOptions: kRescueMapInteractions,
        keepAlive: true,
        onTap: _isAddingHazard
            ? (_, point) => _onMapTapForHazard(point)
            : null,
      ),
      children: [
        const RescueMapTileLayer(),
        ...MapLayerType.values.expand((type) {
          final pois = MapLayerDataService.getLayerData(type);
          final widgets = <Widget>[];
          final markerList = <Marker>[];
          for (final poi in pois) {
            if (poi.polyline != null && poi.polyline!.length >= 2) {
              widgets.add(
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: poi.polyline!,
                      color: _layerColor(type).withValues(alpha: 0.8),
                      strokeWidth: 6,
                    ),
                  ],
                ),
              );
            } else {
              markerList.add(
                Marker(
                  point: poi.position,
                  width: 36,
                  height: 36,
                  child: Tooltip(
                    message:
                        '${poi.name}${poi.subtitle != null ? '\n${poi.subtitle}' : ''}',
                    child: Icon(
                      _layerIcon(type),
                      color: _layerColor(type),
                      size: 28,
                    ),
                  ),
                ),
              );
            }
          }
          if (markerList.isNotEmpty) {
            widgets.add(MarkerLayer(markers: markerList));
          }
          return widgets;
        }),
        PolygonLayer(
          polygons: [
            ...provider.hazardZones
                .where((h) => h.isActive)
                .map((h) => Polygon(
                      points: h.polygon,
                      color: _hazardColor(h.type).withValues(alpha: 0.25),
                      borderColor: _hazardColor(h.type),
                      borderStrokeWidth: 2,
                    )),
            if (_hazardPolygonPoints.length >= 3)
              Polygon(
                points: _hazardPolygonPoints,
                color: Colors.yellow.withValues(alpha: 0.2),
                borderColor: Colors.yellow,
                borderStrokeWidth: 2,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            if (provider.currentPosition != null)
              Marker(
                point: provider.currentPosition!,
                width: 48,
                height: 48,
                child: Tooltip(
                  message: 'You (Command Center)',
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF5C6BC0),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.person_pin_circle,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
            ...provider.rescueUnits.map((unit) => Marker(
                  point: unit.position,
                  width: 44,
                  height: 44,
                  child: Tooltip(
                    message:
                        '${unit.callSign}\n${_unitTypeLabel(unit.type)} • ${_unitCommandStatus(provider, unit, true)}',
                    child: Container(
                      decoration: BoxDecoration(
                        color: _unitReadinessColor(provider, unit, true),
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: Colors.white, width: 2),
                      ),
                      child: Icon(
                        _unitIcon(unit.type),
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                )),
            ...provider.activeSosRequests.map((sos) => Marker(
                  point: sos.location,
                  width: 44,
                  height: 44,
                  child: Tooltip(
                    message:
                        'SOS - ${sos.citizenName}\n${sos.priority.name.toUpperCase()}',
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.sos,
                          color: Colors.white, size: 20),
                    ),
                  ),
                )),
            ...provider.relocationSuggestions.entries.map(
                (e) => Marker(
                  point: e.value.position,
                  width: 36,
                  height: 36,
                  child: Tooltip(
                    message:
                        'Suggested: ${e.value.name}\nFor: ${e.key}',
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.swap_horiz,
                          color: Colors.white, size: 16),
                    ),
                  ),
                )),
            ...List.generate(
              _hazardPolygonPoints.length,
              (i) => Marker(
                point: _hazardPolygonPoints[i],
                width: 20,
                height: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.yellow,
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: Colors.black, width: 1),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCompactStatsStrip() {
    return Consumer<RescueProvider>(
      builder: (context, provider, _) {
        final units = provider.unitsForDisplay;
        final available = units
            .where((u) =>
                provider.isUnitOnline(u.id) &&
                u.isAvailable &&
                provider.canResponseUnitTakeSos(u.id))
            .length;
        final enRoute = units
            .where((u) =>
                provider.isUnitOnline(u.id) && u.status == UnitStatus.enRoute)
            .length;
        final completed = provider.sosHistory
            .where((s) =>
                s.status == SOSStatus.completed && s.completedAt != null)
            .toList();
        double avgResponse = 0;
        if (completed.isNotEmpty) {
          final totalSec = completed.fold<int>(
            0,
            (sum, s) => sum +
                s.completedAt!
                    .difference(s.createdAt)
                    .inSeconds
                    .clamp(0, 24 * 60 * 60),
          );
          avgResponse = (totalSec / completed.length) / 60.0;
        }
        final hazards = provider.hazardZones.where((h) => h.isActive).length;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1B2838),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildStatChip(
                        'SOS',
                        provider.activeSosRequests.length.toString(),
                        Colors.red,
                        Icons.sos,
                      ),
                      const SizedBox(width: 8),
                      _buildStatChip(
                        'Units',
                        available.toString(),
                        Colors.green,
                        Icons.local_shipping,
                      ),
                      const SizedBox(width: 8),
                      _buildStatChip(
                        'En Route',
                        enRoute.toString(),
                        Colors.blue,
                        Icons.directions_car,
                      ),
                      const SizedBox(width: 8),
                      _buildStatChip(
                        'Avg (min)',
                        avgResponse.toStringAsFixed(1),
                        Colors.cyan,
                        Icons.timer,
                      ),
                      const SizedBox(width: 8),
                      _buildStatChip(
                        'Hazards',
                        hazards.toString(),
                        Colors.amber,
                        Icons.warning,
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: () => showMapLayersSheet(context),
                        icon: const Icon(Icons.layers, size: 20),
                        tooltip: 'Map type & details',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white12,
                          foregroundColor: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: () =>
                    setState(() => _commandMapOpen = !_commandMapOpen),
                icon: Icon(
                  _commandMapOpen ? Icons.map : Icons.map_outlined,
                  color: Colors.white70,
                ),
                tooltip: _commandMapOpen ? 'Hide map' : 'Show map',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatChip(
    String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactTabbedPanel() {
    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: const Color(0xFF1B2838),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              indicatorColor: const Color(0xFF4FC3F7),
              tabs: const [
                Tab(text: 'Active SOS'),
                Tab(text: 'History'),
                Tab(text: 'Hazards'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildCompactTabList(
                    builder: (p) => p.activeSosRequests.isEmpty
                        ? const Center(
                            child: Text('No active SOS',
                                style: TextStyle(color: Colors.white54)),
                          )
                        : ListView.builder(
                            itemCount: p.activeSosRequests.length,
                            itemBuilder: (_, i) =>
                                _buildSOSTile(p.activeSosRequests[i]),
                          ),
                  ),
                  _buildCompactTabList(
                    builder: (p) => p.sosHistory.isEmpty
                        ? const Center(
                            child: Text('No history',
                                style: TextStyle(color: Colors.white54)),
                          )
                        : Builder(
                            builder: (_) {
                              final list = p.sosHistory.take(15).toList();
                              return ListView.builder(
                                itemCount: list.length,
                                itemBuilder: (_, i) =>
                                    _buildSOSHistoryTile(list[i]),
                              );
                            },
                          ),
                  ),
                  _buildCompactTabList(
                    builder: (p) => p.hazardZones.isEmpty
                        ? const Center(
                            child: Text('No hazards',
                                style: TextStyle(color: Colors.white54)),
                          )
                        : ListView.builder(
                            itemCount: p.hazardZones.length,
                            itemBuilder: (_, i) =>
                                _buildHazardTile(p.hazardZones[i]),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactTabList({
    required Widget Function(RescueProvider) builder,
  }) {
    return Consumer<RescueProvider>(
      builder: (context, provider, _) => builder(provider),
    );
  }

  Widget _buildResizeBar({required void Function(double dx) onDrag}) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Container(
          width: 6,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 2,
              color: Colors.white24,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMapPlaceholder() {
    return Container(
      color: const Color(0xFF1B2838),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.map_outlined,
            size: 64,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            'Command Center Map is closed',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Open the map to view real-time SOS, units, and hazards',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => setState(() => _commandMapOpen = true),
            icon: const Icon(Icons.map),
            label: const Text('Open Command Center Map'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B3A5C),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: const Color(0xFF1B2838),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            decoration: BoxDecoration(
              color: const Color(0xFF1B3A5C),
              borderRadius: const BorderRadius.only(
                bottomRight: Radius.circular(12),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.emergency, color: Colors.white70, size: 22),
                    SizedBox(width: 10),
                    Text(
                      'CALOOCAN RESCUE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6),
                Text(
                  'Command Center',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Consumer<RescueProvider>(
              builder: (context, provider, _) {
                final units = provider.unitsForDisplay;
                final available = units
                    .where((u) =>
                        provider.isUnitOnline(u.id) &&
                        u.isAvailable &&
                        provider.canResponseUnitTakeSos(u.id))
                    .length;
                final enRoute = units
                    .where((u) =>
                        provider.isUnitOnline(u.id) &&
                        u.status == UnitStatus.enRoute)
                    .length;
                final onScene = units
                    .where((u) =>
                        provider.isUnitOnline(u.id) &&
                        u.status == UnitStatus.onScene)
                    .length;
                final busy = units
                    .where((u) =>
                        provider.isUnitOnline(u.id) &&
                        !u.isAvailable &&
                        u.status != UnitStatus.enRoute &&
                        u.status != UnitStatus.onScene)
                    .length;
                // Basic KPI: average response time (completed SOS) in minutes.
                final completed = provider.sosHistory
                    .where((s) => s.status == SOSStatus.completed && s.completedAt != null)
                    .toList();
                double avgResponseMinutes = 0;
                if (completed.isNotEmpty) {
                  final totalSeconds = completed.fold<int>(
                    0,
                    (sum, s) =>
                        sum +
                        s.completedAt!
                            .difference(s.createdAt)
                            .inSeconds
                            .clamp(0, 24 * 60 * 60),
                  );
                  avgResponseMinutes =
                      (totalSeconds / completed.length) / 60.0;
                }
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _buildStatCard(
                      'Active SOS',
                      provider.activeSosRequests.length.toString(),
                      Colors.red,
                      Icons.sos,
                    ),
                    _buildStatCard(
                      'Avg Response (min)',
                      avgResponseMinutes.toStringAsFixed(1),
                      Colors.cyan,
                      Icons.timer,
                    ),
                    _buildStatCard(
                      'Units Available',
                      available.toString(),
                      Colors.green,
                      Icons.local_shipping,
                    ),
                    _buildStatCard(
                      'En Route',
                      enRoute.toString(),
                      Colors.blue,
                      Icons.directions_car,
                    ),
                    _buildStatCard(
                      'On Scene / Busy',
                      (onScene + busy).toString(),
                      Colors.orange,
                      Icons.directions_car,
                    ),
                    _buildStatCard(
                      'Active Hazards',
                      provider.hazardZones
                          .where((h) => h.isActive)
                          .length
                          .toString(),
                      Colors.amber,
                      Icons.warning,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final count = await provider.markOldSOSAsCompleted(
                            olderThan: const Duration(hours: 2),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(count > 0
                                  ? '$count old SOS marked as completed.'
                                  : 'No old SOS to mark.'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.check_circle_outline, size: 18),
                        label: const Text('Mark old SOS completed'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                    ),
                    const Divider(color: Colors.white24, height: 32),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Row(
                        children: [
                          const Text(
                            'COMMAND MAP',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () =>
                                setState(() => _commandMapOpen = !_commandMapOpen),
                            icon: Icon(
                              _commandMapOpen ? Icons.close : Icons.map,
                              size: 18,
                              color: Colors.white70,
                            ),
                            label: Text(
                              _commandMapOpen ? 'Close Map' : 'Open Map',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'RESCUE UNITS',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: const [
                          _StatusDot(label: 'Available', color: Colors.green),
                          _StatusDot(label: 'En Route', color: Colors.blue),
                          _StatusDot(
                              label: 'On Scene / Busy', color: Colors.orange),
                          _StatusDot(
                              label: 'Maintenance / Out of service',
                              color: Colors.amber),
                          _StatusDot(label: 'Offline', color: Colors.grey),
                        ],
                      ),
                    ),
                    ...provider.unitsForDisplay
                        .map((u) => _buildUnitTile(provider, u)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapArea() {
    return Consumer<RescueProvider>(
      builder: (context, provider, _) {
        return Stack(
          children: [
            _buildMapLayers(provider),
            Positioned(
              top: 16,
              left: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Card(
                    color: const Color(0xFF1B2838).withValues(alpha: 0.95),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Text(
                        _isAddingHazard
                            ? 'Tap map to define hazard zone polygon (${_hazardPolygonPoints.length} points)'
                            : 'Caloocan City - Live Operations Map',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => setState(() => _mapFullScreen = true),
                    icon: const Icon(Icons.fullscreen),
                    tooltip: 'Expand map',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => showMapLayersSheet(context),
                    icon: const Icon(Icons.layers),
                    tooltip: 'Map type & details',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => setState(() => _commandMapOpen = false),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close Command Center Map',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              bottom: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.extended(
                    heroTag: 'hazard',
                    onPressed: _toggleHazardMode,
                    backgroundColor: _isAddingHazard
                        ? Colors.orange
                        : const Color(0xFF1B3A5C),
                    icon: Icon(
                      _isAddingHazard ? Icons.check : Icons.warning_amber,
                    ),
                    label: Text(
                      _isAddingHazard
                          ? 'Finish Hazard'
                          : 'Tag Hazard Zone',
                    ),
                  ),
                  if (_isAddingHazard &&
                      _hazardPolygonPoints.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'undo',
                      onPressed: () {
                        setState(() => _hazardPolygonPoints.removeLast());
                      },
                      backgroundColor: Colors.red,
                      child: const Icon(Icons.undo),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRightPanel() {
    return Container(
      width: 320,
      color: const Color(0xFF1B2838),
      child: Consumer<RescueProvider>(
        builder: (context, provider, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader('ACTIVE SOS', Icons.sos),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    if (provider.activeSosRequests.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('No active SOS on map',
                            style: TextStyle(color: Colors.grey[600])),
                      )
                    else
                      ...provider.activeSosRequests.map(_buildSOSTile),
                    const SizedBox(height: 16),
                    _buildSectionHeader('SOS HISTORY LOGS', Icons.history),
                    if (provider.sosHistory.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('No history',
                            style: TextStyle(color: Colors.grey[600])),
                      )
                    else
                      ...provider.sosHistory.map(_buildSOSHistoryTile),
                  ],
                ),
              ),
              _buildSectionHeader('HAZARD ZONES', Icons.warning_amber),
              Expanded(
                child: provider.hazardZones.isEmpty
                    ? Center(
                        child: Text('No hazard zones tagged',
                            style: TextStyle(color: Colors.grey[600])),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: provider.hazardZones.length,
                        itemBuilder: (context, i) {
                          return _buildHazardTile(
                              provider.hazardZones[i]);
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: _buildRelocationSuggestions(provider),
              ),
            ],
          );
        },
      ),
    );
  }

  // --- Hazard zone tagging ---

  void _onMapTapForHazard(LatLng point) {
    setState(() => _hazardPolygonPoints.add(point));
  }

  void _toggleHazardMode() {
    if (_isAddingHazard) {
      if (_hazardPolygonPoints.length >= 3) {
        _showHazardDialog();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Need at least 3 points for a zone')),
        );
      }
    } else {
      setState(() {
        _isAddingHazard = true;
        _hazardPolygonPoints.clear();
      });
    }
  }

  void _showHazardDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Hazard Zone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _hazardNameController,
              decoration: const InputDecoration(
                labelText: 'Zone Name',
                hintText: 'e.g., Deparo Flood Area',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<HazardType>(
              value: _selectedHazardType,
              decoration:
                  const InputDecoration(labelText: 'Hazard Type'),
              items: HazardType.values.map((t) {
                return DropdownMenuItem(
                    value: t, child: Text(t.name.toUpperCase()));
              }).toList(),
              onChanged: (v) {
                if (v != null) setState(() => _selectedHazardType = v);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _isAddingHazard = false;
                _hazardPolygonPoints.clear();
              });
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final provider = context.read<RescueProvider>();
              await provider.addHazardZone(HazardZone(
                id: 'hz-${DateTime.now().millisecondsSinceEpoch}',
                name: _hazardNameController.text.isNotEmpty
                    ? _hazardNameController.text
                    : 'Hazard Zone',
                type: _selectedHazardType,
                polygon: List.from(_hazardPolygonPoints),
                severityWeight: 50.0,
                reportedAt: DateTime.now(),
              ));
              _hazardNameController.clear();
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {
                _isAddingHazard = false;
                _hazardPolygonPoints.clear();
              });
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  IconData _layerIcon(MapLayerType type) {
    return switch (type) {
      MapLayerType.evacuationRoutes => Icons.route,
      MapLayerType.hospitals => Icons.local_hospital,
      MapLayerType.threeSCenters => Icons.apartment,
      MapLayerType.policeStations => Icons.local_police,
      MapLayerType.fireStations => Icons.local_fire_department,
      MapLayerType.evacuationCenters => Icons.people,
      MapLayerType.floodProneAreas => Icons.water,
      MapLayerType.landslideProneAreas => Icons.terrain,
      MapLayerType.roadBlockages => Icons.block,
      MapLayerType.trafficConditions => Icons.traffic,
      MapLayerType.safeZones => Icons.shield,
      MapLayerType.emergencyHotlines => Icons.phone,
      MapLayerType.incidentReports => Icons.report,
      MapLayerType.bridgeConditions => Icons.account_balance,
      MapLayerType.riverLevels => Icons.water_drop,
      MapLayerType.searchRescueLocations => Icons.search,
      MapLayerType.supplyPoints => Icons.inventory_2,
      MapLayerType.hazardZones => Icons.warning,
      MapLayerType.gpsVictims => Icons.location_on,
      MapLayerType.weatherAlerts => Icons.cloud,
    };
  }

  Color _layerColor(MapLayerType type) {
    return switch (type) {
      MapLayerType.evacuationRoutes => Colors.purple,
      MapLayerType.hospitals => Colors.red,
      MapLayerType.threeSCenters => Colors.deepPurple,
      MapLayerType.policeStations => Colors.blue,
      MapLayerType.fireStations => Colors.orange,
      MapLayerType.evacuationCenters => Colors.green,
      MapLayerType.floodProneAreas => Colors.blue.shade700,
      MapLayerType.landslideProneAreas => Colors.brown,
      MapLayerType.roadBlockages => Colors.red.shade900,
      MapLayerType.trafficConditions => Colors.amber,
      MapLayerType.safeZones => Colors.green.shade700,
      MapLayerType.emergencyHotlines => Colors.teal,
      MapLayerType.incidentReports => Colors.orange,
      MapLayerType.bridgeConditions => Colors.indigo,
      MapLayerType.riverLevels => Colors.cyan,
      MapLayerType.searchRescueLocations => Colors.deepOrange,
      MapLayerType.supplyPoints => Colors.lime,
      MapLayerType.hazardZones => Colors.red,
      MapLayerType.gpsVictims => Colors.pink,
      MapLayerType.weatherAlerts => Colors.lightBlue,
    };
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

  // --- UI builders ---

  Widget _buildStatCard(
      String title, String value, Color color, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: color,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B3A5C),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnitTile(RescueProvider provider, RescueUnit unit) {
    final isOnline = provider.isUnitOnline(unit.id);
    final color = _unitReadinessColor(provider, unit, isOnline);
    return ListTile(
      dense: true,
      leading: Icon(
        _unitIcon(unit.type),
        color: color,
        size: 22,
      ),
      title: Text(unit.callSign,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      subtitle: Text(
        _unitCommandStatus(provider, unit, isOnline),
        style: TextStyle(
          color: color,
          fontSize: 11,
        ),
      ),
      onTap: isOnline ? () => _mapController.move(unit.position, 15) : null,
    );
  }

  void _showLGUChat(BuildContext context, SOSRequest sos) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B2838),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
                'Chat: ${sos.citizenName} (LGU view only)',
                style: TextStyle(
                  color: Colors.grey[300],
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: SOSChatPanel(
                sosId: sos.id,
                senderRole: 'lgu',
                senderId: 'lgu',
                senderDisplayName: 'LGU',
                completedAt: sos.completedAt,
                readOnly: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSOSTile(SOSRequest sos) {
    return Card(
      color: Colors.red.withValues(alpha: 0.15),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.sos, color: Colors.red, size: 20),
        title: Text(sos.citizenName,
            style: const TextStyle(color: Colors.white, fontSize: 13)),
        subtitle: Text(
          '${sos.priority.name.toUpperCase()} | ${sos.status.name}',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.chat_bubble_outline, size: 20, color: Colors.white70),
          onPressed: () => _showLGUChat(context, sos),
          tooltip: 'View messages',
        ),
        onTap: () async {
          // Always move the map first so the LGU can see where this SOS is.
          _mapController.move(sos.location, 16);

          // Allow LGU to mark the SOS as completed directly from the list.
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Mark SOS as completed?'),
              content: Text(
                'Mark SOS for ${sos.citizenName} as completed and remove it from the active map?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Mark completed'),
                ),
              ],
            ),
          );

          if (confirmed == true) {
            final provider = context.read<RescueProvider>();
            await provider.completeSOS(sos);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('SOS marked as completed.'),
                backgroundColor: Colors.green,
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildSOSHistoryTile(SOSRequest sos) {
    final completed = sos.status == SOSStatus.completed;
    final df = DateFormat('MMM d, yyyy • h:mm a');
    final created = df.format(sos.createdAt.toLocal());
    final ended = sos.completedAt != null
        ? df.format(sos.completedAt!.toLocal())
        : '—';
    return Card(
      color: Colors.grey.withValues(alpha: 0.1),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(
          completed ? Icons.check_circle : Icons.cancel,
          color: completed ? Colors.green : Colors.grey,
          size: 20,
        ),
        title: Text(sos.citizenName,
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        subtitle: Text(
          'Created: $created\nEnded: $ended\n${sos.status.name} • ${sos.priority.name}',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.chat_bubble_outline, size: 20, color: Colors.white54),
          onPressed: () => _showLGUChat(context, sos),
          tooltip: 'View messages',
        ),
      ),
    );
  }

  Widget _buildHazardTile(HazardZone hazard) {
    return Card(
      color: _hazardColor(hazard.type).withValues(alpha: 0.15),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.warning,
            color: _hazardColor(hazard.type), size: 20),
        title: Text(hazard.name,
            style: const TextStyle(color: Colors.white, fontSize: 13)),
        subtitle: Text(
          '${hazard.type.name.toUpperCase()} | ${hazard.isActive ? "ACTIVE" : "RESOLVED"}',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        trailing: hazard.isActive
            ? IconButton(
                icon: const Icon(Icons.check_circle_outline,
                    color: Colors.green, size: 20),
                onPressed: () {
                  context
                      .read<RescueProvider>()
                      .resolveHazardZone(hazard.id);
                },
                tooltip: 'Mark Resolved',
              )
            : null,
      ),
    );
  }

  Widget _buildRelocationSuggestions(RescueProvider provider) {
    if (provider.relocationSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'RELOCATION SUGGESTIONS',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        ...provider.relocationSuggestions.entries.map((e) {
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.swap_horiz,
                    color: Colors.blue, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${e.key} → ${e.value.name}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  IconData _unitIcon(UnitType type) {
    return switch (type) {
      UnitType.ambulance => Icons.local_hospital,
      UnitType.fireTruck => Icons.local_fire_department,
      UnitType.policeUnit => Icons.local_police,
      UnitType.rescue => Icons.health_and_safety,
    };
  }

  String _unitTypeLabel(UnitType type) {
    return switch (type) {
      UnitType.ambulance => 'Ambulance',
      UnitType.fireTruck => 'Fire truck',
      UnitType.policeUnit => 'Police',
      UnitType.rescue => 'Barangay Tanod',
    };
  }

  Color _unitReadinessColor(
    RescueProvider provider,
    RescueUnit unit,
    bool isOnline,
  ) {
    final readiness = provider.responseUnitStatusForUnit(unit.id);
    if (!readiness.canTakeSos) {
      switch (readiness) {
        case ResponseUnitStatus.underMaintenance:
          return Colors.amber;
        case ResponseUnitStatus.disabled:
          return Colors.redAccent;
        case ResponseUnitStatus.outOfService:
        case ResponseUnitStatus.inService:
          return Colors.orangeAccent;
      }
    }
    if (!isOnline) return Colors.grey;
    if (unit.status == UnitStatus.enRoute) return Colors.blue;
    if (unit.isAvailable) return Colors.green;
    return Colors.orange;
  }

  String _unitCommandStatus(
    RescueProvider provider,
    RescueUnit unit,
    bool isOnline,
  ) {
    final readiness = provider.responseUnitStatusForUnit(unit.id);
    if (!readiness.canTakeSos) {
      final label = readiness.label.toUpperCase();
      return isOnline ? label : '$label • OFFLINE';
    }
    return isOnline ? _statusLabel(unit.status) : 'OFFLINE';
  }

  String _statusLabel(UnitStatus status) {
    switch (status) {
      case UnitStatus.idle:
        return 'AVAILABLE';
      case UnitStatus.enRoute:
        return 'EN ROUTE';
      case UnitStatus.onScene:
        return 'ON SCENE (BUSY)';
      case UnitStatus.returning:
        return 'RETURNING TO BASE';
      case UnitStatus.dispatched:
        return 'BUSY';
    }
  }
}

class _StatusDot extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusDot({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }
}
