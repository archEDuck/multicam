import 'dart:typed_data';

import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class BuildDepthMapFramePairUseCase {
  final StereoPreprocessRepository _repository;

  const BuildDepthMapFramePairUseCase(this._repository);

  Future<StereoPreprocessResult> call(
    Uint8List cam1Bytes,
    Uint8List cam2Bytes,
  ) {
    return _repository.depthFramePair(cam1Bytes, cam2Bytes);
  }
}
