import 'dart:typed_data';

import 'sam2_point.dart';

class Sam2SegmentationRequest {
  final Uint8List imageBytes;
  final List<Sam2Point> points;

  const Sam2SegmentationRequest({
    required this.imageBytes,
    required this.points,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'imageBytes': imageBytes,
      'points': points.map((point) => point.toJson()).toList(growable: false),
    };
  }
}
