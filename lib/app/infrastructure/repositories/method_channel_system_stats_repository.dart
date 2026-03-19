import 'package:flutter/services.dart';

import '../../domain/entities/system_stats.dart';
import '../../domain/repositories/system_stats_repository.dart';

class MethodChannelSystemStatsRepository implements SystemStatsRepository {
  MethodChannelSystemStatsRepository(this._channel);

  final MethodChannel _channel;

  @override
  Future<void> warmUp() async {
    try {
      await _channel.invokeMethod('getSystemStats');
    } catch (_) {
      // ignore warmup errors
    }
  }

  @override
  Future<SystemStats> fetch() async {
    try {
      final dynamic raw = await _channel.invokeMethod('getSystemStats');
      if (raw is Map) {
        return SystemStats.fromMap(raw);
      }
      return SystemStats.empty();
    } catch (_) {
      return SystemStats.empty();
    }
  }
}
