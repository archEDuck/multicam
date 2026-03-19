import '../entities/system_stats.dart';

abstract interface class SystemStatsRepository {
  Future<void> warmUp();
  Future<SystemStats> fetch();
}
