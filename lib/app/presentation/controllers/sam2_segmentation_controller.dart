import 'package:flutter/foundation.dart';

import '../../application/usecases/get_sam2_availability_use_case.dart';
import '../../application/usecases/segment_sam2_frame_use_case.dart';
import '../../domain/entities/sam2_point.dart';
import '../../domain/entities/sam2_segmentation_request.dart';
import 'sam2_segmentation_state.dart';

class Sam2SegmentationController extends ChangeNotifier {
  Sam2SegmentationController({
    required GetSam2AvailabilityUseCase getAvailabilityUseCase,
    required SegmentSam2FrameUseCase segmentFrameUseCase,
  }) : _getAvailabilityUseCase = getAvailabilityUseCase,
       _segmentFrameUseCase = segmentFrameUseCase;

  final GetSam2AvailabilityUseCase _getAvailabilityUseCase;
  final SegmentSam2FrameUseCase _segmentFrameUseCase;

  Sam2SegmentationState _state = Sam2SegmentationState.initial();
  Sam2SegmentationState get state => _state;

  Future<void> loadAvailability() async {
    _state = _state.copyWith(isLoadingAvailability: true);
    notifyListeners();

    final availability = await _getAvailabilityUseCase();
    _state = _state.copyWith(
      availability: availability,
      isLoadingAvailability: false,
      statusMessage: availability.message,
    );
    notifyListeners();
  }

  void setTarget(Sam2PreviewTarget target) {
    if (_state.target == target) {
      return;
    }

    _state = _state.copyWith(
      target: target,
      points: const [],
      overlayBytes: Uint8List(0),
      score: 0,
      coverageRatio: 0,
      statusMessage: _state.availability.message,
    );
    notifyListeners();
  }

  void addPoint({
    required double x,
    required double y,
    required bool isPositive,
  }) {
    final nextPoints = List<Sam2Point>.from(_state.points)
      ..add(Sam2Point(x: x, y: y, isPositive: isPositive));

    _state = _state.copyWith(
      points: nextPoints,
      statusMessage:
          '${nextPoints.length} prompt noktası hazır. Segment için SAM2 çalıştırın.',
    );
    notifyListeners();
  }

  void removeLastPoint() {
    if (_state.points.isEmpty) {
      return;
    }

    final nextPoints = List<Sam2Point>.from(_state.points)..removeLast();
    _state = _state.copyWith(
      points: nextPoints,
      statusMessage: nextPoints.isEmpty
          ? _state.availability.message
          : '${nextPoints.length} prompt noktası kaldı.',
    );
    notifyListeners();
  }

  void clearSelection() {
    _state = _state.copyWith(
      points: const [],
      overlayBytes: Uint8List(0),
      score: 0,
      coverageRatio: 0,
      statusMessage: _state.availability.message,
    );
    notifyListeners();
  }

  Future<void> segmentFrame(Uint8List imageBytes) async {
    if (!_state.availability.isReady) {
      _state = _state.copyWith(statusMessage: _state.availability.message);
      notifyListeners();
      return;
    }

    if (_state.points.isEmpty) {
      _state = _state.copyWith(
        statusMessage: 'En az bir pozitif veya negatif nokta ekleyin.',
      );
      notifyListeners();
      return;
    }

    if (imageBytes.isEmpty) {
      _state = _state.copyWith(
        statusMessage: 'SAM2 için güncel preview karesi bulunamadı.',
      );
      notifyListeners();
      return;
    }

    _state = _state.copyWith(isSegmenting: true);
    notifyListeners();

    final result = await _segmentFrameUseCase(
      Sam2SegmentationRequest(imageBytes: imageBytes, points: _state.points),
    );

    _state = _state.copyWith(
      isSegmenting: false,
      overlayBytes: result.success ? result.overlayBytes : Uint8List(0),
      statusMessage: result.message,
      score: result.score,
      coverageRatio: result.coverageRatio,
    );
    notifyListeners();
  }
}
