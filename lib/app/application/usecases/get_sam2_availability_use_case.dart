import '../../domain/entities/sam2_availability.dart';
import '../../domain/repositories/sam2_repository.dart';

class GetSam2AvailabilityUseCase {
  final Sam2Repository _repository;

  const GetSam2AvailabilityUseCase(this._repository);

  Future<Sam2Availability> call() {
    return _repository.getAvailability();
  }
}
