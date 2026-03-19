class AppSettings {
  static const int defaultCaptureIntervalMs = 700;
  static const int defaultStatsPollIntervalMs = 1000;
  static const String defaultSessionMode = 'Normal';
  static const String defaultViewMode = 'Çift Kamera';
  static const String defaultTargetIp = '188.191.107.81';

  static const List<String> sessionModes = <String>[
    'Normal',
    'Kalibrasyon',
    'Kalibreli',
    '3D Orbit Tarama',
  ];

  static const List<String> viewModes = <String>[
    'Çift Kamera',
    'Tek Kamera (Kam 1)',
    'Tek Kamera (Kam 2)',
  ];

  static const Object _unset = Object();

  final int? captureIntervalMs;
  final int? statsPollIntervalMs;
  final String? sessionMode;
  final String? viewMode;
  final String? targetIp;

  final bool? autoZipOnStop;
  final bool? autoUploadOnStop;
  final bool? enableStats;
  final bool? enableImu;
  final bool? enableFot;
  final bool? autoSelectCameraPair;

  const AppSettings({
    this.captureIntervalMs,
    this.statsPollIntervalMs,
    this.sessionMode,
    this.viewMode,
    this.targetIp,
    this.autoZipOnStop,
    this.autoUploadOnStop,
    this.enableStats,
    this.enableImu,
    this.enableFot,
    this.autoSelectCameraPair,
  });

  factory AppSettings.defaults() {
    return const AppSettings(
      captureIntervalMs: defaultCaptureIntervalMs,
      statsPollIntervalMs: defaultStatsPollIntervalMs,
      sessionMode: defaultSessionMode,
      viewMode: defaultViewMode,
      targetIp: defaultTargetIp,
      autoZipOnStop: false,
      autoUploadOnStop: false,
      enableStats: true,
      enableImu: true,
      enableFot: true,
      autoSelectCameraPair: true,
    );
  }

  int get effectiveCaptureIntervalMs {
    final value = captureIntervalMs ?? defaultCaptureIntervalMs;
    return value.clamp(20, 2000).toInt();
  }

  int get effectiveStatsPollIntervalMs {
    final value = statsPollIntervalMs ?? defaultStatsPollIntervalMs;
    return value.clamp(500, 5000).toInt();
  }

  String get effectiveSessionMode {
    final value = sessionMode;
    if (value == null || !sessionModes.contains(value)) {
      return defaultSessionMode;
    }
    return value;
  }

  String get effectiveViewMode {
    final value = viewMode;
    if (value == null || !viewModes.contains(value)) {
      return defaultViewMode;
    }
    return value;
  }

  String get effectiveTargetIp {
    final value = targetIp?.trim();
    return value ?? '';
  }

  bool get effectiveAutoZipOnStop => autoZipOnStop ?? true;
  bool get effectiveAutoUploadOnStop => autoUploadOnStop ?? true;
  bool get effectiveEnableStats => enableStats ?? true;
  bool get effectiveEnableImu => enableImu ?? true;
  bool get effectiveEnableFot => enableFot ?? true;
  bool get effectiveAutoSelectCameraPair => autoSelectCameraPair ?? true;

  AppSettings copyWith({
    Object? captureIntervalMs = _unset,
    Object? statsPollIntervalMs = _unset,
    Object? sessionMode = _unset,
    Object? viewMode = _unset,
    Object? targetIp = _unset,
    Object? autoZipOnStop = _unset,
    Object? autoUploadOnStop = _unset,
    Object? enableStats = _unset,
    Object? enableImu = _unset,
    Object? enableFot = _unset,
    Object? autoSelectCameraPair = _unset,
  }) {
    return AppSettings(
      captureIntervalMs: captureIntervalMs == _unset
          ? this.captureIntervalMs
          : captureIntervalMs as int?,
      statsPollIntervalMs: statsPollIntervalMs == _unset
          ? this.statsPollIntervalMs
          : statsPollIntervalMs as int?,
      sessionMode: sessionMode == _unset
          ? this.sessionMode
          : sessionMode as String?,
      viewMode: viewMode == _unset ? this.viewMode : viewMode as String?,
      targetIp: targetIp == _unset ? this.targetIp : targetIp as String?,
      autoZipOnStop: autoZipOnStop == _unset
          ? this.autoZipOnStop
          : autoZipOnStop as bool?,
      autoUploadOnStop: autoUploadOnStop == _unset
          ? this.autoUploadOnStop
          : autoUploadOnStop as bool?,
      enableStats: enableStats == _unset
          ? this.enableStats
          : enableStats as bool?,
      enableImu: enableImu == _unset ? this.enableImu : enableImu as bool?,
      enableFot: enableFot == _unset ? this.enableFot : enableFot as bool?,
      autoSelectCameraPair: autoSelectCameraPair == _unset
          ? this.autoSelectCameraPair
          : autoSelectCameraPair as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'captureIntervalMs': captureIntervalMs,
      'statsPollIntervalMs': statsPollIntervalMs,
      'sessionMode': sessionMode,
      'viewMode': viewMode,
      'targetIp': targetIp,
      'autoZipOnStop': autoZipOnStop,
      'autoUploadOnStop': autoUploadOnStop,
      'enableStats': enableStats,
      'enableImu': enableImu,
      'enableFot': enableFot,
      'autoSelectCameraPair': autoSelectCameraPair,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      captureIntervalMs: _asInt(json['captureIntervalMs']),
      statsPollIntervalMs: _asInt(json['statsPollIntervalMs']),
      sessionMode: json['sessionMode']?.toString(),
      viewMode: json['viewMode']?.toString(),
      targetIp: json['targetIp']?.toString(),
      autoZipOnStop: _asBool(json['autoZipOnStop']),
      autoUploadOnStop: _asBool(json['autoUploadOnStop']),
      enableStats: _asBool(json['enableStats']),
      enableImu: _asBool(json['enableImu']),
      enableFot: _asBool(json['enableFot']),
      autoSelectCameraPair: _asBool(json['autoSelectCameraPair']),
    );
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return null;
  }
}
