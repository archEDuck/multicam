import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class ReleaseDepthModelUseCase {
  final StereoPreprocessRepository _repository;

  const ReleaseDepthModelUseCase(this._repository);

  Future<StereoPreprocessResult> call({String reason = 'manual'}) {
    return _repository.releaseDepthModel(reason: reason);
  }
}
