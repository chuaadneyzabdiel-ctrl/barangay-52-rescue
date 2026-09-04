import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/map_layer_models.dart';
import '../../models/rescue_models.dart';
import '../../map/barangay_coverage.dart';
import '../../map/rescue_map_tiles.dart';
import '../../providers/rescue_provider.dart';
import '../../utils/unit_sos_compatibility.dart';
import '../../utils/geo_utils.dart';
import '../../widgets/map_layers_sheet.dart';
import '../../widgets/rescue_map_tile_layer.dart';
import '../../services/map_layer_data_service.dart';
import '../../services/reverse_geocoding_service.dart';
import '../../widgets/sos_chat_panel.dart';
import '../../widgets/sos_scene_photo.dart';
import '../../widgets/lgu_responder_chat_panel.dart';
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

class _LGUDashboardScreenState extends State<LGUDashboardScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  /// When false, command center map is hidden (no real-time elements shown).
  bool _commandMapOpen = false;
  /// Map flex (desktop): higher = larger map. Clamped 1..8.
  int _mapFlex = 3;
  bool _mapFullScreen = false;

  static const _caloocanCenter = BarangayCoverage.center;

  final FlutterTts _tts = FlutterTts();
  late final AnimationController _pulse;
  RescueProvider? _provider;
  StreamSubscription<Map<String, Map<String, dynamic>>>? _problemSub;
  Timer? _escalateTimer;

  bool _sosWatchSeeded = false;
  final Set<String> _knownSosIds = {};
  final Set<String> _acknowledgedSosIds = {};
  final Set<String> _escalatedSosIds = {};
  final Map<String, DateTime> _alertedAt = {};

  SOSRequest? _alertSos;
  SOSRequest? _problemSos;
  String? _problemText;
  final Map<String, String> _sosAddresses = {};

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final provider = context.read<RescueProvider>();
        _bindProvider(provider);
        provider.startFirebaseListeners();
        await provider.refreshLocationStatus();
        provider.initLocation();
        _listenProblemReports(provider);
        _escalateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          _checkEscalation();
        });
        final count = await provider.markOldSOSAsCompleted(olderThan: const Duration(hours: 2));
        if (mounted && count > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$count old SOS marked as completed.')),
          );
        }
      } catch (_) {}
    });
  }

  void _bindProvider(RescueProvider provider) {
    if (identical(_provider, provider)) return;
    _provider?.removeListener(_onRescueData);
    _provider = provider;
    _provider!.addListener(_onRescueData);
    _onRescueData();
  }

  void _listenProblemReports(RescueProvider provider) {
    _problemSub?.cancel();
    _problemSub = provider.firebaseSync.watchAllLguProblemReports().listen((map) {
      if (!mounted) return;
      SOSRequest? found;
      String? text;
      for (final sos in provider.activeSosRequests) {
        final info = map[sos.id];
        if (info == null) continue;
        if (info['hasProblem'] == true) {
          found = sos;
          text = (info['problemText'] as String?)?.trim();
          break;
        }
      }
      setState(() {
        _problemSos = found;
        _problemText = (text == null || text.isEmpty) ? null : text;
      });
    });
  }

  void _onRescueData() {
    final provider = _provider;
    if (provider == null || !mounted) return;
    final active = provider.activeSosRequests;
    final ids = active.map((s) => s.id).toSet();

    if (!_sosWatchSeeded) {
      _knownSosIds
        ..clear()
        ..addAll(ids);
      _sosWatchSeeded = true;
      return;
    }

    final newcomers = ids.difference(_knownSosIds);
    _knownSosIds
      ..clear()
      ..addAll(ids);
    _acknowledgedSosIds.removeWhere((id) => !ids.contains(id));
    _escalatedSosIds.removeWhere((id) => !ids.contains(id));
    _alertedAt.removeWhere((id, _) => !ids.contains(id));

    SOSRequest? newest;
    for (final id in newcomers) {
      for (final s in active) {
        if (s.id == id) newest = s;
      }
    }
    if (newest != null) {
      _ensureAddress(newest);
      _triggerNewSosAlert(newest);
    }

    for (final sos in active) {
      _ensureAddress(sos);
    }

    if (_alertSos != null && !ids.contains(_alertSos!.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _alertSos = null);
      });
    }
  }

  Future<void> _triggerNewSosAlert(SOSRequest sos) async {
    _alertedAt[sos.id] = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusSosOnMap(sos);
      setState(() => _alertSos = sos);
    });
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
    try {
      final typeLabel = SOSTypeInfo.forType(sos.sosType).label;
      await _tts.stop();
      final place = _addressFor(sos);
      await _tts.speak('New SOS. ${sos.citizenName}. $typeLabel. $place');
    } catch (_) {}
  }

  void _checkEscalation() {
    if (!mounted) return;
    final now = DateTime.now();
    var changed = false;
    for (final e in _alertedAt.entries) {
      if (_acknowledgedSosIds.contains(e.key)) continue;
      if (now.difference(e.value) < const Duration(seconds: 30)) continue;
      if (_escalatedSosIds.add(e.key)) {
        changed = true;
        SystemSound.play(SystemSoundType.alert);
        _tts.speak('SOS still unacknowledged.');
      }
    }
    if (changed) setState(() {});
  }

  void _acknowledgeSos(String sosId) {
    setState(() {
      _acknowledgedSosIds.add(sosId);
      _escalatedSosIds.remove(sosId);
      if (_alertSos?.id == sosId) _alertSos = null;
    });
  }

  void _focusSosOnMap(SOSRequest sos) {
    setState(() {
      _commandMapOpen = true;
      _mapFullScreen = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mapController.move(sos.location, 16);
      } catch (_) {}
    });
  }

  String _addressFor(SOSRequest sos) {
    final stored = sos.address?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return _sosAddresses[sos.id] ??
        ReverseGeocodingService.coordinatesLabel(sos.location);
  }

  Future<void> _ensureAddress(SOSRequest sos) async {
    final existing = sos.address?.trim();
    if (existing != null && existing.isNotEmpty) {
      if (_sosAddresses[sos.id] != existing) {
        _sosAddresses[sos.id] = existing;
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
      }
      return;
    }
    if (_sosAddresses.containsKey(sos.id)) return;
    _sosAddresses[sos.id] =
        ReverseGeocodingService.coordinatesLabel(sos.location);
    final addr = await ReverseGeocodingService.instance.addressFor(sos.location);
    if (!mounted) return;
    setState(() => _sosAddresses[sos.id] = addr);
    sos.address = addr;
    try {
      await context.read<RescueProvider>().firebaseSync.updateSosAddress(sos.id, addr);
    } catch (_) {}
  }

  bool _isUnacked(String sosId) => !_acknowledgedSosIds.contains(sosId);

  @override
  void dispose() {
    _provider?.removeListener(_onRescueData);
    _problemSub?.cancel();
    _escalateTimer?.cancel();
    _pulse.dispose();
    _tts.stop();
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
        title: Consumer<RescueProvider>(
          builder: (context, provider, child) {
            final err = provider.lastFirebaseError;
            final showErr = (kDebugMode || kProfileMode) && err != null && err.isNotEmpty;
            if (showErr) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('LGU Command Center'),
                  Text(
                    err,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.orangeAccent,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );
            }
            return const Text('LGU Command Center');
          },
        ),
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_alertSos != null) _buildNewSosBanner(_alertSos!),
                if (_problemSos != null) _buildProblemBanner(_problemSos!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewSosBanner(SOSRequest sos) {
    final escalated = _escalatedSosIds.contains(sos.id);
    final typeLabel = SOSTypeInfo.forType(sos.sosType).label;
    final time = DateFormat('h:mm a').format(sos.createdAt.toLocal());
    return Material(
      color: escalated ? const Color(0xFFB71C1C) : const Color(0xFFC62828),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                escalated ? Icons.warning_amber : Icons.sos,
                color: Colors.white,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      escalated
                          ? 'UNACKNOWLEDGED SOS · ${sos.citizenName} · $typeLabel · ${sos.priority.name.toUpperCase()} · $time'
                          : 'NEW SOS · ${sos.citizenName} · $typeLabel · ${sos.priority.name.toUpperCase()} · $time',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _addressFor(sos),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _focusSosOnMap(sos),
                child: const Text('VIEW ON MAP',
                    style: TextStyle(color: Colors.white)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFFC62828),
                ),
                onPressed: () => _acknowledgeSos(sos.id),
                child: const Text('ACKNOWLEDGE'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProblemBanner(SOSRequest sos) {
    return Material(
      color: const Color(0xFFE65100),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            const Icon(Icons.report_problem, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _problemText == null || _problemText!.isEmpty
                    ? 'Unit reported a problem on SOS for ${sos.citizenName}'
                    : 'Problem on ${sos.citizenName}: $_problemText',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _openSosActions(sos),
              child: const Text('ASSIST',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            TextButton(
              onPressed: () => _openSosActions(sos),
              child: const Text('REASSIGN',
                  style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await context.read<RescueProvider>().lguReleaseAssignedUnits(sos.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Units released. SOS is pending.')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$e'), backgroundColor: Colors.red),
                    );
                  }
                }
              },
              child: const Text('RELEASE',
                  style: TextStyle(color: Colors.white)),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: () => setState(() => _problemSos = null),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ],
        ),
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
        initialZoom: 15,
        interactionOptions: kRescueMapInteractions,
        keepAlive: true,
      ),
      children: [
        const RescueMapTileLayer(),
        ...BarangayCoverage.mapLayers(),
        ...MapLayerType.values
            .where((type) => type != MapLayerType.hazardZones)
            .expand((type) {
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
                        '${unit.callSign}\n${_unitTypeLabel(unit.type)} • ${_statusLabel(unit.status)}',
                    child: Container(
                      decoration: BoxDecoration(
                        color: unit.isAvailable
                            ? Colors.green
                            : Colors.orange,
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
            .where((u) => provider.isUnitOnline(u.id) && u.isAvailable)
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
        length: 2,
        child: Column(
          children: [
            TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              indicatorColor: const Color(0xFF4FC3F7),
              tabs: const [
                Tab(text: 'Active SOS'),
                Tab(text: 'History'),
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
            'Open the map to view real-time SOS and units',
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
                        provider.isUnitOnline(u.id) && u.isAvailable)
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
                          _StatusDot(label: 'Offline', color: Colors.grey),
                        ],
                      ),
                    ),
                    ...provider.unitsForDisplay.map((u) => _buildUnitTile(u, provider.isUnitOnline(u.id))),
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
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: Card(
                      color: const Color(0xFF1B2838).withValues(alpha: 0.95),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Text(
                          'Caloocan City - Live Operations Map',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(color: Colors.white, fontSize: 14),
                        ),
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
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: () => showMapLayersSheet(context),
                    icon: const Icon(Icons.layers),
                    tooltip: 'Map type & details',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                  ),
                  const SizedBox(width: 6),
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

  Widget _buildUnitTile(RescueUnit unit, bool isOnline) {
    return ListTile(
      dense: true,
      leading: Icon(
        _unitIcon(unit.type),
        color: isOnline
            ? (unit.isAvailable ? Colors.green : Colors.orange)
            : Colors.grey,
        size: 22,
      ),
      title: Text(unit.callSign,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      subtitle: Text(
        isOnline ? _statusLabel(unit.status) : 'OFFLINE',
        style: TextStyle(
          color: isOnline
              ? (unit.isAvailable ? Colors.green.shade300 : Colors.orange.shade300)
              : Colors.grey,
          fontSize: 11,
        ),
      ),
      onTap: isOnline ? () => _mapController.move(unit.position, 15) : null,
    );
  }

  Future<void> _launchCitizenCall(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone.trim());
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
                otherPartyPhoneNumber: sos.callbackPhone,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showResponderChat(BuildContext context, SOSRequest sos) {
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
                'Chat: Responder (LGU)',
                style: TextStyle(
                  color: Colors.grey[300],
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: LguResponderChatPanel(
                sosId: sos.id,
                senderRole: 'lgu',
                senderId: 'lgu',
                senderDisplayName: 'LGU',
                completedAt: sos.completedAt,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSOSTile(SOSRequest sos) {
    final unacked = _isUnacked(sos.id);
    final escalated = _escalatedSosIds.contains(sos.id);
    final typeLabel = SOSTypeInfo.forType(sos.sosType).label;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = unacked ? _pulse.value : 0.0;
        final glow = escalated ? 0.45 + 0.35 * t : 0.15 + 0.22 * t;
        return Card(
          color: Colors.red.withValues(alpha: unacked ? glow : 0.15),
          margin: const EdgeInsets.only(bottom: 6),
          shape: escalated
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Colors.yellowAccent, width: 1.5),
                )
              : null,
          child: child,
        );
      },
      child: ListTile(
        dense: true,
        leading: Icon(
          Icons.sos,
          color: unacked ? Colors.redAccent : Colors.red,
          size: 20,
        ),
        title: Text(sos.citizenName,
            style: const TextStyle(color: Colors.white, fontSize: 13)),
        subtitle: Text(
          '${_addressFor(sos)}\n$typeLabel · ${sos.priority.name.toUpperCase()} · ${sos.status.name}'
          '${sos.locationIsPinned ? (sos.isProxyReport ? ' · For ${sos.reportedForName}' : ' · Pinned') : ''}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        trailing: StreamBuilder<Map<String, dynamic>?>(
          stream: context
              .read<RescueProvider>()
              .firebaseSync
              .watchLguProblemReport(sos.id),
          builder: (context, snap) {
            final info = snap.data;
            final hasProblem = (info?['hasProblem'] as bool?) == true;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (unacked)
                  const Icon(Icons.notifications_active,
                      size: 16, color: Colors.redAccent),
                if (hasProblem)
                  Tooltip(
                    message: (info?['problemText'] as String?)?.trim().isNotEmpty ==
                            true
                        ? (info?['problemText'] as String)
                        : 'Responder marked a problem',
                    child: const Icon(
                      Icons.report_problem,
                      size: 20,
                      color: Colors.orangeAccent,
                    ),
                  ),
              ],
            );
          },
        ),
        onTap: () => _openSosActions(sos),
      ),
    );
  }

  Widget _buildAssistUnitSection(
    BuildContext sheetContext,
    SOSRequest sos,
    String address,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1565C0).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF4FC3F7).withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'ASSIST UNIT',
            style: TextStyle(
              color: Color(0xFF4FC3F7),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Send guidance to the assigned responder on this SOS.',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _sendAssistMessage(
                    sos,
                    'LGU assist — incident location:\n$address\n'
                    '${ReverseGeocodingService.coordinatesLabel(sos.location)}',
                  );
                },
                icon: const Icon(Icons.location_on, size: 18),
                label: const Text('Send address'),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _sendNearestFacility(sos);
                },
                icon: const Icon(Icons.local_hospital, size: 18),
                label: const Text('Nearest facility'),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _sendAssistMessage(
                    sos,
                    'LGU assist — Stand by. Backup unit is being assigned.',
                  );
                },
                icon: const Icon(Icons.hourglass_top, size: 18),
                label: const Text('Stand by / backup'),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _sendAssistMessage(
                    sos,
                    'LGU assist — Stand down and return to station. Await further instruction.',
                  );
                },
                icon: const Icon(Icons.home_outlined, size: 18),
                label: const Text('Stand down'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _sendCustomAssistNote(sos);
                },
                icon: const Icon(Icons.edit_note, size: 18),
                label: const Text('Custom note'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _showResponderChat(context, sos);
                },
                icon: const Icon(Icons.support_agent_outlined, size: 18),
                label: const Text('Open chat'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  MapLayerPOI? _nearestAssistFacility(SOSRequest sos) {
    final layer = switch (sos.sosType) {
      SOSType.medical || SOSType.accident => MapLayerType.hospitals,
      SOSType.fire => MapLayerType.fireStations,
      SOSType.violence => MapLayerType.policeStations,
      _ => MapLayerType.threeSCenters,
    };
    final pois = MapLayerDataService.getLayerData(layer);
    MapLayerPOI? best;
    var bestKm = double.infinity;
    for (final p in pois) {
      final km = GeoUtils.haversineKm(sos.location, p.position);
      if (km < bestKm) {
        bestKm = km;
        best = p;
      }
    }
    return best;
  }

  Future<void> _sendNearestFacility(SOSRequest sos) async {
    final poi = _nearestAssistFacility(sos);
    if (poi == null) {
      _showActionError('No nearby facility found for this SOS type.');
      return;
    }
    final km = GeoUtils.haversineKm(sos.location, poi.position);
    final extra = <String>[
      'LGU assist — nearest ${SOSTypeInfo.forType(sos.sosType).label.toLowerCase()} facility:',
      poi.name,
      if (poi.address != null && poi.address!.trim().isNotEmpty) poi.address!,
      if (poi.phone != null && poi.phone!.trim().isNotEmpty) 'Phone: ${poi.phone}',
      '${km.toStringAsFixed(1)} km from incident',
    ];
    await _sendAssistMessage(sos, extra.join('\n'));
    _mapController.move(poi.position, 16);
  }

  Future<void> _sendCustomAssistNote(SOSRequest sos) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2838),
        title: const Text('Note to responder',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Landmark, floor, gate, patient details…',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = note?.trim() ?? '';
    if (trimmed.isEmpty) return;
    await _sendAssistMessage(sos, 'LGU assist — $trimmed');
  }

  Future<void> _sendAssistMessage(SOSRequest sos, String text) async {
    try {
      await context.read<RescueProvider>().firebaseSync.sendLguResponderChatMessage(
            sosId: sos.id,
            senderRole: 'lgu',
            senderId: 'lgu',
            senderDisplayName: 'LGU',
            text: text,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sent to responder chat.'),
          backgroundColor: Color(0xFF1565C0),
        ),
      );
    } catch (e) {
      _showActionError(e);
    }
  }

  Future<void> _openSosActions(SOSRequest sos) async {
    _focusSosOnMap(sos);
    await _ensureAddress(sos);
    if (!mounted) return;
    final address = _addressFor(sos);
    final coords = ReverseGeocodingService.coordinatesLabel(sos.location);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B2838),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  sos.citizenName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${SOSTypeInfo.forType(sos.sosType).label} · ${sos.priority.name.toUpperCase()} · ${sos.status.name}',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                ),
                if (sos.locationIsPinned) ...[
                  const SizedBox(height: 6),
                  Text(
                    sos.isProxyReport
                        ? 'Pinned for ${sos.reportedForName} · reported by ${sos.citizenName}'
                        : 'Pinned incident location (not live GPS)',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (!BarangayCoverage.contains(sos.location)) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Outside Barangay 52 coverage',
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (sos.hasCallbackPhone) ...[
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () => _launchCitizenCall(sos.callbackPhone!.trim()),
                    child: Text(
                      'Call: ${sos.callbackPhone!.trim()}',
                      style: const TextStyle(
                        color: Colors.lightGreenAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.lightGreenAccent,
                      ),
                    ),
                  ),
                ],
                if (sos.hasScenePhoto)
                  SosScenePhotoThumb(photoUrl: sos.scenePhotoUrl),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'LOCATION',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        address,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        coords,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                if (sos.message != null && sos.message!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(sos.message!,
                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
                const SizedBox(height: 16),
                _buildAssistUnitSection(ctx, sos, address),
                const SizedBox(height: 16),
                const Text(
                  'DISPATCH',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _acknowledgeSos(sos.id);
                      },
                      icon: const Icon(Icons.visibility, size: 18),
                      label: const Text('Acknowledge'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _pickAndRun(
                          sos,
                          title: 'Dispatch unit',
                          action: (id) => context
                              .read<RescueProvider>()
                              .lguDispatchUnit(sosId: sos.id, unitId: id),
                          ok: 'Unit dispatched.',
                        );
                      },
                      icon: const Icon(Icons.send, size: 18),
                      label: const Text('Dispatch unit'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _pickAndRun(
                          sos,
                          title: 'Add backup unit',
                          action: (id) => context
                              .read<RescueProvider>()
                              .lguAddBackupUnit(sosId: sos.id, unitId: id),
                          ok: 'Backup unit added.',
                          assistMessage:
                              'LGU assist — Stand by. Backup unit is being assigned.',
                        );
                      },
                      icon: const Icon(Icons.group_add, size: 18),
                      label: const Text('Add backup'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _pickAndRun(
                          sos,
                          title: 'Reassign unit',
                          action: (id) => context
                              .read<RescueProvider>()
                              .lguReassignUnit(sosId: sos.id, newUnitId: id),
                          ok: 'Unit reassigned.',
                        );
                      },
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Reassign'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          await context
                              .read<RescueProvider>()
                              .lguReleaseAssignedUnits(sos.id);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Units released. SOS is pending.')),
                            );
                          }
                        } catch (e) {
                          _showActionError(e);
                        }
                      },
                      icon: const Icon(Icons.link_off, size: 18),
                      label: const Text('Release unit'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orangeAccent,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmFalseAlarm(sos);
                      },
                      icon: const Icon(Icons.report_off, size: 18),
                      label: const Text('False alarm'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmComplete(sos);
                      },
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Complete'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showResponderChat(context, sos);
                      },
                      icon: const Icon(Icons.support_agent_outlined, size: 18),
                      label: const Text('Chat responder'),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showLGUChat(context, sos);
                      },
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Chat citizen'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickAndRun(
    SOSRequest sos, {
    required String title,
    required Future<void> Function(String unitId) action,
    required String ok,
    String? assistMessage,
  }) async {
    final unit = await _pickUnit(sos, title);
    if (unit == null || !mounted) return;
    try {
      await action(unit.id);
      _acknowledgeSos(sos.id);
      if (assistMessage != null && assistMessage.trim().isNotEmpty) {
        await context.read<RescueProvider>().firebaseSync.sendLguResponderChatMessage(
              sosId: sos.id,
              senderRole: 'lgu',
              senderId: 'lgu',
              senderDisplayName: 'LGU',
              text: assistMessage,
            );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
    } catch (e) {
      _showActionError(e);
    }
  }

  Future<RescueUnit?> _pickUnit(SOSRequest sos, String title) async {
    final provider = context.read<RescueProvider>();
    final candidates = provider.lguDispatchCandidates(sos);
    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No online idle unit can handle this SOS type.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return null;
    }
    return showDialog<RescueUnit>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2838),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (_, i) {
              final u = candidates[i];
              return ListTile(
                leading: Icon(_unitIcon(u.type), color: Colors.greenAccent),
                title: Text(u.callSign,
                    style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  unitTypeLabel(u.type),
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () => Navigator.pop(ctx, u),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmComplete(SOSRequest sos) async {
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
    if (confirmed != true || !mounted) return;
    try {
      await context.read<RescueProvider>().completeSOS(sos);
      _acknowledgeSos(sos.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SOS marked as completed.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      _showActionError(e);
    }
  }

  Future<void> _confirmFalseAlarm(SOSRequest sos) async {
    const reasons = [
      'Not an emergency',
      'Duplicate call',
      'Wrong location',
      'Cancelled by caller',
      'Other',
    ];
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close as false alarm?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'This closes the SOS for ${sos.citizenName} after the fact. It is not a screening check.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            ...reasons.map(
              (r) => ListTile(
                dense: true,
                title: Text(r),
                onTap: () => Navigator.pop(ctx, r),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    try {
      await context.read<RescueProvider>().lguMarkFalseAlarm(sos, reason: reason);
      _acknowledgeSos(sos.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Closed as false alarm ($reason).')),
      );
    } catch (e) {
      _showActionError(e);
    }
  }

  void _showActionError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$e'.replaceFirst('Bad state: ', '')),
        backgroundColor: Colors.red,
      ),
    );
  }

  Widget _buildSOSHistoryTile(SOSRequest sos) {
    final completed = sos.status == SOSStatus.completed;
    final falseAlarm = sos.closeReason != null &&
        sos.closeReason!.startsWith('false_alarm');
    final df = DateFormat('MMM d, yyyy • h:mm a');
    final created = df.format(sos.createdAt.toLocal());
    final ended = sos.completedAt != null
        ? df.format(sos.completedAt!.toLocal())
        : '—';
    final reasonBit = sos.closeReason == null
        ? ''
        : '\n${sos.closeReason!.replaceFirst('false_alarm:', 'False alarm: ').replaceFirst('false_alarm', 'False alarm')}';
    return Card(
      color: Colors.grey.withValues(alpha: 0.1),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(
          completed
              ? Icons.check_circle
              : (falseAlarm ? Icons.report_off : Icons.cancel),
          color: completed
              ? Colors.green
              : (falseAlarm ? Colors.orangeAccent : Colors.grey),
          size: 20,
        ),
        title: Text(sos.citizenName,
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        subtitle: Text(
          'Created: $created\nEnded: $ended\n${sos.status.name} • ${sos.priority.name}$reasonBit',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.support_agent_outlined,
                  size: 20, color: Colors.white54),
              onPressed: () => _showResponderChat(context, sos),
              tooltip: 'Chat responder',
            ),
            IconButton(
              icon: const Icon(Icons.chat_bubble_outline,
                  size: 20, color: Colors.white54),
              onPressed: () => _showLGUChat(context, sos),
              tooltip: 'View messages',
            ),
          ],
        ),
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
