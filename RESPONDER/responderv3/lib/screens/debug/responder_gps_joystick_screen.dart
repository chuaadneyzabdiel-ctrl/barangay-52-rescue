import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/rescue_provider.dart';

/// Debug-only on-screen joystick to spoof a responder unit GPS for waypoint tests.
///
/// Not shown in release builds. Spoof stays off until explicitly enabled here.
class ResponderGpsJoystickScreen extends StatefulWidget {
  const ResponderGpsJoystickScreen({super.key});

  @override
  State<ResponderGpsJoystickScreen> createState() =>
      _ResponderGpsJoystickScreenState();
}

class _ResponderGpsJoystickScreenState extends State<ResponderGpsJoystickScreen> {
  String? _selectedUnitId;
  Timer? _stickTimer;
  Offset _stick = Offset.zero;
  DateTime? _lastTick;

  @override
  void initState() {
    super.initState();
    if (!kDebugMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<RescueProvider>();
      provider.startFirebaseListeners();
      final preferred = provider.gpsSpoofUnitId ??
          provider.currentResponderUnit?.id ??
          provider.currentResponderSessionUnitId ??
          provider.spoofableResponderUnits.firstOrNull?.id;
      if (preferred != null && mounted) {
        setState(() => _selectedUnitId = preferred);
      }
    });
  }

  @override
  void dispose() {
    _stickTimer?.cancel();
    super.dispose();
  }

  void _startStickLoop() {
    _stickTimer?.cancel();
    _lastTick = DateTime.now();
    _stickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final last = _lastTick ?? now;
      _lastTick = now;
      final dt = now.difference(last).inMilliseconds / 1000.0;
      if (_stick.distance < 0.08) return;
      context.read<RescueProvider>().applyGpsSpoofStick(
            stickX: _stick.dx,
            stickY: _stick.dy,
            dtSeconds: dt.clamp(0.01, 0.2),
          );
    });
  }

  void _stopStickLoop() {
    _stickTimer?.cancel();
    _stickTimer = null;
    _lastTick = null;
    _stick = Offset.zero;
  }

  Future<void> _toggleSpoof(RescueProvider provider, bool on) async {
    try {
      if (on) {
        final id = _selectedUnitId;
        if (id == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Pick a responder unit first.')),
          );
          return;
        }
        await provider.enableGpsSpoof(id);
      } else {
        await provider.disableGpsSpoof();
        _stopStickLoop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      return const Scaffold(
        body: Center(child: Text('Debug only')),
      );
    }

    return Consumer<RescueProvider>(
      builder: (context, provider, _) {
        final units = provider.spoofableResponderUnits;
        final selectedId = () {
          if (_selectedUnitId != null &&
              units.any((u) => u.id == _selectedUnitId)) {
            return _selectedUnitId;
          }
          return units.firstOrNull?.id;
        }();
        if (selectedId != _selectedUnitId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedUnitId = selectedId);
          });
        }
        final spoofOn = provider.isGpsSpoofEnabled;
        final pos = provider.gpsSpoofPosition;
        final speed = provider.gpsSpoofSpeedKmh;
        final spoofError = provider.lastGpsSpoofError;

        return Scaffold(
          backgroundColor: const Color(0xFF0D1B2A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF1B3A5C),
            foregroundColor: Colors.white,
            title: const Text('Responder GPS joystick'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orangeAccent),
                ),
                child: const Text(
                  'DEBUG ONLY — writes Firebase unit_locations so citizen/LGU maps '
                  'see the same pin. Spoof the unit that accepted the SOS. '
                  'Keep other responder tabs for that unit closed (spoof lock blocks their GPS).',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
                ),
              ),
              if (spoofError != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: Text(
                    'Firebase write failed: $spoofError',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),
              ],
              if (spoofOn && provider.lastGpsSpoofPushAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Last Firebase push: ${provider.lastGpsSpoofPushAt!.toLocal().toIso8601String().substring(11, 19)}',
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                'Responder unit',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
              const SizedBox(height: 8),
              if (units.isEmpty)
                Text(
                  'No units in roster yet. Open the app online so Firebase loads.',
                  style: TextStyle(color: Colors.grey[500]),
                )
              else
                DropdownButtonFormField<String>(
                  value: selectedId,
                  dropdownColor: const Color(0xFF1B3A5C),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Color(0xFF1B2838),
                  ),
                  items: [
                    for (final u in units)
                      DropdownMenuItem(
                        value: u.id,
                        child: Text(
                          '${u.callSign}  (${provider.isUnitOnline(u.id) ? 'live' : 'roster'})',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                  onChanged: spoofOn
                      ? null
                      : (v) => setState(() => _selectedUnitId = v),
                ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Spoof GPS',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  spoofOn
                      ? 'ON — device GPS ignored for this unit'
                      : 'OFF — real GPS / normal uploads',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                value: spoofOn,
                activeThumbColor: Colors.greenAccent,
                onChanged: (v) => _toggleSpoof(provider, v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await provider.resetGpsSpoofToReal();
                        _stopStickLoop();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.gps_fixed, color: Colors.white70),
                      label: const Text(
                        'Reset to real GPS',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Speed: ${speed.toStringAsFixed(0)} km/h',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              Slider(
                value: speed,
                min: 5,
                max: 100,
                divisions: 19,
                label: '${speed.toStringAsFixed(0)} km/h',
                onChanged: spoofOn
                    ? (v) => provider.setGpsSpoofSpeedKmh(v)
                    : null,
              ),
              Text(
                'How fast the icon moves while you hold the joystick.',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
              const SizedBox(height: 16),
              if (pos != null) ...[
                Text(
                  'Spoofed position',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}',
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 12),
              Center(
                child: Opacity(
                  opacity: spoofOn ? 1 : 0.35,
                  child: _JoystickPad(
                    enabled: spoofOn,
                    onChanged: (o) {
                      _stick = o;
                      if (o.distance >= 0.08) {
                        _startStickLoop();
                      } else {
                        _stopStickLoop();
                      }
                    },
                    onReleased: _stopStickLoop,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                spoofOn
                    ? 'Hold and drag to drive the unit. Release to stop.'
                    : 'Turn Spoof GPS ON to use the joystick.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
              const SizedBox(height: 24),
              _Dpad(
                enabled: spoofOn,
                onNudge: (north, east) {
                  context.read<RescueProvider>().nudgeGpsSpoof(
                        northMeters: north,
                        eastMeters: east,
                      );
                },
                stepMeters: max(5.0, speed * 1000 / 3600 * 0.5),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _JoystickPad extends StatefulWidget {
  const _JoystickPad({
    required this.enabled,
    required this.onChanged,
    required this.onReleased,
  });

  final bool enabled;
  final ValueChanged<Offset> onChanged;
  final VoidCallback onReleased;

  @override
  State<_JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<_JoystickPad> {
  Offset _knob = Offset.zero;
  static const double _size = 200;
  static const double _knobSize = 64;
  static const double _maxTravel = (_size - _knobSize) / 2;

  void _update(Offset local) {
    if (!widget.enabled) return;
    final center = const Offset(_size / 2, _size / 2);
    var delta = local - center;
    if (delta.distance > _maxTravel) {
      delta = Offset.fromDirection(delta.direction, _maxTravel);
    }
    setState(() => _knob = delta);
    widget.onChanged(Offset(delta.dx / _maxTravel, delta.dy / _maxTravel));
  }

  void _end() {
    setState(() => _knob = Offset.zero);
    widget.onChanged(Offset.zero);
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: GestureDetector(
        onPanStart: (d) => _update(d.localPosition),
        onPanUpdate: (d) => _update(d.localPosition),
        onPanEnd: (_) => _end(),
        onPanCancel: _end,
        child: CustomPaint(
          painter: _JoystickPainter(knob: _knob),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({required this.knob});
  final Offset knob;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final base = Paint()..color = const Color(0xFF1B3A5C);
    final ring = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, size.width / 2 - 4, base);
    canvas.drawCircle(center, size.width / 2 - 4, ring);
    final knobPaint = Paint()..color = const Color(0xFF2ECC71);
    canvas.drawCircle(center + knob, 32, knobPaint);
    canvas.drawCircle(
      center + knob,
      32,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) =>
      oldDelegate.knob != knob;
}

class _Dpad extends StatelessWidget {
  const _Dpad({
    required this.enabled,
    required this.onNudge,
    required this.stepMeters,
  });

  final bool enabled;
  final void Function(double northMeters, double eastMeters) onNudge;
  final double stepMeters;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, double n, double e) {
      return IconButton.filled(
        onPressed: enabled ? () => onNudge(n, e) : null,
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF1B3A5C),
          disabledBackgroundColor: Colors.white10,
        ),
        icon: Icon(icon, color: Colors.white),
      );
    }

    final s = stepMeters;
    return Column(
      children: [
        Text(
          'Tap nudge (~${s.toStringAsFixed(0)} m)',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
        const SizedBox(height: 8),
        btn(Icons.keyboard_arrow_up, s, 0),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            btn(Icons.keyboard_arrow_left, 0, -s),
            const SizedBox(width: 48),
            btn(Icons.keyboard_arrow_right, 0, s),
          ],
        ),
        btn(Icons.keyboard_arrow_down, -s, 0),
      ],
    );
  }
}
