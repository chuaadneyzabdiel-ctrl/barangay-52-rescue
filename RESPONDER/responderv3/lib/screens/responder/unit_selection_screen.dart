import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/rescue_models.dart';
import '../../providers/rescue_provider.dart';
import 'responder_pending_approval_screen.dart';

/// Lets the responder pick which rescue unit they are. Same roster as LGU dashboard.
class UnitSelectionScreen extends StatelessWidget {
  final String allowedUnitId;

  const UnitSelectionScreen({super.key, required this.allowedUnitId});

  static IconData _unitIcon(UnitType type) {
    switch (type) {
      case UnitType.ambulance:
        return Icons.local_hospital;
      case UnitType.fireTruck:
        return Icons.local_fire_department;
      case UnitType.policeUnit:
        return Icons.local_police;
      case UnitType.rescue:
        return Icons.health_and_safety;
    }
  }

  static String _unitTypeLabel(UnitType type) {
    return switch (type) {
      UnitType.ambulance => 'AMBULANCE',
      UnitType.fireTruck => 'FIRE TRUCK',
      UnitType.policeUnit => 'POLICE',
      UnitType.rescue => 'BARANGAY TANOD',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        title: const Text('Select your unit'),
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Consumer<RescueProvider>(
        builder: (context, provider, _) {
          final roster = provider.rescueUnitsRoster
              .where((u) => u.id == allowedUnitId)
              .toList();
          final liveIds = provider.rescueUnits.map((u) => u.id).toSet();
          if (roster.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.orangeAccent,
                      size: 40,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Assigned unit not found.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please contact LGU to check account-to-unit mapping.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 8),
              Text(
                'Choose the unit you are operating. This list matches the LGU dashboard.',
                style: TextStyle(color: Colors.grey[400], fontSize: 14),
              ),
              const SizedBox(height: 24),
              ...roster.map((unit) {
                final isOnline = liveIds.contains(unit.id);
                return Card(
                  color: const Color(0xFF1B3A5C).withValues(alpha: 0.6),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isOnline
                          ? Colors.green.withValues(alpha: 0.3)
                          : Colors.grey.withValues(alpha: 0.3),
                      child: Icon(_unitIcon(unit.type), color: Colors.white),
                    ),
                    title: Text(
                      unit.callSign,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Text(
                      '${_unitTypeLabel(unit.type)} • ${isOnline ? "Online" : "Offline"}',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                    trailing: const Icon(Icons.arrow_forward_ios,
                        size: 16, color: Colors.white70),
                    onTap: () =>
                        _onSelectUnit(context, provider, unit, allowedUnitId),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }

  Future<void> _onSelectUnit(
    BuildContext context,
    RescueProvider provider,
    RescueUnit rosterUnit,
    String allowedUnitId,
  ) async {
    if (rosterUnit.id != allowedUnitId) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This account can only access its assigned unit.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    final lockOk = await provider.ensureResponderSessionIsValid(
      unitId: rosterUnit.id,
    );
    if (!lockOk) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This account/session is active elsewhere. Please sign in again.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    await provider.refreshLocationStatus();
    provider.initLocation();
    provider.startFirebaseListeners();
    final position = provider.currentPosition ?? rosterUnit.position;
    final unit = RescueUnit(
      id: rosterUnit.id,
      callSign: rosterUnit.callSign,
      type: rosterUnit.type,
      status: UnitStatus.idle,
      position: position,
      stationId: rosterUnit.stationId,
      barangayId: rosterUnit.barangayId,
    );
    provider.setCurrentResponderUnit(unit);
    if (!context.mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResponderPendingApprovalScreen(rosterUnit: rosterUnit),
      ),
    );
  }
}
