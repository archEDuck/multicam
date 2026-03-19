import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class RectifyStereoSessionUseCase {
  final StereoPreprocessRepository _repository;

  const RectifyStereoSessionUseCase(this._repository);

  Future<StereoPreprocessResult> call(String sessionDir) {
    return _repository.rectifySession(sessionDir);
  }
}
