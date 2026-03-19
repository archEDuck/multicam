import '../../domain/entities/sam2_segmentation_request.dart';
import '../../domain/entities/sam2_segmentation_result.dart';
import '../../domain/repositories/sam2_repository.dart';

class SegmentSam2FrameUseCase {
  final Sam2Repository _repository;

  const SegmentSam2FrameUseCase(this._repository);

  Future<Sam2SegmentationResult> call(Sam2SegmentationRequest request) {
    return _repository.segmentFrame(request);
  }
}
