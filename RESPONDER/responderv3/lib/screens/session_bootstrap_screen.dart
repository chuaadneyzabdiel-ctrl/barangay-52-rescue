import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/rescue_provider.dart';
import 'citizen/sos_screen.dart';
import 'dashboard/lgu_dashboard_screen.dart';
import 'responder/responder_pending_approval_screen.dart';
import 'role_selection_screen.dart';

/// Restores last role (citizen / responder / LGU) from local storage.
class SessionBootstrapScreen extends StatefulWidget {
  const SessionBootstrapScreen({super.key});

  @override
  State<SessionBootstrapScreen> createState() => _SessionBootstrapScreenState();
}

class _SessionBootstrapScreenState extends State<SessionBootstrapScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _route());
  }

  Future<void> _route() async {
    final provider = context.read<RescueProvider>();
    await provider.loadCitizenProfile();
    final role = await provider.readPersistedRole();
    if (!mounted) return;

    if (role == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
      );
      return;
    }

    provider.setRole(role);

    switch (role) {
      case UserRole.citizen:
        final name = provider.citizenName;
        if (name != null && name.trim().isNotEmpty) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const SOSScreen()),
          );
        } else {
          await provider.clearPersistedSessionKeys();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
          );
        }
        break;
      case UserRole.responder:
        final loginId = await provider.readResponderUnitLoginId();
        final sessionId = await provider.readResponderSessionId();
        final unitId = await provider.readResponderSessionUnitId();
        if (!mounted) return;
        if (loginId == null ||
            loginId.isEmpty ||
            sessionId == null ||
            sessionId.isEmpty ||
            unitId == null ||
            unitId.isEmpty) {
          await provider.clearPersistedSessionKeys();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
          );
          return;
        }
        await provider.hydrateResponderSessionLock(
          loginId: loginId,
          responderUnitId: unitId,
          sessionId: sessionId,
        );
        final lockOk = await provider.ensureResponderSessionIsValid(unitId: unitId);
        if (!lockOk) {
          await provider.clearPersistedSessionKeys();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
          );
          return;
        }
        final roster = provider.rescueUnitsRoster
            .where((u) => u.id == unitId)
            .firstOrNull;
        if (roster == null) {
          await provider.clearPersistedSessionKeys();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const RoleSelectionScreen()),
          );
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => ResponderPendingApprovalScreen(rosterUnit: roster),
          ),
        );
        break;
      case UserRole.lguAdmin:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const LGUDashboardScreen()),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0D1B2A),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 16),
            Text(
              'Loading session…',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
