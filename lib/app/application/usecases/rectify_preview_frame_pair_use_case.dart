import 'dart:typed_data';

import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/repositories/stereo_preprocess_repository.dart';

class RectifyPreviewFramePairUseCase {
  final StereoPreprocessRepository _repository;

  const RectifyPreviewFramePairUseCase(this._repository);

  Future<StereoPreprocessResult> call(
    Uint8List cam1Bytes,
    Uint8List cam2Bytes,
  ) {
    return _repository.rectifyFramePair(cam1Bytes, cam2Bytes);
  }
}
