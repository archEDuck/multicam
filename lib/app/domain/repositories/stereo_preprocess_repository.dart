import 'dart:typed_data';

import '../entities/stereo_preprocess_result.dart';

abstract interface class StereoPreprocessRepository {
  Future<StereoPreprocessResult> calibrateSession(String sessionDir);

  Future<StereoPreprocessResult> rectifySession(String sessionDir);

  Future<StereoPreprocessResult> rectifyFramePair(
    Uint8List cam1Bytes,
    Uint8List cam2Bytes,
  );

  Future<StereoPreprocessResult> depthFramePair(
    Uint8List cam1Bytes,
    Uint8List cam2Bytes,
  );

  Future<StereoPreprocessResult> releaseDepthModel({String reason = 'manual'});

  Future<StereoPreprocessResult> getCalibrationStatus();

  Future<StereoPreprocessResult> checkCheckerboard(
    String cam1ImagePath,
    String cam2ImagePath,
  );
}
