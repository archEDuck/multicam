import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'app/application/usecases/calibrate_stereo_session_use_case.dart';
import 'app/application/usecases/check_checkerboard_frame_pair_use_case.dart';
import 'app/application/usecases/build_depth_map_frame_pair_use_case.dart';
import 'app/application/usecases/get_calibration_status_use_case.dart';
import 'app/application/usecases/get_system_stats_use_case.dart';
import 'app/application/usecases/load_app_settings_use_case.dart';
import 'app/application/usecases/rectify_preview_frame_pair_use_case.dart';
import 'app/application/usecases/save_app_settings_use_case.dart';
import 'app/application/usecases/warm_up_system_stats_use_case.dart';
import 'app/domain/entities/app_settings.dart';
import 'app/domain/entities/capture_workflow_phase.dart';
import 'app/domain/entities/stereo_preprocess_result.dart';
import 'app/domain/entities/system_stats.dart';
import 'app/infrastructure/repositories/json_app_settings_repository.dart';
import 'app/infrastructure/repositories/method_channel_stereo_preprocess_repository.dart';
import 'app/infrastructure/repositories/method_channel_system_stats_repository.dart';
import 'app/presentation/controllers/settings_controller.dart';
import 'app/presentation/widgets/multicam_stats_bar.dart';
import 'camera2_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Multicam Stereo Pipeline',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const MultiCamPage(),
    );
  }
}

class _CameraOption {
  final String id;
  final String lensType;
  final double megapixels;
  final double focalMm;
  final String displayName;

  const _CameraOption({
    required this.id,
    required this.lensType,
    required this.megapixels,
    required this.focalMm,
    required this.displayName,
  });

  factory _CameraOption.fromMap(Map<dynamic, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    final id = (map['id']?.toString() ?? '').trim();
    final lensType = (map['lensType']?.toString() ?? '').trim();
    final megapixels = toDouble(map['megapixels']);
    final focalMm = toDouble(map['focalMm']);
    final displayName = (map['displayName']?.toString() ?? '').trim();

    return _CameraOption(
      id: id,
      lensType: lensType,
      megapixels: megapixels,
      focalMm: focalMm,
      displayName: displayName,
    );
  }

  String get compactLabel {
    if (displayName.isNotEmpty) return displayName;
    final mpText = megapixels > 0 ? '${megapixels.toStringAsFixed(1)}MP' : '-';
    final focalText = focalMm > 0 ? '${focalMm.toStringAsFixed(1)}mm' : '-';
    final lensText = lensType.isNotEmpty ? lensType : 'Back';
    return '$lensText • $mpText • $focalText • id=$id';
  }
}

class MultiCamPage extends StatefulWidget {
  const MultiCamPage({super.key});

  @override
  State<MultiCamPage> createState() => _MultiCamPageState();
}

class _MultiCamPageState extends State<MultiCamPage> {
  static const EventChannel _fotSensorChannel = EventChannel(
    'multicam/fot_sensor',
  );
  static const MethodChannel _systemStatsChannel = MethodChannel(
    'multicam/system_stats',
  );
  static const int _defaultRequiredCalibrationPairs = 5;
  static const int _minRequiredCalibrationPairs = 3;
  static const int _maxRequiredCalibrationPairs = 20;
  static const Duration _nextAngleDelay = Duration(milliseconds: 1500);
  static const Duration _liveRectifyMinInterval = Duration(milliseconds: 120);
  static const Duration _liveDepthMinInterval = Duration(milliseconds: 220);

  late final SettingsController _settingsController;
  late final WarmUpSystemStatsUseCase _warmUpSystemStatsUseCase;
  late final GetSystemStatsUseCase _getSystemStatsUseCase;
  late final GetCalibrationStatusUseCase _getCalibrationStatusUseCase;
  late final CalibrateStereoSessionUseCase _calibrateStereoSessionUseCase;
  late final RectifyPreviewFramePairUseCase _rectifyPreviewFramePairUseCase;
  late final BuildDepthMapFramePairUseCase _buildDepthMapFramePairUseCase;
  late final CheckCheckerboardFramePairUseCase
  _checkCheckerboardFramePairUseCase;

  StreamSubscription<dynamic>? _fotSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  Timer? _captureTimer;
  Timer? _statsTimer;
  Timer? _previewTimer;
  Timer? _checkerboardTimer;

  bool _isReady = false;
  bool _isRecording = false;
  bool _isCapturing = false;
  bool _isStereoProcessing = false;
  bool _isOpeningCameras = false;
  bool _isPreviewCapturing = false;
  bool _isCheckerboardDetecting = false;
  bool _isGuidedCalibrationPairCapturing = false;
  bool _isCalibrationCaptureRunning = false;
  bool _isLiveRectifyProcessing = false;
  bool _isLiveDepthProcessing = false;

  String _status = 'Başlatılıyor...';
  String _camera2Status = 'Camera2 raporu hazırlanıyor...';
  String _stereoStatus = '';
  String _checkerboardStatus =
      'Dama tahtası kontrolü bekleniyor. Faz 2’de otomatik aranır.';

  int _capturedCalibrationPairs = 0;
  int _requiredCalibrationPairs = _defaultRequiredCalibrationPairs;
  DateTime? _lastCalibrationCaptureAt;
  DateTime? _lastLiveRectifyAt;
  DateTime? _lastLiveDepthAt;

  double? _fotCm;
  int _frameIndex = 0;

  double? _accX;
  double? _accY;
  double? _accZ;
  double? _gyroX;
  double? _gyroY;
  double? _gyroZ;

  File? _activeCsvFile;
  Directory? _activeSessionDir;

  List<String> _availableBackCameraIds = [];
  Map<String, _CameraOption> _cameraOptionsById = {};
  String? _cam1Id;
  String? _cam2Id;
  Uint8List? _lastCam1PreviewBytes;
  Uint8List? _lastCam2PreviewBytes;
  Uint8List? _rectifiedCam1PreviewBytes;
  Uint8List? _rectifiedCam2PreviewBytes;
  Uint8List? _depthPreviewBytes;
  bool _showRectifiedPreview = false;
  bool _showDepthPreview = false;
  File? _lastCam1Frame;
  File? _lastCam2Frame;
  Directory? _previewCacheDir;
  List<Offset> _cam1CheckerboardCorners = const [];
  List<Offset> _cam2CheckerboardCorners = const [];
  bool _checkerboardFoundCam1 = false;
  bool _checkerboardFoundCam2 = false;

  String? _activeCam1Id;
  String? _activeCam2Id;
  String _activeCaptureMode = '';

  String? _lastCompletedSessionPath;
  String? _lastRectifiedOutputPath;
  bool _hasCachedCalibration = false;
  int? _cachedCalibrationUpdatedAtMs;

  AppSettings _settings = AppSettings.defaults();
  SystemStats _systemStats = SystemStats.empty();
  CaptureWorkflowPhase _phase = CaptureWorkflowPhase.cameraSelection;

  DateTime? _lastCaptureTime;
  double _actualFps = 0;
  final List<double> _fpsHistory = [];

  @override
  void initState() {
    super.initState();

    final settingsRepository = JsonAppSettingsRepository();
    _settingsController = SettingsController(
      loadUseCase: LoadAppSettingsUseCase(settingsRepository),
      saveUseCase: SaveAppSettingsUseCase(settingsRepository),
    );

    final statsRepository = MethodChannelSystemStatsRepository(
      _systemStatsChannel,
    );
    _warmUpSystemStatsUseCase = WarmUpSystemStatsUseCase(statsRepository);
    _getSystemStatsUseCase = GetSystemStatsUseCase(statsRepository);

    final stereoRepository = MethodChannelStereoPreprocessRepository();
    _getCalibrationStatusUseCase = GetCalibrationStatusUseCase(stereoRepository);
    _calibrateStereoSessionUseCase = CalibrateStereoSessionUseCase(
      stereoRepository,
    );
    _rectifyPreviewFramePairUseCase = RectifyPreviewFramePairUseCase(
      stereoRepository,
    );
    _buildDepthMapFramePairUseCase = BuildDepthMapFramePairUseCase(
      stereoRepository,
    );
    _checkCheckerboardFramePairUseCase = CheckCheckerboardFramePairUseCase(
      stereoRepository,
    );

    _initialize();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _stopStatsPolling();
    _stopPreviewLoop();
    _stopCheckerboardLoop();
    _stopFotStream();
    _stopImuStreams();

    unawaited(_settingsController.flushNow());
    _settingsController.dispose();

    Camera2Bridge.closeDualCameras().catchError((_) {});
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _loadSettings();

      final permissionStatus = await Permission.camera.request();
      if (!permissionStatus.isGranted) {
        if (!mounted) return;
        setState(() {
          _status = 'Kamera izni gerekli. Ayarlardan izin verip tekrar dene.';
        });
        return;
      }

      if (Platform.isAndroid) {
        if (await Permission.manageExternalStorage.isDenied) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }

      await _initDualCameras();
      await _refreshCalibrationCacheStatus();
      _applySensorSettings();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Başlatma hatası: $error';
      });
    }
  }

  Future<void> _loadSettings() async {
    final loaded = await _settingsController.load();
    if (!mounted) return;
    setState(() {
      _settings = loaded;
    });
  }

  Future<void> _persistAndSetSettings(
    AppSettings next, {
    bool refreshSensors = false,
    bool restartCaptureTimer = false,
  }) async {
    if (!mounted) return;
    setState(() {
      _settings = next;
    });

    await _settingsController.update(next);

    if (refreshSensors) {
      _applySensorSettings();
    }

    if (restartCaptureTimer && _isRecording) {
      _startCaptureTimer();
      if (!mounted) return;
      setState(() {
        _status =
            'Kayıt devam ediyor. Yeni FPS: ${_fpsLabel(_settings.effectiveCaptureIntervalMs)}';
      });
    }
  }

  void _applySensorSettings() {
    if (_settings.effectiveEnableFot) {
      _startFotStream();
    } else {
      _stopFotStream();
      if (mounted) {
        setState(() {
          _fotCm = null;
        });
      }
    }

    if (_settings.effectiveEnableImu) {
      _startImuStreams();
    } else {
      _stopImuStreams();
      if (mounted) {
        setState(() {
          _accX = null;
          _accY = null;
          _accZ = null;
          _gyroX = null;
          _gyroY = null;
          _gyroZ = null;
        });
      }
    }

    if (_settings.effectiveEnableStats) {
      _startStatsPolling();
    } else {
      _stopStatsPolling();
      if (mounted) {
        setState(() {
          _systemStats = SystemStats.empty();
        });
      }
    }
  }

  Future<void> _initDualCameras() async {
    try {
      final report = await Camera2Bridge.getBackCameraReport();
      final cameraOptions = _parseBackCameraOptions(report);
      final backCameraIds = cameraOptions.map((item) => item.id).toList();

      if (!mounted) return;
      setState(() {
        _cameraOptionsById = {for (final item in cameraOptions) item.id: item};
        _availableBackCameraIds = backCameraIds;
        _camera2Status =
            'Camera2: ${backCameraIds.length} seçilebilir arka kamera bulundu.';
      });

      if (backCameraIds.length < 2) {
        if (!mounted) return;
        setState(() {
          _status = 'En az 2 arka kamera gerekli.';
        });
        return;
      }

      String? suggestedCam1;
      String? suggestedCam2;

      if (_settings.effectiveAutoSelectCameraPair) {
        final pairResult = await Camera2Bridge.findBestPair();
        if (pairResult['found'] == true) {
          suggestedCam1 = pairResult['cam1Id'] as String?;
          suggestedCam2 = pairResult['cam2Id'] as String?;
        }
      }

      suggestedCam1 ??= backCameraIds[0];
      suggestedCam2 ??= backCameraIds[1];

      if (!mounted) return;
      setState(() {
        _cam1Id = suggestedCam1;
        _cam2Id = suggestedCam2;
        _status = 'Faz 1: kamera seçimi sonrası otomatik açılır.';
      });

      await _openSelectedCameras(suggestedCam1, suggestedCam2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _camera2Status = 'Camera2 raporu alınamadı: $e';
      });
    }
  }

  List<_CameraOption> _parseBackCameraOptions(Map<String, dynamic> report) {
    final rawOptions = report['backCameraOptions'];
    if (rawOptions is List) {
      final parsed = rawOptions
          .whereType<Map>()
          .map((item) => _CameraOption.fromMap(item))
          .where((item) => item.id.isNotEmpty)
          .toList();
      if (parsed.isNotEmpty) {
        return parsed;
      }
    }

    final fallbackIds =
        (report['backCameraIds'] as List?)
            ?.map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList() ??
        <String>[];

    return fallbackIds
        .map(
          (id) => _CameraOption(
            id: id,
            lensType: 'Back',
            megapixels: 0,
            focalMm: 0,
            displayName: 'Back • id=$id',
          ),
        )
        .toList();
  }

  Future<void> _openSelectedCameras(String cam1, String cam2) async {
    if (cam1 == cam2) {
      if (!mounted) return;
      setState(() {
        _isReady = false;
        _status = 'Kamera 1 ve Kamera 2 aynı olamaz.';
      });
      return;
    }

    if (_isOpeningCameras || _isRecording) {
      return;
    }

    if (_isReady && _activeCam1Id == cam1 && _activeCam2Id == cam2) {
      _startPreviewLoop();
      return;
    }

    _isOpeningCameras = true;
    _stopPreviewLoop();

    if (!mounted) {
      _isOpeningCameras = false;
      return;
    }
    setState(() {
      _isReady = false;
      _cam1Id = cam1;
      _cam2Id = cam2;
      _lastCam1PreviewBytes = null;
      _lastCam2PreviewBytes = null;
      _rectifiedCam1PreviewBytes = null;
      _rectifiedCam2PreviewBytes = null;
      _depthPreviewBytes = null;
      _showRectifiedPreview = false;
      _showDepthPreview = false;
      _lastCam1Frame = null;
      _lastCam2Frame = null;
      _status = 'Kameralar açılıyor ($cam1, $cam2)...';
    });

    try {
      await Camera2Bridge.closeDualCameras();

      final openResult = await Camera2Bridge.openDualCameras(cam1, cam2);
      final success = openResult['success'] == true;
      final openMode = (openResult['mode']?.toString() ?? '').trim();

      if (!mounted) return;

      if (success) {
        const modeLabel = 'Logical Multi-Camera ✓';
        setState(() {
          _isReady = true;
          _activeCam1Id = cam1;
          _activeCam2Id = cam2;
          _activeCaptureMode = openMode.isNotEmpty
              ? openMode
              : 'logical_multi_camera';
          _status = 'Hazır! $cam1 + $cam2 ($modeLabel).';
          _camera2Status = '${_camera2Status.split('|').first} | $modeLabel';
        });

        _startPreviewLoop();
        if (_phase == CaptureWorkflowPhase.calibration) {
          _startCheckerboardLoop();
        }
      } else {
        final error = openResult['error'] ?? 'Bilinmeyen hata';
        setState(() {
          _isReady = false;
          _activeCam1Id = null;
          _activeCam2Id = null;
          _activeCaptureMode = '';
          _status = 'Dual kamera açılamadı: $error';
          _camera2Status += ' ✗ $error';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isReady = false;
        _activeCam1Id = null;
        _activeCam2Id = null;
        _activeCaptureMode = '';
        _status = 'Dual kamera açılış hatası: $e';
      });
    } finally {
      _isOpeningCameras = false;
    }
  }

  void _startFotStream() {
    _stopFotStream();
    _fotSubscription = _fotSensorChannel.receiveBroadcastStream().listen(
      (value) {
        final parsed = double.tryParse(value.toString());
        if (!mounted) return;
        setState(() {
          _fotCm = parsed;
        });
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _fotCm = -1.0;
        });
      },
      cancelOnError: false,
    );
  }

  void _stopFotStream() {
    _fotSubscription?.cancel();
    _fotSubscription = null;
  }

  void _startImuStreams() {
    _stopImuStreams();

    _accSubscription = userAccelerometerEventStream().listen((event) {
      if (!mounted) return;
      setState(() {
        _accX = event.x;
        _accY = event.y;
        _accZ = event.z;
      });
    });

    _gyroSubscription = gyroscopeEventStream().listen((event) {
      if (!mounted) return;
      setState(() {
        _gyroX = event.x;
        _gyroY = event.y;
        _gyroZ = event.z;
      });
    });
  }

  void _stopImuStreams() {
    _accSubscription?.cancel();
    _gyroSubscription?.cancel();
    _accSubscription = null;
    _gyroSubscription = null;
  }

  Future<void> _stopRecordingSession({String? statusText}) async {
    if (!_isRecording) return;

    _captureTimer?.cancel();
    final sessionDir = _activeSessionDir;

    _activeCsvFile = null;
    _activeSessionDir = null;

    if (!mounted) return;

    setState(() {
      _isRecording = false;
      _lastCompletedSessionPath = sessionDir?.path;
      _status =
          statusText ??
          'Kayıt tamamlandı. Faz 2 butonu ile kalibrasyon adımına geçebilirsin.';
    });

    _startPreviewLoop();
  }

  String _captureLogCsvHeader() {
    return 'frame,timestamp_utc,cam1_image,cam2_image,fot_cm,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,pose_tx,pose_ty,pose_tz,pose_qx,pose_qy,pose_qz,pose_qw,fx,fy,cx,cy,k1,k2,p1,p2,k3,lux,kelvin,exposure_ms,iso,plane_data,bbox_data,cam1_id,cam2_id,capture_mode\n';
  }

  Future<bool> _ensureGuidedCalibrationSession() async {
    if (_activeSessionDir != null && _activeCsvFile != null) {
      return true;
    }

    try {
      final sessionDir = await _createSessionFolder();
      final csvFile = File(
        '${sessionDir.path}${Platform.pathSeparator}capture_log.csv',
      );
      await csvFile.writeAsString(_captureLogCsvHeader(), flush: true);

      _activeSessionDir = sessionDir;
      _activeCsvFile = csvFile;
      _frameIndex = 0;
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _checkerboardStatus =
            '✗ Faz 2 oturumu hazırlanamadı. Depolama iznini/alanını kontrol edin.';
        _status = 'Faz 2 kayıt hatası: $error';
      });
      return false;
    }
  }

  Future<bool> _captureGuidedCalibrationPair() async {
    if (_isGuidedCalibrationPairCapturing || !_isReady) {
      return false;
    }

    final prepared = await _ensureGuidedCalibrationSession();
    if (!prepared) {
      return false;
    }

    final csvFile = _activeCsvFile;
    final sessionDir = _activeSessionDir;
    if (csvFile == null || sessionDir == null) {
      return false;
    }

    _isGuidedCalibrationPairCapturing = true;
    try {
      final frameNo = _frameIndex;
      _frameIndex += 1;

      final now = DateTime.now().toUtc();
      final ts = DateFormat('yyyyMMdd_HHmmss_SSS').format(now);

      final cam1Relative = 'cam1/frame_${frameNo}_$ts.jpg';
      final cam2Relative = 'cam2/frame_${frameNo}_$ts.jpg';

      final cam1FullPath =
          '${sessionDir.path}${Platform.pathSeparator}${cam1Relative.replaceAll('/', Platform.pathSeparator)}';
      final cam2FullPath =
          '${sessionDir.path}${Platform.pathSeparator}${cam2Relative.replaceAll('/', Platform.pathSeparator)}';

      final result = await Camera2Bridge.captureDualFrame(
        cam1FullPath,
        cam2FullPath,
      );

      final cam1Saved = result['cam1Saved'] == true;
      final cam2Saved = result['cam2Saved'] == true;
      final pairSaved = cam1Saved && cam2Saved;

      if (cam1Saved && mounted) {
        setState(() {
          _lastCam1Frame = File(cam1FullPath);
        });
      }
      if (cam2Saved && mounted) {
        setState(() {
          _lastCam2Frame = File(cam2FullPath);
        });
      }

      final fotValue = _fmt(_fotCm, digits: 3);

      final fx = result['fx'] ?? '';
      final fy = result['fy'] ?? '';
      final cx = result['cx'] ?? '';
      final cy = result['cy'] ?? '';
      final k1 = result['k1'] ?? '';
      final k2 = result['k2'] ?? '';
      final p1 = result['p1'] ?? '';
      final p2 = result['p2'] ?? '';
      final k3 = result['k3'] ?? '';
      final lux = result['lux'] ?? '';
      final kelvin = result['kelvin'] ?? '';
      final expMs = result['exposure_ms'] ?? '';
      final iso = result['iso'] ?? '';
      final planeInfo = result['plane_data'] ?? '';
      final bboxInfo = result['bbox_data'] ?? '';
      final cam1Id = result['cam1Id'] ?? _cam1Id ?? '';
      final cam2Id = result['cam2Id'] ?? _cam2Id ?? '';
      final captureMode = result['capture_mode'] ?? '';

      final line =
          '$frameNo,${now.toIso8601String()},${cam1Saved ? cam1Relative : ''},${cam2Saved ? cam2Relative : ''},$fotValue,${_fmt(_accX)},${_fmt(_accY)},${_fmt(_accZ)},${_fmt(_gyroX)},${_fmt(_gyroY)},${_fmt(_gyroZ)},,,,,,,,$fx,$fy,$cx,$cy,$k1,$k2,$p1,$p2,$k3,$lux,$kelvin,$expMs,$iso,"$planeInfo","$bboxInfo",$cam1Id,$cam2Id,$captureMode\n';

      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
      return pairSaved;
    } catch (error) {
      final errorCommas = ',' * 33;
      final line =
          '${_frameIndex - 1},${DateTime.now().toUtc().toIso8601String()},,,ERROR:$error$errorCommas\n';
      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
      return false;
    } finally {
      _isGuidedCalibrationPairCapturing = false;
    }
  }

  void _startCaptureTimer() {
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(
      Duration(milliseconds: _settings.effectiveCaptureIntervalMs),
      (_) async {
        final csv = _activeCsvFile;
        final session = _activeSessionDir;
        if (csv == null || session == null) return;
        await _captureFramePair(csvFile: csv, sessionDir: session);
      },
    );
  }

  void _startPreviewLoop() {
    if (!_isReady || _isRecording) return;

    _stopPreviewLoop();
    unawaited(_capturePreviewFrame());

    final intervalMs = _settings.effectiveCaptureIntervalMs.clamp(80, 250);
    _previewTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => unawaited(_capturePreviewFrame()),
    );
  }

  void _stopPreviewLoop() {
    _previewTimer?.cancel();
    _previewTimer = null;
  }

  Future<void> _capturePreviewFrame() async {
    if (!_isReady || _isRecording || _isCapturing || _isPreviewCapturing) {
      return;
    }

    _isPreviewCapturing = true;
    try {
      final result = await Camera2Bridge.getLatestPreviewFrames();
      if (!mounted) return;

      final mode = (result['capture_mode']?.toString() ?? '').trim();
      if (mode.isNotEmpty && mode != _activeCaptureMode) {
        _activeCaptureMode = mode;
      }

      final cam1Bytes = result['cam1Bytes'];
      final cam2Bytes = result['cam2Bytes'];

      final cam1HasData = cam1Bytes is Uint8List && cam1Bytes.isNotEmpty;
      final cam2HasData = cam2Bytes is Uint8List && cam2Bytes.isNotEmpty;

      if (!cam1HasData && !cam2HasData) {
        return;
      }

      setState(() {
        if (cam1HasData) {
          _lastCam1PreviewBytes = cam1Bytes;
        }
        if (cam2HasData) {
          _lastCam2PreviewBytes = cam2Bytes;
        }
      });

      if (_phase == CaptureWorkflowPhase.stereoMatching &&
          _showRectifiedPreview &&
          cam1Bytes is Uint8List &&
          cam2Bytes is Uint8List &&
          cam1Bytes.isNotEmpty &&
          cam2Bytes.isNotEmpty) {
        unawaited(
          _refreshLiveRectifyFromPreview(
            cam1Bytes: cam1Bytes,
            cam2Bytes: cam2Bytes,
          ),
        );
      }

      if (_phase == CaptureWorkflowPhase.depthMap &&
          _showDepthPreview &&
          cam1Bytes is Uint8List &&
          cam2Bytes is Uint8List &&
          cam1Bytes.isNotEmpty &&
          cam2Bytes.isNotEmpty) {
        unawaited(
          _refreshLiveDepthFromPreview(
            cam1Bytes: cam1Bytes,
            cam2Bytes: cam2Bytes,
          ),
        );
      }
    } catch (_) {
      // Ignore preview errors; recording path remains authoritative.
    } finally {
      _isPreviewCapturing = false;
    }
  }

  Future<Directory> _getPreviewCacheDir() async {
    final cached = _previewCacheDir;
    if (cached != null) {
      return cached;
    }

    final tempDir = await getTemporaryDirectory();
    final dir = Directory(
      '${tempDir.path}${Platform.pathSeparator}multicam_preview',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _previewCacheDir = dir;
    return dir;
  }

  void _startCheckerboardLoop() {
    if (_phase != CaptureWorkflowPhase.calibration ||
        _isRecording ||
        !_isCalibrationCaptureRunning) {
      return;
    }

    _stopCheckerboardLoop();
    unawaited(_checkCheckerboardInPreview());
    _checkerboardTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => unawaited(_checkCheckerboardInPreview()),
    );
  }

  void _startPhase2Capture() {
    if (_phase != CaptureWorkflowPhase.calibration ||
        _isRecording ||
        _isStereoProcessing) {
      return;
    }

    setState(() {
      _isCalibrationCaptureRunning = true;
      _checkerboardStatus =
          'Çekim aktif. Dama tahtası tespit edildiğinde fotoğraf otomatik kaydedilir ($_capturedCalibrationPairs/$_requiredCalibrationPairs).';
      _status = 'Faz 2 çekim aktif.';
    });

    _startCheckerboardLoop();
  }

  void _stopPhase2Capture({String? checkerboardStatus, String? status}) {
    _isCalibrationCaptureRunning = false;
    _stopCheckerboardLoop();

    if (!mounted) return;
    setState(() {
      if (checkerboardStatus != null && checkerboardStatus.isNotEmpty) {
        _checkerboardStatus = checkerboardStatus;
      }
      if (status != null && status.isNotEmpty) {
        _status = status;
      }
    });
  }

  void _stopCheckerboardLoop() {
    _checkerboardTimer?.cancel();
    _checkerboardTimer = null;
  }

  Future<void> _checkCheckerboardInPreview() async {
    if (_phase != CaptureWorkflowPhase.calibration || _isStereoProcessing) {
      return;
    }
    if (_isRecording || _isCheckerboardDetecting) {
      return;
    }

    final probePaths = await _prepareCheckerboardProbePaths();
    if (probePaths == null) {
      if (!mounted) return;
      setState(() {
        _checkerboardStatus =
            '✗ Dama tahtası bulunamadı. Önce iki kamerada da güncel görüntü oluşmasını bekleyin.';
        _cam1CheckerboardCorners = const [];
        _cam2CheckerboardCorners = const [];
        _checkerboardFoundCam1 = false;
        _checkerboardFoundCam2 = false;
      });
      return;
    }

    _isCheckerboardDetecting = true;
    try {
      final result = await _checkCheckerboardFramePairUseCase(
        probePaths.$1,
        probePaths.$2,
      );

      final foundCam1 = result.extras['foundCam1'] == true;
      final foundCam2 = result.extras['foundCam2'] == true;
      final cam1Corners = _extractNormalizedCorners(
        rawCorners: result.extras['cam1Corners'],
        imageWidth: result.extras['cam1ImageWidth'],
        imageHeight: result.extras['cam1ImageHeight'],
      );
      final cam2Corners = _extractNormalizedCorners(
        rawCorners: result.extras['cam2Corners'],
        imageWidth: result.extras['cam2ImageWidth'],
        imageHeight: result.extras['cam2ImageHeight'],
      );

      final statusText = result.message.isNotEmpty
          ? result.message
          : (result.success
                ? '✓ Dama tahtası bulundu.'
                : '✗ Dama tahtası bulunamadı.');

      final now = DateTime.now();
      final inCooldown =
          _lastCalibrationCaptureAt != null &&
          now.difference(_lastCalibrationCaptureAt!) < _nextAngleDelay;

      var nextStatusText = statusText;
      if (result.success) {
        if (_capturedCalibrationPairs >= _requiredCalibrationPairs) {
          nextStatusText =
              '✓ Gerekli fotoğraf sayısı tamamlandı ($_capturedCalibrationPairs/$_requiredCalibrationPairs).';
        } else if (inCooldown) {
          final leftMs =
              _nextAngleDelay.inMilliseconds -
              now.difference(_lastCalibrationCaptureAt!).inMilliseconds;
          final leftSec = (leftMs / 1000).ceil().clamp(1, 2);
          nextStatusText =
              '✓ Bu açı kaydedildi ($_capturedCalibrationPairs/$_requiredCalibrationPairs). Sıradaki açıya geç ($leftSec sn)...';
        }
      }

      if (!mounted) return;
      setState(() {
        _checkerboardStatus = nextStatusText;
        _checkerboardFoundCam1 = foundCam1;
        _checkerboardFoundCam2 = foundCam2;
        _cam1CheckerboardCorners = cam1Corners;
        _cam2CheckerboardCorners = cam2Corners;
      });

      if (!_isCalibrationCaptureRunning) {
        if (result.success) {
          setState(() {
            _checkerboardStatus =
                '✓ Dama tahtası bulundu. Kaydı başlatmak için "Çekimi Başlat" butonuna basın.';
          });
        }
        return;
      }

      if (!result.success ||
          _capturedCalibrationPairs >= _requiredCalibrationPairs) {
        return;
      }

      if (inCooldown || _isGuidedCalibrationPairCapturing) {
        return;
      }

      final pairSaved = await _captureGuidedCalibrationPair();
      if (!mounted) return;

      if (!pairSaved) {
        setState(() {
          _checkerboardStatus =
              '✗ Checkerboard görüldü ama kare çifti kaydedilemedi. Kartı sabit tutup tekrar deneyin.';
        });
        return;
      }

      _capturedCalibrationPairs += 1;
      _lastCalibrationCaptureAt = DateTime.now();
      final remaining = _requiredCalibrationPairs - _capturedCalibrationPairs;

      if (remaining <= 0) {
        _lastCompletedSessionPath = _activeSessionDir?.path;
        _stopPhase2Capture(
          checkerboardStatus:
              '✓ Gerekli fotoğraf sayısı tamamlandı ($_capturedCalibrationPairs/$_requiredCalibrationPairs).',
          status:
              'Faz 2 kayıt tamamlandı. OpenCV Kalibrasyon butonuna basarak devam et.',
        );
        return;
      }

      setState(() {
        _checkerboardStatus =
            '✓ Bu açıdan fotoğraf çekildi ($_capturedCalibrationPairs/$_requiredCalibrationPairs). Sıradaki açıya geç.';
        _status =
            'Faz 2: ${_capturedCalibrationPairs}/$_requiredCalibrationPairs kaydedildi. Kartı 1-2 sn içinde yeni açıya taşı.';
      });
    } finally {
      _isCheckerboardDetecting = false;
    }
  }

  List<Offset> _extractNormalizedCorners({
    required dynamic rawCorners,
    required dynamic imageWidth,
    required dynamic imageHeight,
  }) {
    if (rawCorners is! List) {
      return const [];
    }

    final width = _toPositiveDouble(imageWidth);
    final height = _toPositiveDouble(imageHeight);
    if (width <= 0 || height <= 0) {
      return const [];
    }

    final offsets = <Offset>[];
    for (final item in rawCorners) {
      if (item is! Map) {
        continue;
      }

      final x = _toPositiveDouble(item['x']);
      final y = _toPositiveDouble(item['y']);
      if (x < 0 || y < 0) {
        continue;
      }

      final normalizedX = (x / width).clamp(0.0, 1.0).toDouble();
      final normalizedY = (y / height).clamp(0.0, 1.0).toDouble();
      offsets.add(Offset(normalizedX, normalizedY));
    }

    return offsets;
  }

  double _toPositiveDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? -1;
    }
    return -1;
  }

  Future<(String, String)?> _prepareCheckerboardProbePaths() async {
    final cam1Path = await _resolveProbePath(
      bytes: _lastCam1PreviewBytes,
      fallbackFile: _lastCam1Frame,
      fileName: 'cam1_checkerboard_probe.jpg',
    );
    final cam2Path = await _resolveProbePath(
      bytes: _lastCam2PreviewBytes,
      fallbackFile: _lastCam2Frame,
      fileName: 'cam2_checkerboard_probe.jpg',
    );

    if (cam1Path == null || cam2Path == null) {
      return null;
    }

    return (cam1Path, cam2Path);
  }

  Future<String?> _resolveProbePath({
    required Uint8List? bytes,
    required File? fallbackFile,
    required String fileName,
  }) async {
    if (bytes != null && bytes.isNotEmpty) {
      final previewDir = await _getPreviewCacheDir();
      final file = File('${previewDir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }

    if (fallbackFile != null && await fallbackFile.exists()) {
      return fallbackFile.path;
    }

    return null;
  }

  Future<void> _refreshCalibrationCacheStatus() async {
    final result = await _getCalibrationStatusUseCase();
    if (!mounted) return;

    int? toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    setState(() {
      _hasCachedCalibration = result.success && result.outputPath.isNotEmpty;
      _cachedCalibrationUpdatedAtMs = _hasCachedCalibration
          ? toInt(result.extras['lastUpdatedMs'])
          : null;
    });
  }

  String _cachedCalibrationLabel() {
    if (!_hasCachedCalibration) {
      return 'Kayıtlı kalibrasyon yok. Faz 2 tamamlanınca otomatik kaydedilir.';
    }

    final updatedMs = _cachedCalibrationUpdatedAtMs;
    if (updatedMs == null || updatedMs <= 0) {
      return 'Kayıtlı kalibrasyon bulundu. Yeniden checkerboard çekmeden Faz 3 kullanılabilir.';
    }

    final updated = DateTime.fromMillisecondsSinceEpoch(updatedMs);
    final formatted = DateFormat('dd.MM.yyyy HH:mm:ss').format(updated);
    return 'Kayıtlı kalibrasyon bulundu (son güncelleme: $formatted).';
  }

  Future<void> _setPhase(CaptureWorkflowPhase nextPhase) async {
    if (_phase == nextPhase) {
      if (_phase == CaptureWorkflowPhase.calibration) {
        if (_isCalibrationCaptureRunning) {
          _startCheckerboardLoop();
        } else {
          _stopCheckerboardLoop();
        }
      }
      return;
    }

    if (_isRecording && nextPhase != CaptureWorkflowPhase.cameraSelection) {
      await _stopRecordingSession();
    }

    if (!mounted) return;
    setState(() {
      _phase = nextPhase;
      if (nextPhase != CaptureWorkflowPhase.stereoMatching) {
        _showRectifiedPreview = false;
        _rectifiedCam1PreviewBytes = null;
        _rectifiedCam2PreviewBytes = null;
      }
      if (nextPhase != CaptureWorkflowPhase.depthMap) {
        _showDepthPreview = false;
        _depthPreviewBytes = null;
      }
      if (nextPhase == CaptureWorkflowPhase.calibration) {
        _isCalibrationCaptureRunning = false;
        _capturedCalibrationPairs = 0;
        _lastCalibrationCaptureAt = null;
        _lastCompletedSessionPath = null;
        _activeCsvFile = null;
        _activeSessionDir = null;
        _checkerboardStatus =
            'Hazır. Kayda başlamak için "Çekimi Başlat" butonuna basın (0/$_requiredCalibrationPairs).';
        _status = 'Faz 2 hazır.';
      } else if (nextPhase == CaptureWorkflowPhase.depthMap) {
        _status =
            'Faz 4 hazır. Canlı derinlik haritası için "Canlı Derinlik Başlat" butonuna basın.';
      } else {
        _isCalibrationCaptureRunning = false;
        _cam1CheckerboardCorners = const [];
        _cam2CheckerboardCorners = const [];
        _checkerboardFoundCam1 = false;
        _checkerboardFoundCam2 = false;
      }
    });

    if (nextPhase == CaptureWorkflowPhase.calibration) {
      if (_isCalibrationCaptureRunning) {
        _startCheckerboardLoop();
      } else {
        _stopCheckerboardLoop();
      }
    } else {
      _stopCheckerboardLoop();
    }

    if (_isReady && !_isRecording) {
      _startPreviewLoop();
    }
  }

  Future<void> _runCalibrationOnDevice() async {
    if (_isStereoProcessing) return;
    final sessionPath = _lastCompletedSessionPath;
    if (sessionPath == null || sessionPath.isEmpty) {
      if (!mounted) return;
      setState(() {
        _stereoStatus =
            'Önce Faz 2’de $_requiredCalibrationPairs açı kaydı tamamlanmalı.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = true;
      _stereoStatus = 'OpenCV kalibrasyon çalışıyor...';
    });

    final result = await _calibrateStereoSessionUseCase(sessionPath);
    final shouldAdvanceToPhase3 = result.success;

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = false;
      _stereoStatus =
          '${result.success ? '✓' : '✗'} ${result.message} (çift: ${result.processedPairs})';
      _checkerboardStatus = result.success
          ? '✓ Dama tahtası bulundu. Geçerli çift: ${result.processedPairs}'
          : '✗ Dama tahtası bulunamadı / yetersiz. ${result.message}';
      if (result.success) {
        _status = 'Kalibrasyon tamamlandı. Faz 3 ile stereo rectify başlat.';
      }
    });

    if (result.success) {
      await _refreshCalibrationCacheStatus();
    }

    if (shouldAdvanceToPhase3) {
      await _setPhase(CaptureWorkflowPhase.stereoMatching);
    }
  }

  Future<void> _runRectifyOnDevice() async {
    if (_isStereoProcessing || _isLiveRectifyProcessing) return;

    if (_showRectifiedPreview) {
      if (!mounted) return;
      setState(() {
        _showRectifiedPreview = false;
        _stereoStatus = '';
      });
      return;
    }

    Uint8List? cam1Bytes = _lastCam1PreviewBytes;
    Uint8List? cam2Bytes = _lastCam2PreviewBytes;

    final hasInitialFrames =
        cam1Bytes != null &&
        cam2Bytes != null &&
        cam1Bytes.isNotEmpty &&
        cam2Bytes.isNotEmpty;

    if (!hasInitialFrames && _isReady && !_isRecording) {
      await _capturePreviewFrame();
      cam1Bytes = _lastCam1PreviewBytes;
      cam2Bytes = _lastCam2PreviewBytes;
    }

    final canStartLiveRectify =
        cam1Bytes != null &&
        cam2Bytes != null &&
        cam1Bytes.isNotEmpty &&
        cam2Bytes.isNotEmpty;
    if (!canStartLiveRectify) {
      if (!mounted) return;
      setState(() {
        _stereoStatus =
            'Canlı rectify için iki kameradan güncel preview karesi gerekli.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = true;
      _stereoStatus = '';
    });

    final result = await _rectifyPreviewFramePairUseCase(cam1Bytes, cam2Bytes);
    final pair = _extractRectifiedPreviewPair(result);
    final hasRectifiedPair =
        pair.$1 != null &&
        pair.$2 != null &&
        pair.$1!.isNotEmpty &&
        pair.$2!.isNotEmpty;

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = false;
      _showRectifiedPreview = result.success && hasRectifiedPair;
      if (_showRectifiedPreview) {
        _rectifiedCam1PreviewBytes = pair.$1;
        _rectifiedCam2PreviewBytes = pair.$2;
        _stereoStatus = '';
      } else {
        _stereoStatus = '✗ ${result.message}';
      }
    });
  }

  Future<void> _refreshLiveRectifyFromPreview({
    required Uint8List cam1Bytes,
    required Uint8List cam2Bytes,
  }) async {
    if (_phase != CaptureWorkflowPhase.stereoMatching || !_showRectifiedPreview) {
      return;
    }
    if (_isStereoProcessing || _isLiveRectifyProcessing) {
      return;
    }

    final now = DateTime.now();
    if (_lastLiveRectifyAt != null &&
        now.difference(_lastLiveRectifyAt!) < _liveRectifyMinInterval) {
      return;
    }

    _isLiveRectifyProcessing = true;
    _lastLiveRectifyAt = now;
    try {
      final result = await _rectifyPreviewFramePairUseCase(cam1Bytes, cam2Bytes);
      if (!mounted) return;

      if (!result.success) {
        setState(() {
          _stereoStatus = '✗ ${result.message}';
        });
        return;
      }

      final pair = _extractRectifiedPreviewPair(result);
      final rectifiedCam1 = pair.$1;
      final rectifiedCam2 = pair.$2;
      if (rectifiedCam1 == null ||
          rectifiedCam2 == null ||
          rectifiedCam1.isEmpty ||
          rectifiedCam2.isEmpty) {
        return;
      }

      setState(() {
        _rectifiedCam1PreviewBytes = rectifiedCam1;
        _rectifiedCam2PreviewBytes = rectifiedCam2;
      });
    } finally {
      _isLiveRectifyProcessing = false;
    }
  }

  Future<void> _runDepthMapOnDevice() async {
    if (_isStereoProcessing || _isLiveDepthProcessing) return;

    if (_showDepthPreview) {
      if (!mounted) return;
      setState(() {
        _showDepthPreview = false;
        _depthPreviewBytes = null;
        _stereoStatus = '';
      });
      return;
    }

    Uint8List? cam1Bytes = _lastCam1PreviewBytes;
    Uint8List? cam2Bytes = _lastCam2PreviewBytes;

    final hasInitialFrames =
        cam1Bytes != null &&
        cam2Bytes != null &&
        cam1Bytes.isNotEmpty &&
        cam2Bytes.isNotEmpty;

    if (!hasInitialFrames && _isReady && !_isRecording) {
      await _capturePreviewFrame();
      cam1Bytes = _lastCam1PreviewBytes;
      cam2Bytes = _lastCam2PreviewBytes;
    }

    final canStartLiveDepth =
        cam1Bytes != null &&
        cam2Bytes != null &&
        cam1Bytes.isNotEmpty &&
        cam2Bytes.isNotEmpty;
    if (!canStartLiveDepth) {
      if (!mounted) return;
      setState(() {
        _stereoStatus =
            'Canlı derinlik için iki kameradan güncel preview karesi gerekli.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = true;
      _stereoStatus = '';
    });

    final result = await _buildDepthMapFramePairUseCase(cam1Bytes, cam2Bytes);
    final depthBytes = _extractDepthPreview(result);
    final hasDepthPreview =
        depthBytes != null && depthBytes.isNotEmpty && result.success;

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = false;
      _showDepthPreview = hasDepthPreview;
      _depthPreviewBytes = hasDepthPreview ? depthBytes : null;
      _stereoStatus = hasDepthPreview ? '' : '✗ ${result.message}';
    });
  }

  Future<void> _refreshLiveDepthFromPreview({
    required Uint8List cam1Bytes,
    required Uint8List cam2Bytes,
  }) async {
    if (_phase != CaptureWorkflowPhase.depthMap || !_showDepthPreview) {
      return;
    }
    if (_isStereoProcessing || _isLiveDepthProcessing) {
      return;
    }

    final now = DateTime.now();
    if (_lastLiveDepthAt != null &&
        now.difference(_lastLiveDepthAt!) < _liveDepthMinInterval) {
      return;
    }

    _isLiveDepthProcessing = true;
    _lastLiveDepthAt = now;
    try {
      final result = await _buildDepthMapFramePairUseCase(cam1Bytes, cam2Bytes);
      if (!mounted) return;

      if (!result.success) {
        setState(() {
          _stereoStatus = '✗ ${result.message}';
        });
        return;
      }

      final depthBytes = _extractDepthPreview(result);
      if (depthBytes == null || depthBytes.isEmpty) {
        return;
      }

      setState(() {
        _depthPreviewBytes = depthBytes;
      });
    } finally {
      _isLiveDepthProcessing = false;
    }
  }

  Uint8List? _extractDepthPreview(StereoPreprocessResult result) {
    return _asUint8List(result.extras['depthBytes']);
  }

  (Uint8List?, Uint8List?) _extractRectifiedPreviewPair(
    StereoPreprocessResult result,
  ) {
    final cam1Bytes = _asUint8List(result.extras['cam1Bytes']);
    final cam2Bytes = _asUint8List(result.extras['cam2Bytes']);
    return (cam1Bytes, cam2Bytes);
  }

  Uint8List? _asUint8List(dynamic raw) {
    if (raw is Uint8List) {
      return raw;
    }
    if (raw is ByteData) {
      return raw.buffer.asUint8List();
    }
    if (raw is List<int>) {
      return Uint8List.fromList(raw);
    }
    return null;
  }

  Future<void> _setCaptureInterval(int value) async {
    final nextSettings = _settings.copyWith(captureIntervalMs: value);
    await _persistAndSetSettings(
      nextSettings,
      restartCaptureTimer: _isRecording,
    );

    if (_isReady && !_isRecording) {
      _startPreviewLoop();
    }

    if (!_isRecording && mounted) {
      setState(() {
        _status =
            'Yakala aralığı güncellendi: ${_settings.effectiveCaptureIntervalMs} ms';
      });
    }
  }

  void _onIntervalChanged(double value) {
    final nextValue = value.round();
    if (nextValue == _settings.effectiveCaptureIntervalMs) return;
    unawaited(_setCaptureInterval(nextValue));
  }

  String _fmt(double? value, {int digits = 4}) {
    if (value == null) return '';
    return value.toStringAsFixed(digits);
  }

  String _fpsLabel(int intervalMs) {
    final fps = 1000 / intervalMs;
    return fps.toStringAsFixed(2);
  }

  Future<Directory> _createSessionFolder() async {
    Directory? baseDir;

    if (Platform.isAndroid) {
      baseDir = Directory('/storage/emulated/0/Download/Multicam');
      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }

    final calibrationExists = await File(
      '/storage/emulated/0/Download/Multicam/stereo_calibration.json',
    ).exists();

    final modePrefix = switch (_phase) {
      CaptureWorkflowPhase.cameraSelection =>
        calibrationExists ? 'rectify_' : 'calib_',
      CaptureWorkflowPhase.calibration => 'calib_',
      CaptureWorkflowPhase.stereoMatching => 'rectify_',
      CaptureWorkflowPhase.depthMap => 'depth_',
    };

    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final sessionId = '$modePrefix$timestamp';
    final sessionDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}$sessionId',
    );

    await Directory(
      '${sessionDir.path}${Platform.pathSeparator}cam1',
    ).create(recursive: true);
    await Directory(
      '${sessionDir.path}${Platform.pathSeparator}cam2',
    ).create(recursive: true);

    return sessionDir;
  }

  Future<void> _captureFramePair({
    required File csvFile,
    required Directory sessionDir,
  }) async {
    if (!_isRecording || _isCapturing || !_isReady) return;
    _isCapturing = true;

    final now = DateTime.now();
    if (_lastCaptureTime != null) {
      final elapsed = now.difference(_lastCaptureTime!).inMilliseconds;
      if (elapsed > 0) {
        final instantFps = 1000.0 / elapsed;
        _fpsHistory.add(instantFps);
        if (_fpsHistory.length > 10) _fpsHistory.removeAt(0);
        _actualFps = _fpsHistory.reduce((a, b) => a + b) / _fpsHistory.length;
      }
    }
    _lastCaptureTime = now;

    try {
      final frameNo = _frameIndex;
      _frameIndex += 1;

      final now = DateTime.now().toUtc();
      final ts = DateFormat('yyyyMMdd_HHmmss_SSS').format(now);

      final cam1Relative = 'cam1/frame_${frameNo}_$ts.jpg';
      final cam2Relative = 'cam2/frame_${frameNo}_$ts.jpg';

      final cam1FullPath =
          '${sessionDir.path}${Platform.pathSeparator}${cam1Relative.replaceAll('/', Platform.pathSeparator)}';
      final cam2FullPath =
          '${sessionDir.path}${Platform.pathSeparator}${cam2Relative.replaceAll('/', Platform.pathSeparator)}';

      final result = await Camera2Bridge.captureDualFrame(
        cam1FullPath,
        cam2FullPath,
      );

      final cam1Saved = result['cam1Saved'] == true;
      final cam2Saved = result['cam2Saved'] == true;

      if (cam1Saved && mounted) {
        setState(() {
          _lastCam1Frame = File(cam1FullPath);
        });
      }
      if (cam2Saved && mounted) {
        setState(() {
          _lastCam2Frame = File(cam2FullPath);
        });
      }

      final fotValue = _fmt(_fotCm, digits: 3);

      final fx = result['fx'] ?? '';
      final fy = result['fy'] ?? '';
      final cx = result['cx'] ?? '';
      final cy = result['cy'] ?? '';
      final k1 = result['k1'] ?? '';
      final k2 = result['k2'] ?? '';
      final p1 = result['p1'] ?? '';
      final p2 = result['p2'] ?? '';
      final k3 = result['k3'] ?? '';
      final lux = result['lux'] ?? '';
      final kelvin = result['kelvin'] ?? '';
      final expMs = result['exposure_ms'] ?? '';
      final iso = result['iso'] ?? '';
      final planeInfo = result['plane_data'] ?? '';
      final bboxInfo = result['bbox_data'] ?? '';
      final cam1Id = result['cam1Id'] ?? _cam1Id ?? '';
      final cam2Id = result['cam2Id'] ?? _cam2Id ?? '';
      final captureMode = result['capture_mode'] ?? '';

      final line =
          '$frameNo,${now.toIso8601String()},${cam1Saved ? cam1Relative : ''},${cam2Saved ? cam2Relative : ''},$fotValue,${_fmt(_accX)},${_fmt(_accY)},${_fmt(_accZ)},${_fmt(_gyroX)},${_fmt(_gyroY)},${_fmt(_gyroZ)},,,,,,,,$fx,$fy,$cx,$cy,$k1,$k2,$p1,$p2,$k3,$lux,$kelvin,$expMs,$iso,"$planeInfo","$bboxInfo",$cam1Id,$cam2Id,$captureMode\n';

      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (error) {
      final errorCommas = ',' * 33;
      final line =
          '${_frameIndex - 1},${DateTime.now().toUtc().toIso8601String()},,,ERROR:$error$errorCommas\n';
      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
    } finally {
      _isCapturing = false;
    }
  }

  void _startStatsPolling() {
    _stopStatsPolling();

    unawaited(_warmUpSystemStatsUseCase());

    _statsTimer = Timer.periodic(
      Duration(milliseconds: _settings.effectiveStatsPollIntervalMs),
      (_) => _pollSystemStats(),
    );
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<void> _pollSystemStats() async {
    final stats = await _getSystemStatsUseCase();
    if (!mounted) return;
    setState(() {
      _systemStats = stats;
    });
  }

  Widget _buildPreview(
    Uint8List? previewBytes,
    File? lastFrame,
    String label, {
    required List<Offset> checkerCorners,
    required bool checkerFound,
  }) {
    final hasPreviewBytes = previewBytes != null && previewBytes.isNotEmpty;
    final hasLastFrame = lastFrame != null && lastFrame.existsSync();

    if (!hasPreviewBytes && !hasLastFrame) {
      return Container(
        color: Colors.black,
        child: Center(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.camera_alt, color: Colors.white38, size: 40),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _isRecording
                      ? 'Yakala...'
                      : _isReady
                      ? 'Canlı önizleme hazırlanıyor...'
                      : 'Bekleniyor',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasPreviewBytes)
          Image.memory(
            previewBytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          )
        else
          Image.file(
            lastFrame!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
        if (_phase == CaptureWorkflowPhase.calibration)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CheckerboardOverlayPainter(
                  checkerCorners: checkerCorners,
                  checkerFound: checkerFound,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDepthPreview() {
    final depthBytes = _depthPreviewBytes;
    final hasDepth = depthBytes != null && depthBytes.isNotEmpty;

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasDepth)
            Image.memory(
              depthBytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.blur_on, color: Colors.white38, size: 42),
                  SizedBox(height: 8),
                  Text(
                    'Canlı derinlik haritası bekleniyor...',
                    style: TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: const Text(
                'Derinlik Haritası',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhaseSelector() {
    final phases = CaptureWorkflowPhase.values;

    return Row(
      children: List.generate(phases.length, (index) {
        final phase = phases[index];
        final isSelected = _phase == phase;

        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: index < phases.length - 1 ? 8 : 0),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                backgroundColor: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                foregroundColor: isSelected ? Colors.white : Colors.white70,
                side: BorderSide(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white24,
                ),
              ),
              onPressed: () {
                unawaited(_setPhase(phase));
              },
              child: Text(
                '${phase.shortLabel} ${phase.title}',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildCameraDropdowns() {
    if (_availableBackCameraIds.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: _buildDropdown('Kamera 1', _cam1Id, (val) {
            if (val == null) return;
            if (val == _cam1Id) return;
            _onCameraSelectionChanged(cam1Id: val);
          }),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildDropdown('Kamera 2', _cam2Id, (val) {
            if (val == null) return;
            if (val == _cam2Id) return;
            _onCameraSelectionChanged(cam2Id: val);
          }),
        ),
      ],
    );
  }

  void _onCameraSelectionChanged({String? cam1Id, String? cam2Id}) {
    final nextCam1 = cam1Id ?? _cam1Id;
    final nextCam2 = cam2Id ?? _cam2Id;

    if (nextCam1 == null || nextCam2 == null) {
      return;
    }

    if (nextCam1 == nextCam2) {
      setState(() {
        _cam1Id = nextCam1;
        _cam2Id = nextCam2;
        _isReady = false;
        _status = 'Kamera 1 ve Kamera 2 aynı olamaz.';
      });
      return;
    }

    setState(() {
      _cam1Id = nextCam1;
      _cam2Id = nextCam2;
      _isReady = false;
      _status = 'Kamera seçimi güncellendi. Otomatik açılıyor...';
    });

    unawaited(_openSelectedCameras(nextCam1, nextCam2));
  }

  Widget _buildDropdown(
    String label,
    String? currentValue,
    ValueChanged<String?> onChanged,
  ) {
    final effectiveValue =
        (currentValue != null && _availableBackCameraIds.contains(currentValue))
        ? currentValue
        : (_availableBackCameraIds.isNotEmpty
              ? _availableBackCameraIds.first
              : null);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButton<String>(
        value: effectiveValue,
        isExpanded: true,
        dropdownColor: Colors.grey.shade800,
        style: const TextStyle(color: Colors.white),
        underline: const SizedBox.shrink(),
        onChanged: _isRecording ? null : onChanged,
        items: _availableBackCameraIds.map((id) {
          final option = _cameraOptionsById[id];
          final text = option?.compactLabel ?? 'Back • id=$id';
          return DropdownMenuItem(
            value: id,
            child: Text('$label: $text', overflow: TextOverflow.ellipsis),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSelectedCameraInfo() {
    final cam1 = _cam1Id == null ? null : _cameraOptionsById[_cam1Id!];
    final cam2 = _cam2Id == null ? null : _cameraOptionsById[_cam2Id!];

    if (cam1 == null && cam2 == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cam1 != null)
          Text(
            'Kamera 1: ${cam1.compactLabel}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        if (cam2 != null)
          Text(
            'Kamera 2: ${cam2.compactLabel}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
      ],
    );
  }

  Widget _buildPhaseContent() {
    switch (_phase) {
      case CaptureWorkflowPhase.cameraSelection:
        return _buildPhaseOneContent();
      case CaptureWorkflowPhase.calibration:
        return _buildPhaseTwoContent();
      case CaptureWorkflowPhase.stereoMatching:
        return _buildPhaseThreeContent();
      case CaptureWorkflowPhase.depthMap:
        return _buildPhaseFourContent();
    }
  }

  Widget _buildPhaseOneContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCameraDropdowns(),
        const SizedBox(height: 6),
        _buildSelectedCameraInfo(),
        const SizedBox(height: 8),
        const Text(
          'Faz 2’de checkerboard her tespit edildiğinde açı otomatik kaydedilir.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: !_isReady
                ? null
                : () {
                    unawaited(_setPhase(CaptureWorkflowPhase.calibration));
                  },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Faz 2’ye Geç (Kalibrasyon)'),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('Görünüm:', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<String>(
                value: _settings.effectiveViewMode,
                isExpanded: true,
                dropdownColor: Colors.grey.shade800,
                style: const TextStyle(color: Colors.white),
                onChanged: (value) {
                  if (value == null) return;
                  unawaited(
                    _persistAndSetSettings(_settings.copyWith(viewMode: value)),
                  );
                },
                items: AppSettings.viewModes
                    .map(
                      (mode) =>
                          DropdownMenuItem(value: mode, child: Text(mode)),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Text('FPS:', style: TextStyle(color: Colors.white70)),
            Expanded(
              child: Slider(
                value: _settings.effectiveCaptureIntervalMs.toDouble(),
                min: 20,
                max: 2000,
                divisions: 18,
                label: '${_settings.effectiveCaptureIntervalMs} ms',
                onChanged: _onIntervalChanged,
              ),
            ),
            Text(
              '${_settings.effectiveCaptureIntervalMs}ms',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              selected: _settings.effectiveEnableStats,
              label: const Text('Stats'),
              onSelected: (value) {
                unawaited(
                  _persistAndSetSettings(
                    _settings.copyWith(enableStats: value),
                    refreshSensors: true,
                  ),
                );
              },
            ),
            FilterChip(
              selected: _settings.effectiveEnableImu,
              label: const Text('IMU'),
              onSelected: (value) {
                unawaited(
                  _persistAndSetSettings(
                    _settings.copyWith(enableImu: value),
                    refreshSensors: true,
                  ),
                );
              },
            ),
            FilterChip(
              selected: _settings.effectiveEnableFot,
              label: const Text('FoT'),
              onSelected: (value) {
                unawaited(
                  _persistAndSetSettings(
                    _settings.copyWith(enableFot: value),
                    refreshSensors: true,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPhaseTwoContent() {
    final activeSessionPath =
        _lastCompletedSessionPath ?? _activeSessionDir?.path;
    final sessionName = activeSessionPath == null
        ? '-'
        : activeSessionPath.split(Platform.pathSeparator).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Checkerboard ile kaydedilen oturumdan intrinsic/extrinsic hesaplanır.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        const Text(
          'Yönerge: 10x7 (önerilen), 7x10, 7x7, 9x6 veya 6x9 iç köşe dama tahtasını iki kamerada da tamamen görünür tutun; farklı açı/mesafelerde yavaşça hareket ettirin ve titremesiz bir kadraj sağlayın.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Text(
          'Toplanan açı: $_capturedCalibrationPairs/$_requiredCalibrationPairs',
          style: const TextStyle(color: Colors.lightBlueAccent),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text(
              'Hedef fotoğraf:',
              style: TextStyle(color: Colors.white70),
            ),
            Expanded(
              child: Slider(
                value: _requiredCalibrationPairs.toDouble(),
                min: _minRequiredCalibrationPairs.toDouble(),
                max: _maxRequiredCalibrationPairs.toDouble(),
                divisions:
                    _maxRequiredCalibrationPairs - _minRequiredCalibrationPairs,
                label: '$_requiredCalibrationPairs',
                onChanged: _isStereoProcessing || _isCheckerboardDetecting
                    ? null
                    : (value) {
                        final nextRequired = value.round();
                        if (nextRequired == _requiredCalibrationPairs) {
                          return;
                        }
                        setState(() {
                          _requiredCalibrationPairs = nextRequired;
                          if (_capturedCalibrationPairs >
                              _requiredCalibrationPairs) {
                            _capturedCalibrationPairs = _requiredCalibrationPairs;
                          }
                          _checkerboardStatus = _capturedCalibrationPairs >=
                                  _requiredCalibrationPairs
                              ? '✓ Gerekli fotoğraf sayısı tamamlandı ($_capturedCalibrationPairs/$_requiredCalibrationPairs).'
                              : 'Hazır. Kaydı başlatmak için "Çekimi Başlat" butonuna basın ($_capturedCalibrationPairs/$_requiredCalibrationPairs).';
                        });
                      },
              ),
            ),
            Text(
              '$_requiredCalibrationPairs',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _checkerboardStatus,
          style: TextStyle(
            color: _checkerboardStatus.startsWith('✓')
                ? Colors.lightGreenAccent
                : Colors.orangeAccent,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _cachedCalibrationLabel(),
          style: TextStyle(
            color: _hasCachedCalibration
                ? Colors.lightGreenAccent
                : Colors.orangeAccent,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Oturum: $sessionName',
          style: const TextStyle(color: Colors.white),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _isStereoProcessing || _isCheckerboardDetecting
                  ? null
                  : () {
                      if (_isCalibrationCaptureRunning) {
                        _stopPhase2Capture(
                          checkerboardStatus:
                              'Çekim durduruldu ($_capturedCalibrationPairs/$_requiredCalibrationPairs).',
                          status: 'Faz 2 çekim durduruldu.',
                        );
                        return;
                      }
                      _startPhase2Capture();
                    },
              icon: Icon(
                _isCalibrationCaptureRunning
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(
                _isCalibrationCaptureRunning
                    ? 'Çekimi Durdur'
                    : 'Çekimi Başlat',
              ),
            ),
            OutlinedButton.icon(
              onPressed: _isStereoProcessing || _isCheckerboardDetecting
                  ? null
                  : () {
                      unawaited(_checkCheckerboardInPreview());
                    },
              icon: const Icon(Icons.grid_4x4),
              label: const Text('Dama Tahtası Ara'),
            ),
            FilledButton.icon(
              onPressed:
                  _isStereoProcessing ||
                      _capturedCalibrationPairs < _requiredCalibrationPairs
                  ? null
                  : _runCalibrationOnDevice,
              icon: const Icon(Icons.tune),
              label: const Text('OpenCV Kalibrasyon'),
            ),
            OutlinedButton.icon(
              onPressed: _isStereoProcessing || !_hasCachedCalibration
                  ? null
                  : () async {
                      await _setPhase(CaptureWorkflowPhase.stereoMatching);
                      if (!mounted) return;
                      setState(() {
                        _status =
                            'Kayıtlı kalibrasyon ile Faz 3 açıldı. Checkerboard çekimine gerek yok.';
                        _stereoStatus =
                            'Kayıtlı kalibrasyon hazır. Faz 3’te canlı rectify başlatabilirsiniz.';
                      });
                    },
              icon: const Icon(Icons.memory),
              label: const Text('Kayıtlı Kalibrasyon ile Faz 3'),
            ),
            OutlinedButton(
              onPressed: _isStereoProcessing
                  ? null
                  : () {
                      unawaited(
                        _setPhase(CaptureWorkflowPhase.cameraSelection),
                      );
                    },
              child: const Text('Faz 1'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPhaseThreeContent() {
    final sessionName = _lastCompletedSessionPath == null
        ? '-'
        : _lastCompletedSessionPath!.split(Platform.pathSeparator).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Kalibrasyon sonrası canlı rectified sol/sağ akış burada izlenir.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Text(
          'Oturum: $sessionName',
          style: const TextStyle(color: Colors.white),
        ),
        if ((_lastRectifiedOutputPath ?? '').isNotEmpty)
          Text(
            'Çıktı: $_lastRectifiedOutputPath',
            style: const TextStyle(color: Colors.lightGreenAccent),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isStereoProcessing ? null : _runRectifyOnDevice,
                icon: Icon(
                  _showRectifiedPreview
                      ? Icons.pause_circle_outline
                      : Icons.auto_fix_high,
                ),
                label: Text(
                  _showRectifiedPreview
                      ? 'Canlı Rectify Durdur'
                      : 'Canlı Rectify Başlat',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _isStereoProcessing
                  ? null
                  : () {
                      unawaited(
                        _setPhase(CaptureWorkflowPhase.cameraSelection),
                      );
                    },
              child: const Text('Faz 1'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPhaseFourContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Stereo görüntü işleme ile canlı derinlik haritası üretilir.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        const Text(
          'Isınmayı azaltmak için derinlik hesabı düşük çözünürlükte ve aralıklı çalışır.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isStereoProcessing ? null : _runDepthMapOnDevice,
                icon: Icon(
                  _showDepthPreview
                      ? Icons.pause_circle_outline
                      : Icons.blur_on,
                ),
                label: Text(
                  _showDepthPreview
                      ? 'Canlı Derinlik Durdur'
                      : 'Canlı Derinlik Başlat',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _isStereoProcessing
                  ? null
                  : () {
                      unawaited(
                        _setPhase(CaptureWorkflowPhase.cameraSelection),
                      );
                    },
              child: const Text('Faz 1'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentViewMode = _settings.effectiveViewMode;
    final showRectifiedInPreview =
        _phase == CaptureWorkflowPhase.stereoMatching &&
        _showRectifiedPreview;
    final cam1PreviewBytes = showRectifiedInPreview
        ? (_rectifiedCam1PreviewBytes ?? _lastCam1PreviewBytes)
        : _lastCam1PreviewBytes;
    final cam2PreviewBytes = showRectifiedInPreview
        ? (_rectifiedCam2PreviewBytes ?? _lastCam2PreviewBytes)
        : _lastCam2PreviewBytes;

    return Scaffold(
      appBar: AppBar(
        title: Text('Stereo Pipeline - ${_phase.shortLabel} ${_phase.title}'),
      ),
      body: Column(
        children: [
          Expanded(
            child: _phase == CaptureWorkflowPhase.depthMap
                ? _buildDepthPreview()
                : Row(
                    children: [
                      if (currentViewMode == 'Çift Kamera' ||
                          currentViewMode == 'Tek Kamera (Kam 1)')
                        Expanded(
                          child: _buildPreview(
                            cam1PreviewBytes,
                            _lastCam1Frame,
                            'Arka Kamera 1',
                            checkerCorners: _cam1CheckerboardCorners,
                            checkerFound: _checkerboardFoundCam1,
                          ),
                        ),
                      if (currentViewMode == 'Çift Kamera' ||
                          currentViewMode == 'Tek Kamera (Kam 2)')
                        Expanded(
                          child: _buildPreview(
                            cam2PreviewBytes,
                            _lastCam2Frame,
                            'Arka Kamera 2',
                            checkerCorners: _cam2CheckerboardCorners,
                            checkerFound: _checkerboardFoundCam2,
                          ),
                        ),
                    ],
                  ),
          ),
          if (_settings.effectiveEnableStats)
            MulticamStatsBar(stats: _systemStats, actualFps: _actualFps),
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildPhaseSelector(),
                const SizedBox(height: 8),
                _buildPhaseContent(),
                const SizedBox(height: 8),
                Text(_status, style: const TextStyle(color: Colors.white)),
                if (_stereoStatus.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _stereoStatus,
                    style: const TextStyle(color: Colors.amberAccent),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'FoT: ${_settings.effectiveEnableFot ? (_fotCm?.toStringAsFixed(2) ?? '-') : 'Kapalı'} | '
                  'Acc: ${_settings.effectiveEnableImu ? '${_fmt(_accX, digits: 2)}, ${_fmt(_accY, digits: 2)}, ${_fmt(_accZ, digits: 2)}' : 'Kapalı'} | '
                  'Gyro: ${_settings.effectiveEnableImu ? '${_fmt(_gyroX, digits: 2)}, ${_fmt(_gyroY, digits: 2)}, ${_fmt(_gyroZ, digits: 2)}' : 'Kapalı'}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckerboardOverlayPainter extends CustomPainter {
  final List<Offset> checkerCorners;
  final bool checkerFound;

  const _CheckerboardOverlayPainter({
    required this.checkerCorners,
    required this.checkerFound,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (checkerCorners.isEmpty) {
      return;
    }

    final pointPaint = Paint()
      ..color = checkerFound
          ? Colors.lightGreenAccent.withOpacity(0.95)
          : Colors.orangeAccent.withOpacity(0.95)
      ..style = PaintingStyle.fill;

    for (final corner in checkerCorners) {
      final point = Offset(corner.dx * size.width, corner.dy * size.height);
      canvas.drawCircle(point, 2.2, pointPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardOverlayPainter oldDelegate) {
    if (checkerFound != oldDelegate.checkerFound) {
      return true;
    }
    if (checkerCorners.length != oldDelegate.checkerCorners.length) {
      return true;
    }
    for (var index = 0; index < checkerCorners.length; index++) {
      if (checkerCorners[index] != oldDelegate.checkerCorners[index]) {
        return true;
      }
    }
    return false;
  }
}
