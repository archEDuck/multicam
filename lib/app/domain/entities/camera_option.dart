class CameraOption {
  final String id;
  final String lensType;
  final double megapixels;
  final double focalMm;
  final String displayName;

  const CameraOption({
    required this.id,
    required this.lensType,
    required this.megapixels,
    required this.focalMm,
    required this.displayName,
  });

  factory CameraOption.fromMap(Map<dynamic, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    final id = (map['id']?.toString() ?? '').trim();
    final lensType = (map['lensType']?.toString() ?? '').trim();
    final megapixels = toDouble(map['megapixels']);
    final focalMm = toDouble(map['focalMm']);
    final displayName = (map['displayName']?.toString() ?? '').trim();

    return CameraOption(
      id: id,
      lensType: lensType,
      megapixels: megapixels,
      focalMm: focalMm,
      displayName: displayName,
    );
  }

  String get compactLabel {
    if (displayName.isNotEmpty) return displayName;
    final mpText = megapixels > 0 ? '${megapixels.toStringAsFixed(1)}MP' : '-';
    final focalText = focalMm > 0 ? '${focalMm.toStringAsFixed(1)}mm' : '-';
    final lensText = lensType.isNotEmpty ? lensType : 'Back';
    return '$lensText • $mpText • $focalText • id=$id';
  }
}
