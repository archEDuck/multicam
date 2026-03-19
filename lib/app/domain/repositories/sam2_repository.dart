import '../entities/sam2_availability.dart';
import '../entities/sam2_segmentation_request.dart';
import '../entities/sam2_segmentation_result.dart';

abstract interface class Sam2Repository {
  Future<Sam2Availability> getAvailability();

  Future<Sam2SegmentationResult> segmentFrame(Sam2SegmentationRequest request);
}
