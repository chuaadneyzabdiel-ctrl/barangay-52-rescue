import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../map/rescue_map_tiles.dart';
import '../../widgets/map_layers_sheet.dart';
import '../../widgets/rescue_map_tile_layer.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_provider.dart';
import '../../utils/geo_utils.dart';
import '../../utils/unit_sos_compatibility.dart';
import '../../services/local_notification_service.dart';
import 'route_preview_screen.dart';
import '../dashboard/account_center_screen.dart';
import '../map_navigation_screen.dart';
import '../session_bootstrap_screen.dart';

class DispatchScreen extends StatefulWidget {
  final String unitId;

  const DispatchScreen({super.key, required this.unitId});

  @override
  State<DispatchScreen> createState() => _DispatchScreenState();
}

class _DispatchScreenState extends State<DispatchScreen> {
  final MapController _mapController = MapController();
  bool _isAccepting = false;
  bool _isCompleting = false;
  bool _isCancelling = false;
  StreamSubscription<bool>? _approvalSub;
  bool _revokedHandled = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<RescueProvider>();
      final lockOk = await provider.ensureResponderSessionIsValid(
        unitId: widget.unitId,
      );
      if (!lockOk) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session is active elsewhere. Please sign in again.'),
            backgroundColor: Colors.red,
          ),
        );
        await provider.clearPersistedSessionKeys();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => const SessionBootstrapScreen()),
          (_) => false,
        );
        return;
      }
      await provider.refreshLocationStatus();
      provider.startFirebaseListeners();
      provider.initLocation();
      RescueUnit? unit = provider.currentResponderUnit?.id == widget.unitId
          ? provider.currentResponderUnit
          : provider.rescueUnits.where((u) => u.id == widget.unitId).firstOrNull;
      if (unit == null) {
        final roster = provider.rescueUnitsRoster
            .where((u) => u.id == widget.unitId)
            .firstOrNull;
        if (roster != null) {
          final pos = provider.currentPosition ?? roster.position;
          unit = RescueUnit(
            id: roster.id,
            callSign: roster.callSign,
            type: roster.type,
            status: UnitStatus.idle,
            position: pos,
            stationId: roster.stationId,
          );
          provider.setCurrentResponderUnit(unit);
          bool ok = false;
          try {
            ok = await provider.registerUnit(unit);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
              );
            }
            return;
          }
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Responder account pending LGU approval.'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      }
      if (unit != null) provider.startGpsUpload(widget.unitId, unit);

      _approvalSub?.cancel();
      _approvalSub = provider.firebaseSync
          .watchResponderApproval(widget.unitId)
          .listen((approved) async {
        if (!approved && mounted && !_revokedHandled) {
          _revokedHandled = true;
          await provider.responderLogout(widget.unitId);
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
      final pending = provider.pendingRequests;
      if (pending.isNotEmpty) {
        LocalNotificationService().showNewSOS();
      }

      // Resume navigation if responder had an active run (persisted) — e.g. left map or restarted app.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      final nav = await provider.readResponderNavigation();
      if (nav.sosId == null || nav.unitId != widget.unitId) return;
      final sos = provider.sosRequests
          .where(
            (r) =>
                r.id == nav.sosId &&
                r.isActive &&
                r.assignedUnitId == widget.unitId,
          )
          .firstOrNull;
      if (sos == null || !mounted) return;

      RescueUnit? navUnit = provider.rescueUnits
          .where((u) => u.id == widget.unitId)
          .firstOrNull;
      navUnit ??= provider.currentResponderUnit?.id == widget.unitId
          ? provider.currentResponderUnit
          : null;
      if (navUnit == null) {
        final roster = provider.rescueUnitsRoster
            .where((u) => u.id == widget.unitId)
            .firstOrNull;
        if (roster != null) {
          navUnit = RescueUnit(
            id: roster.id,
            callSign: roster.callSign,
            type: roster.type,
            status: UnitStatus.enRoute,
            position: provider.currentPosition ?? roster.position,
            stationId: roster.stationId,
            assignedSOSId: sos.id,
          );
          provider.setCurrentResponderUnit(navUnit);
          bool ok = false;
          try {
            ok = await provider.registerUnit(navUnit);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
              );
            }
            return;
          }
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Responder account pending LGU approval.'),
                backgroundColor: Colors.orange,
              ),
            );
            return;
          }
        }
      }
      if (navUnit != null && mounted) {
        final unitForNav = navUnit!;
        await provider.computeRoute(
          from: unitForNav.position,
          to: sos.location,
        );
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => MapNavigationScreen(
              sosRequest: sos,
              responderUnit: unitForNav,
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    context.read<RescueProvider>().stopGpsUpload();
    _approvalSub?.cancel();
    _mapController.dispose();
    super.dispose();
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

  Future<void> _openNavigationForActive(
    BuildContext context,
    RescueProvider provider,
    SOSRequest sos,
  ) async {
    RescueUnit? unit = provider.rescueUnits
        .where((u) => u.id == widget.unitId)
        .firstOrNull;
    unit ??= provider.currentResponderUnit?.id == widget.unitId
        ? provider.currentResponderUnit
        : null;
    if (unit == null) {
      final roster = provider.rescueUnitsRoster
          .where((u) => u.id == widget.unitId)
          .firstOrNull;
      if (roster == null) return;
      unit = RescueUnit(
        id: roster.id,
        callSign: roster.callSign,
        type: roster.type,
        status: UnitStatus.enRoute,
        position: provider.currentPosition ?? roster.position,
        stationId: roster.stationId,
        assignedSOSId: sos.id,
      );
      provider.setCurrentResponderUnit(unit);
      bool ok = false;
      try {
        ok = await provider.registerUnit(unit);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
          );
        }
        return;
      }
      if (!ok) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Responder account pending LGU approval.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
    }
    await provider.computeRoute(
      from: unit.position,
      to: sos.location,
    );
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MapNavigationScreen(
          sosRequest: sos,
          responderUnit: unit!,
        ),
      ),
    );
  }

  Future<void> _confirmCompleteFromDispatch(
    BuildContext context,
    RescueProvider provider,
    SOSRequest sos,
  ) async {
    if (_isCompleting) return;
    final unit = provider.rescueUnits.where((u) => u.id == widget.unitId).firstOrNull ??
        provider.currentResponderUnit;
    if (unit?.type == UnitType.ambulance) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'For ambulance calls, complete only after arriving at selected facility in the navigation map.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Complete rescue?'),
        content: const Text(
          'Mark this SOS as completed only if the scene is clear and the citizen is assisted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Complete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    setState(() => _isCompleting = true);
    try {
      await provider.completeSOS(sos);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SOS marked complete.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      await _handleResponderActionError(e);
    } finally {
      if (mounted) setState(() => _isCompleting = false);
    }
  }

  Future<void> _confirmAbortFromDispatch(
    BuildContext context,
    RescueProvider provider,
    SOSRequest sos,
  ) async {
    if (_isCancelling) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this response?'),
        content: const Text(
          'You will stop responding to this SOS. The request will be cancelled for everyone. '
          'Only use this if you cannot continue (vehicle issue, false alarm, etc.).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay on call'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Final confirmation'),
        content: const Text(
          'This cannot be undone. Cancel the SOS response?',
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
    if (sure != true || !context.mounted) return;
    setState(() => _isCancelling = true);
    try {
      await provider.responderAbortSOS(
        sosId: sos.id,
        unitId: widget.unitId,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Response cancelled.'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      await _handleResponderActionError(e);
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  Future<void> _confirmBackToMain(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave rescue dashboard?'),
        content: const Text(
          'Your unit will go offline on the map. Your responder session stays signed in until you use '
          'Account → Log out.',
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
    if (confirmed != true || !context.mounted) return;
    final provider = context.read<RescueProvider>();
    await provider.logDashboardExit(
      role: 'responder',
      screen: 'dispatch',
      unitId: widget.unitId,
    );
    await provider.goOffline(widget.unitId);
    if (!context.mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _handleAccept(SOSRequest request) async {
    if (_isAccepting) return;
    setState(() => _isAccepting = true);

    try {
      final provider = context.read<RescueProvider>();
      await provider.acceptDispatch(unitId: widget.unitId, sosId: request.id);

      final unit = provider.currentResponderUnit?.id == widget.unitId
          ? provider.currentResponderUnit
          : provider.rescueUnits.where((u) => u.id == widget.unitId).firstOrNull;

      if (!mounted) return;

      if (unit == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unit not found. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RoutePreviewScreen(
            sosRequest: request,
            responderUnit: unit,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Dispatch failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isAccepting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Consumer<RescueProvider>(
        builder: (context, provider, _) {
          final pending = provider.pendingRequests;
          final responderUnit = provider.rescueUnits
                  .where((u) => u.id == widget.unitId)
                  .firstOrNull ??
              provider.rescueUnitsRoster.where((u) => u.id == widget.unitId).firstOrNull;
          final responderUnitType = responderUnit?.type;
          final activeForUnit = provider.sosRequests
              .where(
                (r) =>
                    r.assignedUnitId == widget.unitId && r.isActive,
              )
              .firstOrNull;

          return Stack(
            children: [
              // Full-screen map
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: provider.currentPosition ??
                      const LatLng(14.6544, 120.9840),
                  initialZoom: 14,
                  interactionOptions: kRescueMapInteractions,
                  keepAlive: true,
                ),
                children: [
                  const RescueMapTileLayer(),
                  PolygonLayer(
                    polygons: provider.hazardZones
                        .where((h) => h.isActive)
                        .map((h) => Polygon(
                              points: h.polygon,
                              color:
                                  _hazardColor(h.type).withValues(alpha: 0.25),
                              borderColor: _hazardColor(h.type),
                              borderStrokeWidth: 2,
                            ))
                        .toList(),
                  ),
                  MarkerLayer(
                    markers: [
                      if (provider.currentPosition != null)
                        Marker(
                          point: provider.currentPosition!,
                          width: 52,
                          height: 52,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.green.withValues(alpha: 0.6),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(Icons.local_shipping,
                                color: Colors.white, size: 24),
                          ),
                        ),
                      ...provider.activeSosRequests.map((sos) => Marker(
                            point: sos.location,
                            width: 52,
                            height: 52,
                            child: Container(
                              decoration: BoxDecoration(
                                color: _priorityColor(sos.priority),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.6),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.sos,
                                  color: Colors.white, size: 24),
                            ),
                          )),
                    ],
                  ),
                ],
              ),

              // Location off banner (rescuers)
              if (provider.locationStatus?.needsPrompt == true)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 12,
                  right: 12,
                  child: _buildLocationBanner(context, provider),
                ),

              // Top bar with title + status chip
              Positioned(
                top: MediaQuery.of(context).padding.top +
                    (provider.locationStatus?.needsPrompt == true ? 56 : 8),
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      style: IconButton.styleFrom(
                        backgroundColor:
                            Colors.black.withValues(alpha: 0.35),
                      ),
                      onPressed: () => _confirmBackToMain(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.account_circle_outlined,
                          color: Colors.white),
                      style: IconButton.styleFrom(
                        backgroundColor:
                            Colors.black.withValues(alpha: 0.35),
                      ),
                      tooltip: 'Account',
                      onPressed: () {
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const AccountCenterScreen(),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B3A5C).withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            pending.isEmpty ? Icons.shield : Icons.sos,
                            color:
                                pending.isEmpty ? Colors.green : Colors.red,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            pending.isEmpty
                                ? 'Standby'
                                : '${pending.length} SOS Alert${pending.length > 1 ? 's' : ''}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Builder(builder: (context) {
                      final unit = provider.rescueUnits
                          .where((u) => u.id == widget.unitId);
                      if (unit.isEmpty) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: unit.first.isAvailable
                              ? Colors.green.withValues(alpha: 0.9)
                              : Colors.orange.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Text(
                          _statusLabel(unit.first.status),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),

              // Active SOS: complete / cancel / open navigation (when not on map screen)
              if (activeForUnit != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: pending.isNotEmpty ? 260 : 110,
                  child: Material(
                    color: const Color(0xFF1B2838),
                    elevation: 8,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.emergency_share,
                                  color: Colors.orange, size: 22),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Active response • ${activeForUnit.citizenName}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            SOSTypeInfo.forType(activeForUnit.sosType).label,
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _openNavigationForActive(
                                      context, provider, activeForUnit),
                                  icon: const Icon(Icons.navigation, size: 18),
                                  label: const Text('Navigation'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.green.shade700,
                                  ),
                                  onPressed: (_isCompleting || _isCancelling)
                                      ? null
                                      : () => _confirmCompleteFromDispatch(
                                          context, provider, activeForUnit),
                                  icon: const Icon(Icons.check_circle, size: 18),
                                  label: const Text('Complete'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: TextButton.icon(
                              onPressed: (_isCompleting || _isCancelling)
                                  ? null
                                  : () => _confirmAbortFromDispatch(
                                      context, provider, activeForUnit),
                              icon: Icon(Icons.cancel, color: Colors.red.shade300),
                              label: Text(
                                'Cancel response',
                                style: TextStyle(color: Colors.red.shade200),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Map layers + recenter
              Positioned(
                bottom: activeForUnit != null && pending.isNotEmpty
                    ? 380
                    : activeForUnit != null
                        ? 320
                        : pending.isNotEmpty
                            ? 260
                            : 116,
                right: 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MapLayersMapButton(),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'recenter-dispatch',
                      onPressed: () {
                        final pos = provider.currentPosition;
                        if (pos != null) _mapController.move(pos, 15);
                      },
                      backgroundColor:
                          const Color(0xFF1B3A5C).withValues(alpha: 0.95),
                      child:
                          const Icon(Icons.my_location, color: Colors.white),
                    ),
                  ],
                ),
              ),

              // Loading overlay
              if (_isAccepting)
                Container(
                  color: Colors.black54,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          'Accepting dispatch & computing route...',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),

              // Bottom sheet with SOS cards (fully scrollable: header + cards)
              if (pending.isNotEmpty)
                DraggableScrollableSheet(
                  initialChildSize: 0.32,
                  minChildSize: 0.10,
                  maxChildSize: 0.85,
                  builder: (context, scrollController) {
                    return Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF0D1B2A),
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(20)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 12,
                            offset: Offset(0, -4),
                          ),
                        ],
                      ),
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          const SizedBox(height: 8),
                          Center(
                            child: Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey[600],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber,
                                    color: Colors.orange, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  'Incoming SOS Alerts',
                                  style: TextStyle(
                                    color: Colors.grey[300],
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ...pending.map(
                            (request) => Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              child: _DispatchCard(
                                request: request,
                                responderPosition:
                                    provider.currentPosition,
                                isAccepting: _isAccepting,
                                canAccept: responderUnitType == null
                                    ? false
                                    : canUnitHandleSos(
                                        responderUnitType, request.sosType),
                                ineligibleReason: responderUnitType == null
                                    ? 'Unit details unavailable.'
                                    : '${unitTypeLabel(responderUnitType)} cannot handle ${SOSTypeInfo.forType(request.sosType).label.toLowerCase()} SOS.',
                                onAccept: () => _handleAccept(request),
                                onLocateTap: () {
                                  _mapController.move(request.location, 16);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

              // Standby message when no SOS and no active assignment
              if (pending.isEmpty && activeForUnit == null)
                Positioned(
                  bottom: 24,
                  left: 24,
                  right: 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color:
                          const Color(0xFF1B3A5C).withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.shield,
                            color: Colors.green, size: 22),
                        const SizedBox(width: 10),
                        Text(
                          'Standing by for SOS alerts...',
                          style: TextStyle(
                              color: Colors.grey[300], fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLocationBanner(BuildContext context, RescueProvider provider) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.orange.shade700,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.orange.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.location_off, color: Colors.white, size: 24),
            const SizedBox(width: 10),
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
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    'Keep location on so your position is shared accurately.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.95),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () async {
                final opened = await provider.locationService.openLocationSettings();
                if (!opened) await provider.locationService.openAppSettings();
                if (context.mounted) provider.refreshLocationStatus();
              },
              child: const Text('Turn on', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
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

  Color _priorityColor(SOSPriority priority) {
    return switch (priority) {
      SOSPriority.critical => Colors.red.shade900,
      SOSPriority.high => Colors.red,
      SOSPriority.medium => Colors.orange,
      SOSPriority.low => Colors.amber,
    };
  }
}

class _DispatchCard extends StatelessWidget {
  final SOSRequest request;
  final LatLng? responderPosition;
  final bool isAccepting;
  final bool canAccept;
  final String? ineligibleReason;
  final VoidCallback onAccept;
  final VoidCallback onLocateTap;

  const _DispatchCard({
    required this.request,
    required this.responderPosition,
    required this.isAccepting,
    required this.canAccept,
    required this.ineligibleReason,
    required this.onAccept,
    required this.onLocateTap,
  });

  @override
  Widget build(BuildContext context) {
    final (priorityLabel, priorityColor) = switch (request.priority) {
      SOSPriority.critical => ('CRITICAL', Colors.red),
      SOSPriority.high => ('HIGH', Colors.orange),
      SOSPriority.medium => ('MEDIUM', Colors.amber),
      SOSPriority.low => ('LOW', Colors.green),
    };

    String distanceText = '';
    if (responderPosition != null) {
      final km = GeoUtils.haversineKm(responderPosition!, request.location);
      distanceText = km < 1
          ? '${(km * 1000).toStringAsFixed(0)}m away'
          : '${km.toStringAsFixed(1)}km away';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: const Color(0xFF1B2838),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: priorityColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    priorityLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (distanceText.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      distanceText,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  _timeAgo(request.createdAt),
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _iconForSOSType(request.sosType),
                        color: Colors.amber,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        SOSTypeInfo.forType(request.sosType).label.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    request.typeDescription,
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.person, color: Colors.white70, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    request.citizenName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onLocateTap,
                  icon:
                      const Icon(Icons.gps_fixed, color: Colors.blue, size: 20),
                  tooltip: 'Show on map',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (request.message != null) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.message, color: Colors.white70, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      request.message!,
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            if (!canAccept && ineligibleReason != null) ...[
              Text(
                ineligibleReason!,
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: (isAccepting || !canAccept) ? null : onAccept,
                icon: const Icon(Icons.navigation),
                label: const Text(
                  'ACCEPT & NAVIGATE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2ECC71),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
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
}
