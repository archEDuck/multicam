import 'package:flutter/services.dart';

import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class MethodChannelStereoPreprocessRepository
    implements StereoPreprocessRepository {
  MethodChannelStereoPreprocessRepository({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('multicam/stereo_preprocess');

  final MethodChannel _channel;

  @override
  Future<StereoPreprocessResult> calibrateSession(String sessionDir) async {
    try {
      final dynamic raw = await _channel.invokeMethod('calibrateSession', {
        'sessionDir': sessionDir,
      });
      if (raw is Map) {
        return StereoPreprocessResult.fromMap(raw);
      }
      return StereoPreprocessResult.empty(
        'Kalibrasyon sonucu okunamadı (boş yanıt).',
      );
    } catch (e) {
      return StereoPreprocessResult.empty('Kalibrasyon hatası: $e');
    }
  }

  @override
  Future<StereoPreprocessResult> rectifySession(String sessionDir) async {
    try {
      final dynamic raw = await _channel.invokeMethod('rectifySession', {
        'sessionDir': sessionDir,
      });
      if (raw is Map) {
        return StereoPreprocessResult.fromMap(raw);
      }
      return StereoPreprocessResult.empty(
        'Rectify sonucu okunamadı (boş yanıt).',
      );
    } catch (e) {
      return StereoPreprocessResult.empty('Rectify hatası: $e');
    }
  }

  @override
  Future<StereoPreprocessResult> checkCheckerboard(
    String cam1ImagePath,
    String cam2ImagePath,
  ) async {
    try {
      final dynamic raw = await _channel.invokeMethod('checkCheckerboard', {
        'cam1Path': cam1ImagePath,
        'cam2Path': cam2ImagePath,
      });
      if (raw is Map) {
        return StereoPreprocessResult.fromMap(raw);
      }
      return StereoPreprocessResult.empty(
        'Checkerboard sonucu okunamadı (boş yanıt).',
      );
    } catch (e) {
      return StereoPreprocessResult.empty('Checkerboard kontrol hatası: $e');
    }
  }
}
