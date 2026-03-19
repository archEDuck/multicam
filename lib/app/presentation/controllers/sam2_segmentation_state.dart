import 'dart:typed_data';

import '../../domain/entities/sam2_availability.dart';
import '../../domain/entities/sam2_point.dart';

enum Sam2PreviewTarget { camera1, camera2 }

class Sam2SegmentationState {
  final Sam2Availability availability;
  final Sam2PreviewTarget target;
  final List<Sam2Point> points;
  final Uint8List overlayBytes;
  final bool isLoadingAvailability;
  final bool isSegmenting;
  final String statusMessage;
  final double score;
  final double coverageRatio;

  const Sam2SegmentationState({
    required this.availability,
    required this.target,
    required this.points,
    required this.overlayBytes,
    required this.isLoadingAvailability,
    required this.isSegmenting,
    required this.statusMessage,
    required this.score,
    required this.coverageRatio,
  });

  factory Sam2SegmentationState.initial() {
    return Sam2SegmentationState(
      availability: Sam2Availability.unavailable(
        'SAM2 durumu henüz yüklenmedi.',
      ),
      target: Sam2PreviewTarget.camera1,
      points: const [],
      overlayBytes: Uint8List(0),
      isLoadingAvailability: false,
      isSegmenting: false,
      statusMessage: 'SAM2 hazır değil.',
      score: 0,
      coverageRatio: 0,
    );
  }

  bool get hasOverlay => overlayBytes.isNotEmpty;

  Sam2SegmentationState copyWith({
    Sam2Availability? availability,
    Sam2PreviewTarget? target,
    List<Sam2Point>? points,
    Uint8List? overlayBytes,
    bool? isLoadingAvailability,
    bool? isSegmenting,
    String? statusMessage,
    double? score,
    double? coverageRatio,
  }) {
    return Sam2SegmentationState(
      availability: availability ?? this.availability,
      target: target ?? this.target,
      points: points ?? this.points,
      overlayBytes: overlayBytes ?? this.overlayBytes,
      isLoadingAvailability:
          isLoadingAvailability ?? this.isLoadingAvailability,
      isSegmenting: isSegmenting ?? this.isSegmenting,
      statusMessage: statusMessage ?? this.statusMessage,
      score: score ?? this.score,
      coverageRatio: coverageRatio ?? this.coverageRatio,
    );
  }
}
