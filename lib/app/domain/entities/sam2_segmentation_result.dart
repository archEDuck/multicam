import 'dart:typed_data';

class Sam2SegmentationResult {
  final bool success;
  final String message;
  final Uint8List overlayBytes;
  final double score;
  final double coverageRatio;
  final int imageWidth;
  final int imageHeight;

  const Sam2SegmentationResult({
    required this.success,
    required this.message,
    required this.overlayBytes,
    required this.score,
    required this.coverageRatio,
    required this.imageWidth,
    required this.imageHeight,
  });

  factory Sam2SegmentationResult.empty(String message) {
    return Sam2SegmentationResult(
      success: false,
      message: message,
      overlayBytes: Uint8List(0),
      score: 0,
      coverageRatio: 0,
      imageWidth: 0,
      imageHeight: 0,
    );
  }

  factory Sam2SegmentationResult.fromMap(Map<dynamic, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    int toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    final overlay = map['overlayBytes'];

    return Sam2SegmentationResult(
      success: map['success'] == true,
      message: (map['message']?.toString() ?? '').trim(),
      overlayBytes: overlay is Uint8List ? overlay : Uint8List(0),
      score: toDouble(map['score']),
      coverageRatio: toDouble(map['coverageRatio']),
      imageWidth: toInt(map['imageWidth']),
      imageHeight: toInt(map['imageHeight']),
    );
  }

  Sam2SegmentationResult copyWith({
    bool? success,
    String? message,
    Uint8List? overlayBytes,
    double? score,
    double? coverageRatio,
    int? imageWidth,
    int? imageHeight,
  }) {
    return Sam2SegmentationResult(
      success: success ?? this.success,
      message: message ?? this.message,
      overlayBytes: overlayBytes ?? this.overlayBytes,
      score: score ?? this.score,
      coverageRatio: coverageRatio ?? this.coverageRatio,
      imageWidth: imageWidth ?? this.imageWidth,
      imageHeight: imageHeight ?? this.imageHeight,
    );
  }
}
