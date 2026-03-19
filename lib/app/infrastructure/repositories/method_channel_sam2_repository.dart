import 'package:flutter/services.dart';

import '../../domain/entities/sam2_availability.dart';
import '../../domain/entities/sam2_segmentation_request.dart';
import '../../domain/entities/sam2_segmentation_result.dart';
import '../../domain/repositories/sam2_repository.dart';

class MethodChannelSam2Repository implements Sam2Repository {
  MethodChannelSam2Repository({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('multicam/sam2');

  final MethodChannel _channel;

  @override
  Future<Sam2Availability> getAvailability() async {
    try {
      final dynamic raw = await _channel.invokeMethod('getSam2Status');
      if (raw is Map) {
        return Sam2Availability.fromMap(raw);
      }
      return Sam2Availability.unavailable('SAM2 durumu okunamadı (boş yanıt).');
    } catch (error) {
      return Sam2Availability.unavailable('SAM2 durumu alınamadı: $error');
    }
  }

  @override
  Future<Sam2SegmentationResult> segmentFrame(
    Sam2SegmentationRequest request,
  ) async {
    try {
      final dynamic raw = await _channel.invokeMethod(
        'segmentFrame',
        request.toJson(),
      );
      if (raw is Map) {
        return Sam2SegmentationResult.fromMap(raw);
      }
      return Sam2SegmentationResult.empty(
        'SAM2 çıktısı okunamadı (boş yanıt).',
      );
    } catch (error) {
      return Sam2SegmentationResult.empty('SAM2 segmentasyon hatası: $error');
    }
  }
}
