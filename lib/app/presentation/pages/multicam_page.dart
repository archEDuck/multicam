import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../application/usecases/build_depth_map_frame_pair_use_case.dart';
import '../../application/usecases/calibrate_stereo_session_use_case.dart';
import '../../application/usecases/check_checkerboard_frame_pair_use_case.dart';
import '../../application/usecases/get_calibration_status_use_case.dart';
import '../../application/usecases/get_system_stats_use_case.dart';
import '../../application/usecases/load_app_settings_use_case.dart';
import '../../application/usecases/rectify_preview_frame_pair_use_case.dart';
import '../../application/usecases/save_app_settings_use_case.dart';
import '../../application/usecases/warm_up_system_stats_use_case.dart';
import '../../domain/entities/app_settings.dart';
import '../../domain/entities/camera_option.dart';
import '../../domain/entities/capture_workflow_phase.dart';
import '../../domain/entities/stereo_preprocess_result.dart';
import '../../domain/entities/system_stats.dart';
import '../../infrastructure/repositories/json_app_settings_repository.dart';
import '../../infrastructure/repositories/method_channel_stereo_preprocess_repository.dart';
import '../../infrastructure/repositories/method_channel_system_stats_repository.dart';
import '../controllers/settings_controller.dart';
import '../controllers/workflow_phase_transition_controller.dart';
import '../widgets/multicam_preview_panels.dart';
import '../widgets/multicam_stats_bar.dart';
import '../widgets/workflow/phase_panels.dart';
import '../widgets/workflow/phase_selector.dart';
import '../../../camera2_bridge.dart';

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
  Map<String, CameraOption> _cameraOptionsById = {};
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
  final WorkflowPhaseTransitionController _phaseTransitionController =
      const WorkflowPhaseTransitionController();

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
    _getCalibrationStatusUseCase = GetCalibrationStatusUseCase(
      stereoRepository,
    );
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

  List<CameraOption> _parseBackCameraOptions(Map<String, dynamic> report) {
    final rawOptions = report['backCameraOptions'];
    if (rawOptions is List) {
      final parsed = rawOptions
          .whereType<Map>()
          .map((item) => CameraOption.fromMap(item))
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
          (id) => CameraOption(
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
            'Faz 2: $_capturedCalibrationPairs/$_requiredCalibrationPairs kaydedildi. Kartı 1-2 sn içinde yeni açıya taşı.';
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
      await _transitionToPhase(
        CaptureWorkflowPhase.stereoMatching,
        intent: PhaseTransitionIntent.calibrationCompleted,
      );
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
    if (_phase != CaptureWorkflowPhase.stereoMatching ||
        !_showRectifiedPreview) {
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
      final result = await _rectifyPreviewFramePairUseCase(
        cam1Bytes,
        cam2Bytes,
      );
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
    return CameraPreviewPanel(
      previewBytes: previewBytes,
      lastFrame: lastFrame,
      label: label,
      isRecording: _isRecording,
      isReady: _isReady,
      showCheckerboardOverlay: _phase == CaptureWorkflowPhase.calibration,
      checkerCorners: checkerCorners,
      checkerFound: checkerFound,
    );
  }

  Widget _buildDepthPreview() {
    return DepthPreviewPanel(depthBytes: _depthPreviewBytes);
  }

  Future<void> _transitionToPhase(
    CaptureWorkflowPhase nextPhase, {
    PhaseTransitionIntent intent = PhaseTransitionIntent.manual,
  }) async {
    final transitionPlan = _phaseTransitionController.plan(
      currentPhase: _phase,
      nextPhase: nextPhase,
      isStereoProcessing: _isStereoProcessing,
      isOpeningCameras: _isOpeningCameras,
      isReady: _isReady,
      hasCachedCalibration: _hasCachedCalibration,
      intent: intent,
    );

    if (!transitionPlan.allowed) {
      if (!mounted) return;
      setState(() {
        _status = transitionPlan.blockMessage ?? _status;
      });
      return;
    }

    if (_phase == CaptureWorkflowPhase.calibration &&
        nextPhase != CaptureWorkflowPhase.calibration &&
        _isCalibrationCaptureRunning) {
      _stopPhase2Capture(
        checkerboardStatus:
            'Çekim durduruldu ($_capturedCalibrationPairs/$_requiredCalibrationPairs).',
        status: 'Faz 2 çekim durduruldu.',
      );
    }

    await _setPhase(nextPhase);

    if (!mounted) return;
    setState(() {
      if ((transitionPlan.statusMessage ?? '').isNotEmpty) {
        _status = transitionPlan.statusMessage!;
      }
      if (transitionPlan.clearStereoStatus) {
        _stereoStatus = '';
      }
      if ((transitionPlan.stereoStatusMessage ?? '').isNotEmpty) {
        _stereoStatus = transitionPlan.stereoStatusMessage!;
      }
    });
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

  void _onRequiredCalibrationPairsChanged(double value) {
    final nextRequired = value.round();
    if (nextRequired == _requiredCalibrationPairs) {
      return;
    }

    setState(() {
      _requiredCalibrationPairs = nextRequired;
      if (_capturedCalibrationPairs > _requiredCalibrationPairs) {
        _capturedCalibrationPairs = _requiredCalibrationPairs;
      }
      _checkerboardStatus =
          _capturedCalibrationPairs >= _requiredCalibrationPairs
          ? '✓ Gerekli fotoğraf sayısı tamamlandı ($_capturedCalibrationPairs/$_requiredCalibrationPairs).'
          : 'Hazır. Kaydı başlatmak için "Çekimi Başlat" butonuna basın ($_capturedCalibrationPairs/$_requiredCalibrationPairs).';
    });
  }

  void _togglePhaseTwoCapture() {
    if (_isCalibrationCaptureRunning) {
      _stopPhase2Capture(
        checkerboardStatus:
            'Çekim durduruldu ($_capturedCalibrationPairs/$_requiredCalibrationPairs).',
        status: 'Faz 2 çekim durduruldu.',
      );
      return;
    }
    _startPhase2Capture();
  }

  Widget _buildPhaseSelector() {
    return WorkflowPhaseSelector(
      selectedPhase: _phase,
      enabled: !_isStereoProcessing && !_isOpeningCameras,
      onPhaseSelected: (phase) {
        unawaited(_transitionToPhase(phase));
      },
    );
  }

  Widget _buildPhaseContent() {
    final calibrationSessionPath =
        _lastCompletedSessionPath ?? _activeSessionDir?.path;
    final calibrationSessionName = calibrationSessionPath == null
        ? '-'
        : calibrationSessionPath.split(Platform.pathSeparator).last;

    final stereoSessionName = _lastCompletedSessionPath == null
        ? '-'
        : _lastCompletedSessionPath!.split(Platform.pathSeparator).last;

    switch (_phase) {
      case CaptureWorkflowPhase.cameraSelection:
        return CameraSelectionPhasePanel(
          availableBackCameraIds: _availableBackCameraIds,
          cameraOptionsById: _cameraOptionsById,
          cam1Id: _cam1Id,
          cam2Id: _cam2Id,
          isRecording: _isRecording,
          isReady: _isReady,
          settings: _settings,
          onCam1Changed: (val) {
            if (val == null || val == _cam1Id) return;
            _onCameraSelectionChanged(cam1Id: val);
          },
          onCam2Changed: (val) {
            if (val == null || val == _cam2Id) return;
            _onCameraSelectionChanged(cam2Id: val);
          },
          onViewModeChanged: (value) {
            unawaited(
              _persistAndSetSettings(_settings.copyWith(viewMode: value)),
            );
          },
          onIntervalChanged: _onIntervalChanged,
          onToggleStats: (value) {
            unawaited(
              _persistAndSetSettings(
                _settings.copyWith(enableStats: value),
                refreshSensors: true,
              ),
            );
          },
          onToggleImu: (value) {
            unawaited(
              _persistAndSetSettings(
                _settings.copyWith(enableImu: value),
                refreshSensors: true,
              ),
            );
          },
          onToggleFot: (value) {
            unawaited(
              _persistAndSetSettings(
                _settings.copyWith(enableFot: value),
                refreshSensors: true,
              ),
            );
          },
          onGoCalibration: () {
            unawaited(_transitionToPhase(CaptureWorkflowPhase.calibration));
          },
        );
      case CaptureWorkflowPhase.calibration:
        return CalibrationPhasePanel(
          capturedCalibrationPairs: _capturedCalibrationPairs,
          requiredCalibrationPairs: _requiredCalibrationPairs,
          minRequiredCalibrationPairs: _minRequiredCalibrationPairs,
          maxRequiredCalibrationPairs: _maxRequiredCalibrationPairs,
          isStereoProcessing: _isStereoProcessing,
          isCheckerboardDetecting: _isCheckerboardDetecting,
          isCalibrationCaptureRunning: _isCalibrationCaptureRunning,
          canUseCachedCalibration:
              !_isStereoProcessing && _hasCachedCalibration,
          canRunCalibration:
              !_isStereoProcessing &&
              _capturedCalibrationPairs >= _requiredCalibrationPairs,
          hasCachedCalibration: _hasCachedCalibration,
          checkerboardStatus: _checkerboardStatus,
          cachedCalibrationLabel: _cachedCalibrationLabel(),
          sessionName: calibrationSessionName,
          onRequiredPairsChanged: _onRequiredCalibrationPairsChanged,
          onToggleCapture: _togglePhaseTwoCapture,
          onCheckCheckerboard: () {
            unawaited(_checkCheckerboardInPreview());
          },
          onRunCalibration: _runCalibrationOnDevice,
          onUseCachedCalibration: () {
            unawaited(
              _transitionToPhase(
                CaptureWorkflowPhase.stereoMatching,
                intent: PhaseTransitionIntent.cachedCalibrationShortcut,
              ),
            );
          },
          onBackToPhaseOne: () {
            unawaited(_transitionToPhase(CaptureWorkflowPhase.cameraSelection));
          },
        );
      case CaptureWorkflowPhase.stereoMatching:
        return StereoMatchingPhasePanel(
          isStereoProcessing: _isStereoProcessing,
          showRectifiedPreview: _showRectifiedPreview,
          sessionName: stereoSessionName,
          rectifiedOutputPath: _lastRectifiedOutputPath,
          onToggleLiveRectify: _runRectifyOnDevice,
          onBackToPhaseOne: () {
            unawaited(_transitionToPhase(CaptureWorkflowPhase.cameraSelection));
          },
        );
      case CaptureWorkflowPhase.depthMap:
        return DepthMapPhasePanel(
          isStereoProcessing: _isStereoProcessing,
          showDepthPreview: _showDepthPreview,
          onToggleLiveDepth: _runDepthMapOnDevice,
          onBackToPhaseOne: () {
            unawaited(_transitionToPhase(CaptureWorkflowPhase.cameraSelection));
          },
        );
    }
  }

  Color _statusColor(String text, ColorScheme colorScheme) {
    final normalized = text.trim().toLowerCase();
    if (normalized.startsWith('✓')) {
      return colorScheme.tertiary;
    }
    if (normalized.startsWith('✗') || normalized.contains('hata')) {
      return colorScheme.error;
    }
    return colorScheme.onSurfaceVariant;
  }

  String _sensorSummaryText() {
    final fotText = _settings.effectiveEnableFot
        ? (_fotCm?.toStringAsFixed(2) ?? '-')
        : 'Kapalı';
    final accText = _settings.effectiveEnableImu
        ? '${_fmt(_accX, digits: 2)}, ${_fmt(_accY, digits: 2)}, ${_fmt(_accZ, digits: 2)}'
        : 'Kapalı';
    final gyroText = _settings.effectiveEnableImu
        ? '${_fmt(_gyroX, digits: 2)}, ${_fmt(_gyroY, digits: 2)}, ${_fmt(_gyroZ, digits: 2)}'
        : 'Kapalı';

    return 'FoT: $fotText | Acc: $accText | Gyro: $gyroText';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final currentViewMode = _settings.effectiveViewMode;
    final showRectifiedInPreview =
        _phase == CaptureWorkflowPhase.stereoMatching && _showRectifiedPreview;
    final cam1PreviewBytes = showRectifiedInPreview
        ? (_rectifiedCam1PreviewBytes ?? _lastCam1PreviewBytes)
        : _lastCam1PreviewBytes;
    final cam2PreviewBytes = showRectifiedInPreview
        ? (_rectifiedCam2PreviewBytes ?? _lastCam2PreviewBytes)
        : _lastCam2PreviewBytes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stereo Pipeline'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${_phase.shortLabel} • ${_phase.title}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
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
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(
                  top: BorderSide(color: colorScheme.outlineVariant),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildPhaseSelector(),
                        const SizedBox(height: 10),
                        _buildPhaseContent(),
                        const SizedBox(height: 10),
                        Text(
                          _status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: _statusColor(_status, colorScheme),
                          ),
                        ),
                        if (_stereoStatus.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            _stereoStatus,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: _statusColor(_stereoStatus, colorScheme),
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          _sensorSummaryText(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
