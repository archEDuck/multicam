import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

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
      title: 'Multicam Recorder',
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

  StreamSubscription<dynamic>? _fotSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  Timer? _captureTimer;
  Timer? _statsTimer;

  bool _isReady = false;
  bool _isRecording = false;
  bool _isCapturing = false;

  String _status = 'Kameralar hazirlaniyor...';
  String _camera2Status = 'Camera2 raporu hazirlaniyor...';
  double? _fotCm;
  String? _sessionPath;
  int _frameIndex = 0;
  int _captureIntervalMs = 700;
  String _sessionMode = 'Normal';
  String _viewMode = 'Çift Kamera';
  final TextEditingController _ipController = TextEditingController(
    text:
        '188.191.107.81', // USB uzerinden adb reverse kullanilacak (veya 10.0.2.2 emulator icin)
  );

  double? _accX;
  double? _accY;
  double? _accZ;
  double? _gyroX;
  double? _gyroY;
  double? _gyroZ;

  double? _poseTx;
  double? _poseTy;
  double? _poseTz;
  double? _poseQx;
  double? _poseQy;
  double? _poseQz;
  double? _poseQw;

  File? _activeCsvFile;
  Directory? _activeSessionDir;

  // Native dual camera state
  List<String> _availableBackCameraIds = [];
  String? _cam1Id;
  String? _cam2Id;
  File? _lastCam1Frame;
  File? _lastCam2Frame;
  int _cam1FrameKey = 0;
  int _cam2FrameKey = 0;

  // System stats
  double _cpuPercent = 0;
  double _totalRamMB = 0;
  double _usedRamMB = 0;
  double _appHeapMB = 0;
  double _appNativeMB = 0;

  // FPS tracking
  DateTime? _lastCaptureTime;
  double _actualFps = 0;
  final List<double> _fpsHistory = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _statsTimer?.cancel();
    _fotSubscription?.cancel();
    _accSubscription?.cancel();
    _gyroSubscription?.cancel();
    _ipController.dispose();
    Camera2Bridge.closeDualCameras().catchError((_) {});
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final permissionStatus = await Permission.camera.request();
      if (!permissionStatus.isGranted) {
        setState(() {
          _status = 'Kamera izni gerekli. Ayarlardan izin verip tekrar dene.';
        });
        return;
      }

      // Storage permissions
      if (Platform.isAndroid) {
        if (await Permission.manageExternalStorage.isDenied) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }

      await _initDualCameras();

      _startFotStream();
      _startImuStreams();
      _startStatsPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Baslatma hatasi: $error';
      });
    }
  }

  Future<void> _initDualCameras() async {
    // Step 1: Get camera report for display info
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
            'Camera2: ${backCameraIds.length} arka kamera bulundu (${backCameraIds.join(", ")})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _camera2Status = 'Camera2 raporu alinamadi: $e';
      });
    }

    // Step 2: Find the best camera pair
    try {
      final pairResult = await Camera2Bridge.findBestPair();
      final found = pairResult['found'] == true;
      final mode = pairResult['mode'] ?? 'unknown';

      if (!found) {
        if (!mounted) return;
        setState(() {
          _status = 'Uyumlu arka kamera cifti bulunamadi!';
          _camera2Status += ' | Pair YOK';
        });
        return;
      }

      final cam1 = pairResult['cam1Id'] as String;
      final cam2 = pairResult['cam2Id'] as String;
      final logicalId = pairResult['logicalId'];

      if (!mounted) return;
      setState(() {
        _camera2Status +=
            ' | Mod: $mode | Info: $cam1 + $cam2${logicalId != null ? ' (logical=$logicalId)' : ''}';
      });

      // Default olarak en iyi çifti açalım
      await _openSelectedCameras(cam1, cam2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Baslangic kameralari bulunamadi: $e';
      });
    }
  }

  Future<void> _openSelectedCameras(String cam1, String cam2) async {
    if (!mounted) return;
    setState(() {
      _isReady = false;
      _cam1Id = cam1;
      _cam2Id = cam2;
      _status = 'Kameralar aciliyor ($cam1, $cam2)...';
    });

    try {
      // Önceki varsa kapat
      await Camera2Bridge.closeDualCameras();

      // Step 3: Open cameras via native Camera2 API
      final openResult = await Camera2Bridge.openDualCameras(cam1, cam2);
      final success = openResult['success'] == true;
      final openMode = openResult['mode'] ?? 'unknown';

      if (!mounted) return;

      if (success) {
        final modeLabel = openMode == 'logical_multi_camera'
            ? 'Logical Multi-Camera ✓'
            : openMode == 'alternating'
            ? 'Alternating (sirali cekim) ✓'
            : '$openMode ✓';
        setState(() {
          _isReady = true;
          _status = 'Hazir! $cam1 + $cam2 ($modeLabel). Kaydi baslat.';
          _camera2Status = _camera2Status.split('|').first + ' | $modeLabel';
        });
      } else {
        final error = openResult['error'] ?? 'Bilinmeyen hata';
        setState(() {
          _status = 'Dual kamera acilamadi: $error';
          _camera2Status += ' ✗ $error';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Dual kamera acilis hatasi: $e';
      });
    }
  }

  void _startFotStream() {
    _fotSubscription?.cancel();
    _fotSubscription = _fotSensorChannel.receiveBroadcastStream().listen(
      (value) {
        final parsed = double.tryParse(value.toString());
        if (!mounted) return;
        setState(() {
          _fotCm = parsed;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _fotCm = -1.0;
        });
      },
      cancelOnError: false,
    );
  }

  void _startImuStreams() {
    _accSubscription?.cancel();
    _gyroSubscription?.cancel();

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

  Future<void> _toggleRecording() async {
    if (!_isReady) return;

    if (_isRecording) {
      _captureTimer?.cancel();
      final sessionDir = _activeSessionDir;
      final sessionPath = _sessionPath;

      _activeCsvFile = null;
      _activeSessionDir = null;

      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _status = 'Kayit durduruldu. Dosyalar isleniyor (Lutfen bekleyin)...';
      });

      if (sessionDir != null) {
        try {
          // Cekim bittikten sonra arkadaki disk islem sureci icin 4 saniye bekleme
          await Future.delayed(const Duration(seconds: 4));

          if (!mounted) return;
          setState(() {
            _status = 'Dosyalar hazirlandi. ZIP olusturuluyor...';
          });

          final zipPath = await _zipSessionDirectory(sessionDir);
          if (!mounted) return;
          setState(() {
            _status = 'ZIP hazirlandi. Bilgisayara gonderiliyor... ($zipPath)';
          });
          await _uploadZip(zipPath);
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _status =
                'ZIP olusturulamadi: $error | Oturum: ${sessionPath ?? '-'}';
          });
        }
      }
      return;
    }

    final sessionDir = await _createSessionFolder();
    final csvFile = File(
      '${sessionDir.path}${Platform.pathSeparator}capture_log.csv',
    );
    await csvFile.writeAsString(
      'frame,timestamp_utc,cam1_image,cam2_image,fot_cm,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,pose_tx,pose_ty,pose_tz,pose_qx,pose_qy,pose_qz,pose_qw,fx,fy,cx,cy,k1,k2,p1,p2,k3,lux,kelvin,exposure_ms,iso,plane_data,bbox_data,cam1_id,cam2_id,capture_mode\n',
      flush: true,
    );

    _frameIndex = 0;
    _sessionPath = sessionDir.path;
    _activeSessionDir = sessionDir;
    _activeCsvFile = csvFile;

    if (!mounted) return;

    setState(() {
      _isRecording = true;
      _status = 'Kayit basladi | FPS: ${_fpsLabel(_captureIntervalMs)}';
    });

    _startCaptureTimer();
  }

  void _startCaptureTimer() {
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(Duration(milliseconds: _captureIntervalMs), (
      _,
    ) async {
      final csv = _activeCsvFile;
      final session = _activeSessionDir;
      if (csv == null || session == null) return;
      await _captureFramePair(csvFile: csv, sessionDir: session);
    });
  }

  Future<void> _uploadZip(String zipPath) async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty || ip.endsWith('.')) {
      setState(() {
        _status =
            'ZIP kaydedildikten sonra PC IP girilmedigi icin aktarilamadi.';
      });
      return;
    }

    try {
      final file = File(zipPath);
      if (!file.existsSync()) {
        setState(() {
          _status = 'Hata: ZIP dosyasi bulunamadi: $zipPath';
        });
        return;
      }

      final fileName = file.uri.pathSegments.last;
      final length = await file.length();
      if (length == 0) {
        setState(() {
          _status = 'Hata: Olusturulan ZIP dosyasi bos (0 byte)!';
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _status =
            'ZIP gonderiliyor... ($fileName, ${(length / 1024).toStringAsFixed(0)} KB)';
      });

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 45);
      final url = Uri.parse('http://$ip:5000/upload?file=$fileName');
      final request = await client.postUrl(url);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/zip');
      request.headers.set(HttpHeaders.contentLengthHeader, length.toString());
      request.contentLength = length;

      // BUYUK DOSYALARIN CÖKMEMESI VE SORUNSUZ İLETİLMESİ İÇİN STREAM KULLANILDI:
      await request.addStream(file.openRead());

      final response = await request.close();

      if (!mounted) return;
      if (response.statusCode == 200) {
        final respBody = await response.transform(utf8.decoder).join();
        print('DEBUG: Server response: $respBody');
        setState(() {
          _status =
              'ZIP Bilgisayara BASARIYLA GONDERILDI! ($fileName, ${(length / 1024).toStringAsFixed(0)} KB)';
        });
      } else {
        setState(() {
          _status = 'Gonderim Reddedildi: HTTP ${response.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Gonderim Hatasi: $e (Bilgisayardaki script acik mi?)';
      });
    }
  }

  Future<String> _zipSessionDirectory(Directory sessionDir) async {
    print('DEBUG: Checking session directory: ${sessionDir.path}');
    if (!sessionDir.existsSync()) {
      print('DEBUG: HATA! Session directory does not exist!');
      throw Exception('Session directory does not exist: ${sessionDir.path}');
    }

    // Tüm devam eden çekimlerin bitmesini beklemek ve
    // dosyalarin diske yazilmasi icin kisa bir bekleme süresi koyalim:
    int waitCounter = 0;
    while (_isCapturing && waitCounter < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitCounter++;
    }
    await Future.delayed(const Duration(seconds: 3));

    // Dizindeki dosyalari say ve listele
    final allFiles = <File>[];
    await for (final entity in sessionDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        allFiles.add(entity);
      }
    }

    print('ZIP: ${allFiles.length} dosya bulundu, session: ${sessionDir.path}');
    for (final f in allFiles) {
      final size = f.lengthSync();
      print('  -> ${f.path} ($size bytes)');
    }

    if (allFiles.isEmpty) {
      throw Exception(
        'Oturum klasoru bos — hic dosya bulunamadi: ${sessionDir.path}',
      );
    }

    if (!mounted) return '';
    setState(() {
      _status = '${allFiles.length} dosya bulundu, ZIP olusturuluyor...';
    });

    final zipPath = '${sessionDir.path}.zip';
    final encoder = ZipFileEncoder();

    try {
      encoder.create(zipPath);

      for (final file in allFiles) {
        if (!file.existsSync()) continue;
        final relativePath = file.path
            .substring(sessionDir.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        await encoder.addFile(file, relativePath);
      }

      await encoder.close();
    } catch (e) {
      print('ZIP Olusturma Hatasi: $e');
      // close cagrilmamissa tekrar deneyelim
      try {
        await encoder.close();
      } catch (_) {}
      rethrow;
    }

    // Dogrulama: ZIP dosyasinin gercekten dolu oldugunu kontrol et
    final zipFile = File(zipPath);
    final zipSize = zipFile.existsSync() ? zipFile.lengthSync() : 0;
    print('ZIP olusturuldu: $zipPath ($zipSize bytes)');

    if (zipSize == 0) {
      throw Exception('ZIP dosyasi 0 byte — olusturma basarisiz.');
    }

    if (mounted) {
      setState(() {
        _status =
            'ZIP olusturuldu: ${(zipSize / 1024).toStringAsFixed(0)} KB. Gonderiliyor...';
      });
    }

    return zipPath;
  }

  void _onIntervalChanged(double value) {
    final nextValue = value.round();
    if (nextValue == _captureIntervalMs) return;

    setState(() {
      _captureIntervalMs = nextValue;
    });

    if (_isRecording) {
      _startCaptureTimer();
      setState(() {
        _status =
            'Kayit devam ediyor. Yeni FPS: ${_fpsLabel(_captureIntervalMs)}';
      });
    }
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
    // External storage kullan — root gerekmez, dosya yoneticisiyle gorulebilir
    Directory? baseDir;

    if (Platform.isAndroid) {
      // Android 11+ için kolay erisilebilir ve kullanicinin direk gorebilecegi klasor
      baseDir = Directory('/storage/emulated/0/Download/Multicam');
      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }

    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final String modePrefix = _sessionMode == 'Kalibrasyon'
        ? 'calib_'
        : _sessionMode == 'Kalibreli'
        ? 'rectify_'
        : _sessionMode == '3D Orbit Tarama'
        ? 'orbit_'
        : '';
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

    print('Oturum klasoru olusturuldu: ${sessionDir.path}');
    return sessionDir;
  }

  Future<void> _captureFramePair({
    required File csvFile,
    required Directory sessionDir,
  }) async {
    if (!_isRecording || _isCapturing || !_isReady) return;
    _isCapturing = true;

    // Track actual FPS
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

      // Capture from both cameras via native Camera2 API
      final result = await Camera2Bridge.captureDualFrame(
        cam1FullPath,
        cam2FullPath,
      );

      final cam1Saved = result['cam1Saved'] == true;
      final cam2Saved = result['cam2Saved'] == true;

      // Update displayed preview frames
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

      // Extract extra sensor/camera metadata
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
          '$frameNo,${now.toIso8601String()},${cam1Saved ? cam1Relative : ''},${cam2Saved ? cam2Relative : ''},$fotValue,${_fmt(_accX)},${_fmt(_accY)},${_fmt(_accZ)},${_fmt(_gyroX)},${_fmt(_gyroY)},${_fmt(_gyroZ)},${_fmt(_poseTx)},${_fmt(_poseTy)},${_fmt(_poseTz)},${_fmt(_poseQx)},${_fmt(_poseQy)},${_fmt(_poseQz)},${_fmt(_poseQw)},$fx,$fy,$cx,$cy,$k1,$k2,$p1,$p2,$k3,$lux,$kelvin,$expMs,$iso,"$planeInfo","$bboxInfo",$cam1Id,$cam2Id,$captureMode\n';

      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (error) {
      final errorCommas = ',' * 33; // Fill the rest of the columns
      final line =
          '${_frameIndex - 1},${DateTime.now().toUtc().toIso8601String()},,,ERROR:$error$errorCommas\n';
      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
    } finally {
      _isCapturing = false;
    }
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
                _isRecording ? 'Yakalaniyor...' : 'Bekleniyor',
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
          gaplessPlayback: true, // Prevents flickering between frames
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

  void _startStatsPolling() {
    // Initial read to warm up CPU delta
    _systemStatsChannel.invokeMethod('getSystemStats').catchError((_) {});

    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollSystemStats(),
    );
  }

  Future<void> _pollSystemStats() async {
    try {
      final stats = await _systemStatsChannel.invokeMethod('getSystemStats');
      if (stats is Map && mounted) {
        setState(() {
          _cpuPercent = (stats['cpuPercent'] as num?)?.toDouble() ?? 0;
          _totalRamMB = (stats['totalRamMB'] as num?)?.toDouble() ?? 0;
          _usedRamMB = (stats['usedRamMB'] as num?)?.toDouble() ?? 0;
          _appHeapMB = (stats['appHeapMB'] as num?)?.toDouble() ?? 0;
          _appNativeMB = (stats['appNativeMB'] as num?)?.toDouble() ?? 0;
        });
      }
    } catch (_) {
      // silently ignore stats errors
    }
  }

  Widget _buildStatsBar() {
    final ramPercent = _totalRamMB > 0 ? (_usedRamMB / _totalRamMB * 100) : 0.0;
    final fpsText = _actualFps > 0 ? _actualFps.toStringAsFixed(1) : '-';
    final appMem = (_appHeapMB + _appNativeMB);

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
            _actualFps > 0 && _actualFps < 1.0
                ? Colors.red
                : Colors.greenAccent,
          ),
          const SizedBox(width: 12),
          _statChip(
            Icons.memory,
            'CPU',
            '${_cpuPercent.toStringAsFixed(1)}%',
            _cpuPercent > 80
                ? Colors.red
                : _cpuPercent > 50
                ? Colors.orange
                : Colors.greenAccent,
          ),
          const SizedBox(width: 12),
          _statChip(
            Icons.storage,
            'RAM',
            '${_usedRamMB.toStringAsFixed(0)}/${_totalRamMB.toStringAsFixed(0)} MB (${ramPercent.toStringAsFixed(0)}%)',
            ramPercent > 85
                ? Colors.red
                : ramPercent > 70
                ? Colors.orange
                : Colors.greenAccent,
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

  Widget _buildModeDropdown() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Çekim Modu:',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _sessionMode,
            dropdownColor: Colors.grey.shade800,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontWeight: FontWeight.bold,
            ),
            items: ['Normal', 'Kalibrasyon', 'Kalibreli', '3D Orbit Tarama']
                .map((mode) => DropdownMenuItem(value: mode, child: Text(mode)))
                .toList(),
            onChanged: _isRecording
                ? null
                : (val) {
                    if (val != null) {
                      setState(() {
                        _sessionMode = val;
                      });
                    }
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildViewModeSelector() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Görüntü Modu:',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _viewMode,
            dropdownColor: Colors.grey.shade800,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontWeight: FontWeight.bold,
            ),
            items: ['Çift Kamera', 'Tek Kamera (Kam 1)', 'Tek Kamera (Kam 2)']
                .map((mode) => DropdownMenuItem(value: mode, child: Text(mode)))
                .toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _viewMode = val;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCameraDropdowns() {
    if (_availableBackCameraIds.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildDropdown('Kamera 1:', _cam1Id, (val) {
            if (val != null && val != _cam1Id && _cam2Id != null) {
              _openSelectedCameras(val, _cam2Id!);
            }
          }),
          _buildDropdown('Kamera 2:', _cam2Id, (val) {
            if (val != null && val != _cam2Id && _cam1Id != null) {
              _openSelectedCameras(_cam1Id!, val);
            }
          }),
        ],
      ),
    );
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

    return Row(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(4),
          ),
          child: DropdownButton<String>(
            value: effectiveValue,
            dropdownColor: Colors.grey.shade800,
            style: const TextStyle(color: Colors.white),
            underline: const SizedBox.shrink(),
            onChanged: _isRecording ? null : onChanged,
            items: _availableBackCameraIds.map((id) {
              return DropdownMenuItem(value: id, child: Text('Kamera $id'));
            }).toList(),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multicam Capture')),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                if (_viewMode == 'Çift Kamera' ||
                    _viewMode == 'Tek Kamera (Kam 1)')
                  Expanded(
                    child: _buildPreview(
                      _lastCam1Frame,
                      _cam1FrameKey,
                      'Arka Kamera 1',
                    ),
                  ),
                if (_viewMode == 'Çift Kamera' ||
                    _viewMode == 'Tek Kamera (Kam 2)')
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
          _buildStatsBar(),
          Expanded(
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildModeDropdown(),
                    _buildViewModeSelector(),
                    _buildCameraDropdowns(),
                    Text(_status, style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 6),
                    Text(
                      _camera2Status,
                      style: const TextStyle(color: Colors.lightBlueAccent),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'FoT/proximity (cm): ${_fotCm?.toStringAsFixed(2) ?? '-'}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Acc (m/s2): ${_fmt(_accX, digits: 3)}, ${_fmt(_accY, digits: 3)}, ${_fmt(_accZ, digits: 3)}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Gyro (rad/s): ${_fmt(_gyroX, digits: 3)}, ${_fmt(_gyroY, digits: 3)}, ${_fmt(_gyroZ, digits: 3)}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Yakala araligi: $_captureIntervalMs ms (${_fpsLabel(_captureIntervalMs)} FPS)',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: _captureIntervalMs.toDouble(),
                      min: 20,
                      max: 2000,
                      divisions: 18,
                      label: '$_captureIntervalMs ms',
                      onChanged: _onIntervalChanged,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _ipController,
                      style: const TextStyle(color: Colors.black),
                      decoration: InputDecoration(
                        labelText: 'Hedef Bilgisayar IP (Ayni Wifi)',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.0),
                        ),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _isReady ? _toggleRecording : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: _isRecording
                              ? Colors.red.shade700
                              : Colors.green.shade700,
                        ),
                        child: Text(
                          _isRecording ? 'Kaydi Durdur' : 'Kaydi Baslat',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
