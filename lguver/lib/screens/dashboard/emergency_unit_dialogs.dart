import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/rescue_models.dart';
import '../../providers/rescue_provider.dart';

String emergencyUnitTypeLabel(UnitType type) {
  return switch (type) {
    UnitType.ambulance => 'Ambulance',
    UnitType.fireTruck => 'Fire truck',
    UnitType.policeUnit => 'Police',
    UnitType.rescue => 'Barangay Tanod',
  };
}

Future<void> promptAddEmergencyUnit(BuildContext context) async {
  final callSignController = TextEditingController();
  UnitType selectedType = UnitType.ambulance;
  try {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text('Add emergency unit'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: callSignController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Call sign',
                    hintText: 'e.g. FIRE-02',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UnitType>(
                  value: selectedType,
                  decoration: const InputDecoration(labelText: 'Unit type'),
                  items: [
                    for (final t in UnitType.values)
                      if (t != UnitType.policeUnit)
                        DropdownMenuItem(
                          value: t,
                          child: Text(emergencyUnitTypeLabel(t)),
                        ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setStateDialog(() => selectedType = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final unit = await context.read<RescueProvider>().createEmergencyUnit(
          callSign: callSignController.text,
          type: selectedType,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${unit.callSign} added. Set status to In service when ready.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    }
  } finally {
    callSignController.dispose();
  }
}

Future<void> promptDeleteEmergencyUnit(
  BuildContext context,
  RescueUnit unit,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete emergency unit?'),
      content: Text(
        'Remove ${unit.callSign} from the roster? '
        'It will disappear from the homepage. '
        'Responder logins mapped to this unit will also be deleted.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await context.read<RescueProvider>().deleteEmergencyUnit(unitId: unit.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${unit.callSign} deleted.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    }
  }
}
