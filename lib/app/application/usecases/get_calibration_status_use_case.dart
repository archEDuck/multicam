import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class GetCalibrationStatusUseCase {
  final StereoPreprocessRepository _repository;

  const GetCalibrationStatusUseCase(this._repository);

  Future<StereoPreprocessResult> call() {
    return _repository.getCalibrationStatus();
  }
}
