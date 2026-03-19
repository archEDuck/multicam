import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class CheckCheckerboardFramePairUseCase {
  final StereoPreprocessRepository _repository;

  const CheckCheckerboardFramePairUseCase(this._repository);

  Future<StereoPreprocessResult> call(
    String cam1ImagePath,
    String cam2ImagePath,
  ) {
    return _repository.checkCheckerboard(cam1ImagePath, cam2ImagePath);
  }
}
