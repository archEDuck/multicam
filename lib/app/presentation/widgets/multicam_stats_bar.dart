import 'package:flutter/material.dart';

import '../../domain/entities/system_stats.dart';

class MulticamStatsBar extends StatelessWidget {
  const MulticamStatsBar({
    super.key,
    required this.stats,
    required this.actualFps,
  });

  final SystemStats stats;
  final double actualFps;

  @override
  Widget build(BuildContext context) {
    final ramPercent = stats.totalRamMB > 0
        ? (stats.usedRamMB / stats.totalRamMB * 100)
        : 0.0;
    final fpsText = actualFps > 0 ? actualFps.toStringAsFixed(1) : '-';
    final appMem = (stats.appHeapMB + stats.appNativeMB);
    final tempText = stats.batteryTempC > 0
        ? '${stats.batteryTempC.toStringAsFixed(1)}°C'
        : '-';

    return Container(
      width: double.infinity,
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _statChip(
            Icons.speed,
            'FPS',
            fpsText,
            actualFps > 0 && actualFps < 1.0 ? Colors.red : Colors.greenAccent,
          ),
          const SizedBox(width: 12),
          _statChip(
            Icons.memory,
            'CPU',
            '${stats.cpuPercent.toStringAsFixed(1)}%',
            stats.cpuPercent > 80
                ? Colors.red
                : stats.cpuPercent > 50
                ? Colors.orange
                : Colors.greenAccent,
          ),
          const SizedBox(width: 12),
          _statChip(
            Icons.storage,
            'RAM',
            '${stats.usedRamMB.toStringAsFixed(0)}/${stats.totalRamMB.toStringAsFixed(0)} MB (${ramPercent.toStringAsFixed(0)}%)',
            ramPercent > 85
                ? Colors.red
                : ramPercent > 70
                ? Colors.orange
                : Colors.greenAccent,
          ),
          const SizedBox(width: 12),
          _statChip(
            Icons.thermostat,
            'TEMP',
            tempText,
            stats.batteryTempC > 40
                ? Colors.orange
                : stats.batteryTempC > 0
                ? Colors.greenAccent
                : Colors.white54,
          ),
          const SizedBox(width: 12),
          _statChip(
            Icons.apps,
            'App',
            '${appMem.toStringAsFixed(1)} MB',
            appMem > 200 ? Colors.orange : Colors.greenAccent,
          ),
        ],
      ),
    );
  }

  Widget _statChip(
    IconData icon,
    String label,
    String value,
    Color valueColor,
  ) {
    return Expanded(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white54, size: 14),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              '$label: $value',
              style: TextStyle(
                color: valueColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
