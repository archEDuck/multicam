import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'app/application/usecases/calibrate_stereo_session_use_case.dart';
import 'app/application/usecases/get_system_stats_use_case.dart';
import 'app/application/usecases/load_app_settings_use_case.dart';
import 'app/application/usecases/rectify_stereo_session_use_case.dart';
import 'app/application/usecases/save_app_settings_use_case.dart';
import 'app/application/usecases/warm_up_system_stats_use_case.dart';
import 'app/domain/entities/app_settings.dart';
import 'app/domain/entities/capture_workflow_phase.dart';
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

  late final SettingsController _settingsController;
  late final WarmUpSystemStatsUseCase _warmUpSystemStatsUseCase;
  late final GetSystemStatsUseCase _getSystemStatsUseCase;
  late final CalibrateStereoSessionUseCase _calibrateStereoSessionUseCase;
  late final RectifyStereoSessionUseCase _rectifyStereoSessionUseCase;

  StreamSubscription<dynamic>? _fotSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  Timer? _captureTimer;
  Timer? _statsTimer;
  Timer? _previewTimer;

  bool _isReady = false;
  bool _isRecording = false;
  bool _isCapturing = false;
  bool _isStereoProcessing = false;
  bool _isOpeningCameras = false;
  bool _isPreviewCapturing = false;

  String _status = 'Başlatılıyor...';
  String _camera2Status = 'Camera2 raporu hazırlanıyor...';
  String _stereoStatus = '';

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
  String? _cam1Id;
  String? _cam2Id;
  File? _lastCam1Frame;
  File? _lastCam2Frame;
  int _cam1FrameKey = 0;
  int _cam2FrameKey = 0;
  int _previewFrameIndex = 0;

  String? _activeCam1Id;
  String? _activeCam2Id;
  Directory? _previewDir;

  String? _lastCompletedSessionPath;
  String? _lastRectifiedOutputPath;

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
    _calibrateStereoSessionUseCase = CalibrateStereoSessionUseCase(
      stereoRepository,
    );
    _rectifyStereoSessionUseCase = RectifyStereoSessionUseCase(
      stereoRepository,
    );

    _initialize();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _stopStatsPolling();
    _stopPreviewLoop();
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
      final backCameraIds =
          (report['backCameraIds'] as List?)
              ?.map((item) => item.toString())
              .toList() ??
          <String>[];

      if (!mounted) return;
      setState(() {
        _availableBackCameraIds = backCameraIds;
        _camera2Status =
            'Camera2: ${backCameraIds.length} arka kamera bulundu (${backCameraIds.join(', ')})';
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

    var openedSuccessfully = false;
    var openedMode = '';

    if (!mounted) {
      _isOpeningCameras = false;
      return;
    }
    setState(() {
      _isReady = false;
      _cam1Id = cam1;
      _cam2Id = cam2;
      _lastCam1Frame = null;
      _lastCam2Frame = null;
      _status = 'Kameralar açılıyor ($cam1, $cam2)...';
    });

    try {
      await Camera2Bridge.closeDualCameras();

      final openResult = await Camera2Bridge.openDualCameras(cam1, cam2);
      final success = openResult['success'] == true;
      final openMode = openResult['mode'] ?? 'unknown';
      openedMode = openMode.toString();

      if (!mounted) return;

      if (success) {
        openedSuccessfully = true;
        final modeLabel = openMode == 'logical_multi_camera'
            ? 'Logical Multi-Camera ✓'
            : openMode == 'alternating'
            ? 'Alternating (sıralı çekim) ✓'
            : '$openMode ✓';
        setState(() {
          _isReady = true;
          _activeCam1Id = cam1;
          _activeCam2Id = cam2;
          _status = 'Hazır! $cam1 + $cam2 ($modeLabel).';
          _camera2Status = '${_camera2Status.split('|').first} | $modeLabel';
        });

        _startPreviewLoop();
      } else {
        final error = openResult['error'] ?? 'Bilinmeyen hata';
        setState(() {
          _isReady = false;
          _activeCam1Id = null;
          _activeCam2Id = null;
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
        _status = 'Dual kamera açılış hatası: $e';
      });
    } finally {
      _isOpeningCameras = false;
    }

    if (openedSuccessfully && openedMode == 'alternating') {
      await _tryRecoverFromAlternatingMode(
        attemptedCam1: cam1,
        attemptedCam2: cam2,
      );
    }
  }

  Future<void> _tryRecoverFromAlternatingMode({
    required String attemptedCam1,
    required String attemptedCam2,
  }) async {
    if (!mounted || _isRecording || _isOpeningCameras) return;

    final pairResult = await Camera2Bridge.findBestPair();
    if (!mounted) return;

    final found = pairResult['found'] == true;
    final mode = (pairResult['mode'] ?? '').toString();
    final bestCam1 = pairResult['cam1Id']?.toString();
    final bestCam2 = pairResult['cam2Id']?.toString();

    if (found &&
        mode == 'logical_multi_camera' &&
        bestCam1 != null &&
        bestCam2 != null &&
        (bestCam1 != attemptedCam1 || bestCam2 != attemptedCam2)) {
      setState(() {
        _status =
            'Seçilen çift senkron değil. En iyi senkron çifte geçiliyor ($bestCam1, $bestCam2)...';
      });
      await _openSelectedCameras(bestCam1, bestCam2);
      return;
    }

    setState(() {
      _status =
          'Seçilen çift alternating modda açıldı. Canlı eşzamanlı görüntü için farklı bir çift seç.';
    });
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

  Future<void> _toggleRecording() async {
    if (!_isReady) return;

    if (_isRecording) {
      _captureTimer?.cancel();
      final sessionDir = _activeSessionDir;

      _activeCsvFile = null;
      _activeSessionDir = null;

      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _lastCompletedSessionPath = sessionDir?.path;
        _phase = CaptureWorkflowPhase.calibration;
        _status =
            'Kayıt tamamlandı. Faz 2 için checkerboard kalibrasyonunu çalıştır.';
      });

      return;
    }

    _stopPreviewLoop();

    final sessionDir = await _createSessionFolder();
    final csvFile = File(
      '${sessionDir.path}${Platform.pathSeparator}capture_log.csv',
    );
    await csvFile.writeAsString(
      'frame,timestamp_utc,cam1_image,cam2_image,fot_cm,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,pose_tx,pose_ty,pose_tz,pose_qx,pose_qy,pose_qz,pose_qw,fx,fy,cx,cy,k1,k2,p1,p2,k3,lux,kelvin,exposure_ms,iso,plane_data,bbox_data,cam1_id,cam2_id,capture_mode\n',
      flush: true,
    );

    _frameIndex = 0;
    _activeSessionDir = sessionDir;
    _activeCsvFile = csvFile;

    if (!mounted) return;

    setState(() {
      _isRecording = true;
      _status =
          'Kayıt başladı | FPS: ${_fpsLabel(_settings.effectiveCaptureIntervalMs)}';
    });

    _startCaptureTimer();
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

  Future<Directory> _ensurePreviewDirectory() async {
    if (_previewDir != null) {
      return _previewDir!;
    }

    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}preview_frames',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _previewDir = dir;
    return dir;
  }

  void _startPreviewLoop() {
    if (!_isReady || _isRecording) return;

    _stopPreviewLoop();
    unawaited(_capturePreviewFrame());

    final intervalMs = _settings.effectiveCaptureIntervalMs.clamp(250, 1200);
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
      final dir = await _ensurePreviewDirectory();
      final slot = _previewFrameIndex % 2;
      _previewFrameIndex += 1;

      final cam1Path =
          '${dir.path}${Platform.pathSeparator}preview_cam1_$slot.jpg';
      final cam2Path =
          '${dir.path}${Platform.pathSeparator}preview_cam2_$slot.jpg';

      final result = await Camera2Bridge.captureDualFrame(cam1Path, cam2Path);
      if (!mounted) return;

      final cam1Saved = result['cam1Saved'] == true;
      final cam2Saved = result['cam2Saved'] == true;

      if (!cam1Saved && !cam2Saved) {
        return;
      }

      if (cam1Saved) {
        await FileImage(File(cam1Path)).evict();
      }
      if (cam2Saved) {
        await FileImage(File(cam2Path)).evict();
      }

      setState(() {
        if (cam1Saved) {
          _lastCam1Frame = File(cam1Path);
          _cam1FrameKey += 1;
        }
        if (cam2Saved) {
          _lastCam2Frame = File(cam2Path);
          _cam2FrameKey += 1;
        }
      });
    } catch (_) {
      // Ignore preview errors; recording path remains authoritative.
    } finally {
      _isPreviewCapturing = false;
    }
  }

  Future<void> _runCalibrationOnDevice() async {
    if (_isStereoProcessing) return;
    final sessionPath = _lastCompletedSessionPath;
    if (sessionPath == null || sessionPath.isEmpty) {
      if (!mounted) return;
      setState(() {
        _stereoStatus = 'Önce Faz 1 ile bir oturum kaydet.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = true;
      _stereoStatus = 'OpenCV kalibrasyon çalışıyor...';
    });

    final result = await _calibrateStereoSessionUseCase(sessionPath);

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = false;
      _stereoStatus =
          '${result.success ? '✓' : '✗'} ${result.message} (çift: ${result.processedPairs})';
      if (result.success) {
        _phase = CaptureWorkflowPhase.stereoMatching;
        _status = 'Kalibrasyon tamamlandı. Faz 3 ile stereo rectify başlat.';
      }
    });
  }

  Future<void> _runRectifyOnDevice() async {
    if (_isStereoProcessing) return;
    final sessionPath = _lastCompletedSessionPath;
    if (sessionPath == null || sessionPath.isEmpty) {
      if (!mounted) return;
      setState(() {
        _stereoStatus = 'Rectify için önce bir oturum kaydet.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = true;
      _stereoStatus = 'OpenCV rectify çalışıyor...';
    });

    final result = await _rectifyStereoSessionUseCase(sessionPath);

    if (!mounted) return;
    setState(() {
      _isStereoProcessing = false;
      _lastRectifiedOutputPath = result.outputPath.isNotEmpty
          ? result.outputPath
          : _lastRectifiedOutputPath;
      _stereoStatus =
          '${result.success ? '✓' : '✗'} ${result.message} (çift: ${result.processedPairs})';
      if (result.success) {
        _status = 'Stereo rectify tamamlandı. Çıktılar cihazda hazır.';
      }
    });
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
          _cam1FrameKey++;
        });
      }
      if (cam2Saved && mounted) {
        setState(() {
          _lastCam2Frame = File(cam2FullPath);
          _cam2FrameKey++;
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

  Widget _buildPreview(File? lastFrame, int frameKey, String label) {
    if (lastFrame == null || !lastFrame.existsSync()) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt, color: Colors.white38, size: 48),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 16),
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
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          lastFrame,
          key: ValueKey('${label}_$frameKey'),
          fit: BoxFit.cover,
          gaplessPlayback: true,
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
      ],
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
                setState(() {
                  _phase = phase;
                });
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
          return DropdownMenuItem(value: id, child: Text('$label: $id'));
        }).toList(),
      ),
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
    }
  }

  Widget _buildPhaseOneContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCameraDropdowns(),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isReady ? _toggleRecording : null,
            icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(_isRecording ? 'Kaydı Durdur' : 'Kaydı Başlat'),
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
    final sessionName = _lastCompletedSessionPath == null
        ? '-'
        : _lastCompletedSessionPath!.split(Platform.pathSeparator).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Checkerboard ile kaydedilen oturumdan intrinsic/extrinsic hesaplanır.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        Text(
          'Oturum: $sessionName',
          style: const TextStyle(color: Colors.white),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isStereoProcessing ? null : _runCalibrationOnDevice,
                icon: const Icon(Icons.tune),
                label: const Text('OpenCV Kalibrasyon'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _isStereoProcessing
                  ? null
                  : () {
                      setState(() {
                        _phase = CaptureWorkflowPhase.cameraSelection;
                      });
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
          'Kalibrasyon sonrası stereo rectify cihaz üzerinde çalışır.',
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
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('OpenCV Stereo Rectify'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _isStereoProcessing
                  ? null
                  : () {
                      setState(() {
                        _phase = CaptureWorkflowPhase.cameraSelection;
                      });
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

    return Scaffold(
      appBar: AppBar(
        title: Text('Stereo Pipeline - ${_phase.shortLabel} ${_phase.title}'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                if (currentViewMode == 'Çift Kamera' ||
                    currentViewMode == 'Tek Kamera (Kam 1)')
                  Expanded(
                    child: _buildPreview(
                      _lastCam1Frame,
                      _cam1FrameKey,
                      'Arka Kamera 1',
                    ),
                  ),
                if (currentViewMode == 'Çift Kamera' ||
                    currentViewMode == 'Tek Kamera (Kam 2)')
                  Expanded(
                    child: _buildPreview(
                      _lastCam2Frame,
                      _cam2FrameKey,
                      'Arka Kamera 2',
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
                const SizedBox(height: 4),
                Text(
                  _camera2Status,
                  style: const TextStyle(color: Colors.lightBlueAccent),
                ),
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
