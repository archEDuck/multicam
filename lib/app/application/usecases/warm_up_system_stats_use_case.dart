import '../../domain/repositories/system_stats_repository.dart';

class WarmUpSystemStatsUseCase {
  final SystemStatsRepository _repository;

  const WarmUpSystemStatsUseCase(this._repository);

  Future<void> call() {
    return _repository.warmUp();
  }
}
