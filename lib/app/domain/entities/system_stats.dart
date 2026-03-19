class SystemStats {
  final double cpuPercent;
  final double totalRamMB;
  final double usedRamMB;
  final double appHeapMB;
  final double appNativeMB;
  final double batteryTempC;

  const SystemStats({
    required this.cpuPercent,
    required this.totalRamMB,
    required this.usedRamMB,
    required this.appHeapMB,
    required this.appNativeMB,
    required this.batteryTempC,
  });

  factory SystemStats.empty() {
    return const SystemStats(
      cpuPercent: 0,
      totalRamMB: 0,
      usedRamMB: 0,
      appHeapMB: 0,
      appNativeMB: 0,
      batteryTempC: 0,
    );
  }

  factory SystemStats.fromMap(Map<dynamic, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    return SystemStats(
      cpuPercent: toDouble(map['cpuPercent']),
      totalRamMB: toDouble(map['totalRamMB']),
      usedRamMB: toDouble(map['usedRamMB']),
      appHeapMB: toDouble(map['appHeapMB']),
      appNativeMB: toDouble(map['appNativeMB']),
      batteryTempC: toDouble(map['batteryTempC']),
    );
  }
}
