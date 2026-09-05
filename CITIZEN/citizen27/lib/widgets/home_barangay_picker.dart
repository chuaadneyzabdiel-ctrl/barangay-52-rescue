import 'package:flutter/material.dart';

import '../models/barangay.dart';

class HomeBarangayPicker extends StatelessWidget {
  final String? value;
  final List<BarangayRecord> catalog;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const HomeBarangayPicker({
    super.key,
    required this.value,
    required this.catalog,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final items = catalog.isEmpty ? kBuiltInBarangays : catalog;
    return DropdownButtonFormField<String>(
      value: value != null && items.any((b) => b.id == value) ? value : null,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Home barangay',
      ),
      items: [
        for (final barangay in items)
          DropdownMenuItem<String>(
            value: barangay.id,
            enabled: barangay.isActive,
            child: Text(
              barangay.isActive
                  ? barangay.label
                  : '${barangay.label} (coming soon)',
              style: TextStyle(
                color: barangay.isActive ? Colors.white : Colors.white54,
              ),
            ),
          ),
      ],
      onChanged: enabled
          ? (next) {
              if (next == null) return;
              final match = items.where((b) => b.id == next).firstOrNull;
              if (match == null || !match.isActive) return;
              onChanged(next);
            }
          : null,
      validator: (v) {
        if (v == null || v.trim().isEmpty) {
          return 'Home barangay is required.';
        }
        final match = items.where((b) => b.id == v).firstOrNull;
        if (match == null || !match.isActive) {
          return 'Choose an active barangay.';
        }
        return null;
      },
    );
  }
}
