import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class CalibrateStereoSessionUseCase {
  final StereoPreprocessRepository _repository;

  const CalibrateStereoSessionUseCase(this._repository);

  Future<StereoPreprocessResult> call(String sessionDir) {
    return _repository.calibrateSession(sessionDir);
  }
}
