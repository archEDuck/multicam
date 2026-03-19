import '../../domain/entities/system_stats.dart';
import '../../domain/repositories/system_stats_repository.dart';

class GetSystemStatsUseCase {
  final SystemStatsRepository _repository;

  const GetSystemStatsUseCase(this._repository);

  Future<SystemStats> call() {
    return _repository.fetch();
  }
}
