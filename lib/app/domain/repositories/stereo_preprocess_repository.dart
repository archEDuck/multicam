import '../entities/stereo_preprocess_result.dart';

abstract interface class StereoPreprocessRepository {
  Future<StereoPreprocessResult> calibrateSession(String sessionDir);

  Future<StereoPreprocessResult> rectifySession(String sessionDir);
}
