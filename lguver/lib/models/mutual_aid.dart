import 'barangay.dart';

class MutualAidRequest {
  final String id;
  final String sosId;
  final String fromBarangayId;
  final String toBarangayId;
  final String message;
  final List<String> unitTypes;
  final String status;
  final int createdAt;
  final int? respondedAt;
  final String createdBy;

  const MutualAidRequest({
    required this.id,
    required this.sosId,
    required this.fromBarangayId,
    required this.toBarangayId,
    required this.message,
    required this.unitTypes,
    required this.status,
    required this.createdAt,
    this.respondedAt,
    required this.createdBy,
  });

  bool get isPending => status == 'pending';

  Map<String, dynamic> toJson() => {
        'id': id,
        'sosId': sosId,
        'fromBarangayId': normalizeBarangayId(fromBarangayId),
        'toBarangayId': normalizeBarangayId(toBarangayId),
        'message': message,
        'unitTypes': unitTypes,
        'status': status,
        'createdAt': createdAt,
        if (respondedAt != null) 'respondedAt': respondedAt,
        'createdBy': createdBy,
      };

  factory MutualAidRequest.fromJson(String key, Map<dynamic, dynamic> json) {
    final types = <String>[];
    final raw = json['unitTypes'];
    if (raw is List) {
      for (final e in raw) {
        final t = e?.toString().trim() ?? '';
        if (t.isNotEmpty && !types.contains(t)) types.add(t);
      }
    }
    return MutualAidRequest(
      id: (json['id'] ?? key).toString(),
      sosId: json['sosId']?.toString() ?? '',
      fromBarangayId: normalizeBarangayId(json['fromBarangayId']?.toString()),
      toBarangayId: normalizeBarangayId(json['toBarangayId']?.toString()),
      message: json['message']?.toString() ?? '',
      unitTypes: types,
      status: json['status']?.toString() ?? 'pending',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      respondedAt: (json['respondedAt'] as num?)?.toInt(),
      createdBy: json['createdBy']?.toString() ?? '',
    );
  }
}
