import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:multicam/app/application/usecases/get_sam2_availability_use_case.dart';
import 'package:multicam/app/application/usecases/segment_sam2_frame_use_case.dart';
import 'package:multicam/app/domain/entities/sam2_availability.dart';
import 'package:multicam/app/domain/entities/sam2_segmentation_request.dart';
import 'package:multicam/app/domain/entities/sam2_segmentation_result.dart';
import 'package:multicam/app/domain/repositories/sam2_repository.dart';
import 'package:multicam/app/presentation/controllers/sam2_segmentation_controller.dart';
import 'package:multicam/app/presentation/controllers/sam2_segmentation_state.dart';

void main() {
  late _FakeSam2Repository repository;
  late Sam2SegmentationController controller;

  setUp(() {
    repository = _FakeSam2Repository();
    controller = Sam2SegmentationController(
      getAvailabilityUseCase: GetSam2AvailabilityUseCase(repository),
      segmentFrameUseCase: SegmentSam2FrameUseCase(repository),
    );
  });

  test('availability yüklenince state güncellenir', () async {
    await controller.loadAvailability();

    expect(controller.state.availability.isReady, isTrue);
    expect(controller.state.statusMessage, 'SAM2 hazır.');
  });

  test('prompt ekleme ve silme state üzerinden yönetilir', () {
    controller.addPoint(x: 120, y: 80, isPositive: true);
    controller.addPoint(x: 90, y: 45, isPositive: false);

    expect(controller.state.points.length, 2);
    expect(controller.state.points.last.isPositive, isFalse);

    controller.removeLastPoint();

    expect(controller.state.points.length, 1);
    expect(controller.state.points.single.isPositive, isTrue);
  });

  test('nokta yoksa repository çağrılmaz', () async {
    await controller.loadAvailability();
    await controller.segmentFrame(Uint8List.fromList([1, 2, 3]));

    expect(repository.segmentCallCount, 0);
    expect(
      controller.state.statusMessage,
      'En az bir pozitif veya negatif nokta ekleyin.',
    );
  });

  test('başarılı segmentasyon overlay ve skor bilgisi üretir', () async {
    await controller.loadAvailability();
    controller.addPoint(x: 320, y: 240, isPositive: true);

    await controller.segmentFrame(Uint8List.fromList([7, 8, 9]));

    expect(repository.segmentCallCount, 1);
    expect(controller.state.hasOverlay, isTrue);
    expect(controller.state.score, closeTo(0.91, 0.0001));
    expect(controller.state.coverageRatio, closeTo(0.23, 0.0001));
    expect(controller.state.statusMessage, 'SAM2 segmentasyonu tamamlandı.');
  });

  test('target değişince selection ve overlay temizlenir', () async {
    await controller.loadAvailability();
    controller.addPoint(x: 15, y: 12, isPositive: true);
    await controller.segmentFrame(Uint8List.fromList([3, 4, 5]));

    controller.setTarget(Sam2PreviewTarget.camera2);

    expect(controller.state.target, Sam2PreviewTarget.camera2);
    expect(controller.state.points, isEmpty);
    expect(controller.state.hasOverlay, isFalse);
  });
}

class _FakeSam2Repository implements Sam2Repository {
  int segmentCallCount = 0;

  @override
  Future<Sam2Availability> getAvailability() async {
    return const Sam2Availability(
      isReady: true,
      message: 'SAM2 hazır.',
      modelDirectory: '/tmp/models',
      encoderPath: '/tmp/models/encoder.onnx',
      decoderPath: '/tmp/models/decoder.onnx',
    );
  }

  @override
  Future<Sam2SegmentationResult> segmentFrame(
    Sam2SegmentationRequest request,
  ) async {
    segmentCallCount += 1;
    return Sam2SegmentationResult(
      success: true,
      message: 'SAM2 segmentasyonu tamamlandı.',
      overlayBytes: Uint8List.fromList([1, 2, 3, 4]),
      score: 0.91,
      coverageRatio: 0.23,
      imageWidth: 1920,
      imageHeight: 1080,
    );
  }
}
