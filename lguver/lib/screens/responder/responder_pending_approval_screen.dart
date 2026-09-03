import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/rescue_models.dart';
import '../../providers/rescue_provider.dart';
import '../session_bootstrap_screen.dart';
import 'dispatch_screen.dart';

/// After unit selection: wait for LGU approval if needed, then open dispatch.
class ResponderPendingApprovalScreen extends StatefulWidget {
  const ResponderPendingApprovalScreen({super.key, required this.rosterUnit});

  final RescueUnit rosterUnit;

  @override
  State<ResponderPendingApprovalScreen> createState() =>
      _ResponderPendingApprovalScreenState();
}

class _ResponderPendingApprovalScreenState
    extends State<ResponderPendingApprovalScreen> {
  Timer? _poll;
  StreamSubscription<bool>? _approvalSub;
  bool _waiting = false;
  bool _navigated = false;
  bool _revokedHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final provider = context.read<RescueProvider>();
    final lockOk = await provider.ensureResponderSessionIsValid(
      unitId: widget.rosterUnit.id,
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
    provider.setRole(UserRole.responder);
    await provider.refreshLocationStatus();
    provider.initLocation();
    provider.startFirebaseListeners();

    final pos = provider.currentPosition ?? widget.rosterUnit.position;
    final unit = RescueUnit(
      id: widget.rosterUnit.id,
      callSign: widget.rosterUnit.callSign,
      type: widget.rosterUnit.type,
      status: UnitStatus.idle,
      position: pos,
      stationId: widget.rosterUnit.stationId,
    );
    provider.setCurrentResponderUnit(unit);

    await provider.persistResponderSessionUnit(widget.rosterUnit.id);

    _approvalSub?.cancel();
    _approvalSub = provider.firebaseSync
        .watchResponderApproval(widget.rosterUnit.id)
        .listen((approved) async {
      if (!approved && mounted && !_revokedHandled) {
        _revokedHandled = true;
        _poll?.cancel();
        await provider.responderLogout(widget.rosterUnit.id);
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

    final approvedFirst = await provider.isResponderApproved(widget.rosterUnit.id);
    if (!mounted) return;

    if (approvedFirst) {
      await _tryEnterDispatch(provider, unit);
      return;
    }

    setState(() => _waiting = true);
    try {
      await provider.registerUnit(unit);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
      return;
    }
    if (!mounted) return;

    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _navigated) return;
      final ok = await provider.isResponderApproved(widget.rosterUnit.id);
      if (ok && mounted) {
        setState(() => _waiting = false);
        await _tryEnterDispatch(provider, unit);
      }
    });
  }

  Future<void> _tryEnterDispatch(RescueProvider provider, RescueUnit unit) async {
    if (_navigated) return;
    bool registered = false;
    try {
      registered = await provider.registerUnit(unit);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
      return;
    }
    if (!mounted) return;
    if (!registered) {
      setState(() => _waiting = true);
      return;
    }
    _navigated = true;
    _poll?.cancel();
    provider.startGpsUpload(unit.id, unit);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DispatchScreen(unitId: unit.id),
      ),
    );
  }

  /// Only this path clears the responder session (see Account Center).
  Future<void> _logout() async {
    _poll?.cancel();
    final provider = context.read<RescueProvider>();
    await provider.responderLogout(widget.rosterUnit.id);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const SessionBootstrapScreen()),
      (_) => false,
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _approvalSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B3A5C),
        foregroundColor: Colors.white,
        title: Text(widget.rosterUnit.callSign),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to unit selection',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, color: Colors.white70, size: 20),
            label: const Text('Log out', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_waiting) ...[
                const CircularProgressIndicator(color: Colors.white70),
                const SizedBox(height: 24),
                const Text(
                  'Waiting for LGU approval',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Your unit (${widget.rosterUnit.callSign}) must be approved before you can go online. '
                  'You can leave this screen and return later — your session is saved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 14),
                ),
              ] else ...[
                const CircularProgressIndicator(color: Colors.white70),
                const SizedBox(height: 16),
                Text(
                  'Loading…',
                  style: TextStyle(color: Colors.grey[400], fontSize: 14),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
