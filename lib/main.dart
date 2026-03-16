import 'dart:async';
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

  StreamSubscription<dynamic>? _fotSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  Timer? _captureTimer;

  bool _isReady = false;
  bool _isRecording = false;
  bool _isCapturing = false;

  String _status = 'Kameralar hazirlaniyor...';
  String _camera2Status = 'Camera2 raporu hazirlaniyor...';
  double? _fotCm;
  String? _sessionPath;
  int _frameIndex = 0;
  int _captureIntervalMs = 700;
  final TextEditingController _ipController = TextEditingController(
    text: '192.168.1.',
  );

  double? _accX;
  double? _accY;
  double? _accZ;
  double? _gyroX;
  double? _gyroY;
  double? _gyroZ;

  File? _activeCsvFile;
  Directory? _activeSessionDir;

  // Native dual camera state
  String? _cam1Id;
  String? _cam2Id;
  File? _lastCam1Frame;
  File? _lastCam2Frame;
  int _cam1FrameKey = 0;
  int _cam2FrameKey = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
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

      await _initDualCameras();

      _startFotStream();
      _startImuStreams();
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

      _cam1Id = pairResult['cam1Id'] as String;
      _cam2Id = pairResult['cam2Id'] as String;
      final logicalId = pairResult['logicalId'];

      if (!mounted) return;
      setState(() {
        _camera2Status +=
            ' | Mod: $mode | Pair: $_cam1Id + $_cam2Id${logicalId != null ? ' (logical=$logicalId)' : ''}';
        _status = 'Kameralar aciliyor ($_cam1Id, $_cam2Id)...';
      });

      // Step 3: Open cameras via native Camera2 API
      final openResult = await Camera2Bridge.openDualCameras(
        _cam1Id!,
        _cam2Id!,
      );
      final success = openResult['success'] == true;
      final openMode = openResult['mode'] ?? mode;

      if (!mounted) return;

      if (success) {
        final modeLabel = openMode == 'logical_multi_camera'
            ? 'Logical Multi-Camera ✓'
            : openMode == 'alternating'
            ? 'Alternating (sirkali cekim) ✓'
            : '$openMode ✓';
        setState(() {
          _isReady = true;
          _status = 'Hazir! $_cam1Id + $_cam2Id ($modeLabel). Kaydi baslat.';
          _camera2Status += ' | $modeLabel';
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
        _status = 'Dual kamera baslatma hatasi: $e';
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
        _status = 'Kayit durduruldu. ZIP olusturuluyor...';
      });

      if (sessionDir != null) {
        try {
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
      'frame,timestamp_utc,cam1_image,cam2_image,fot_cm,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z\n',
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
      final fileName = file.uri.pathSegments.last;

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final url = Uri.parse('http://$ip:5000/upload?file=$fileName');
      final request = await client.postUrl(url);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/zip');
      request.contentLength = await file.length();

      await request.addStream(file.openRead());
      final response = await request.close();

      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          _status = 'ZIP Bilgisayara BASARIYLA GONDERILDI! ($fileName)';
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
    final zipPath = '${sessionDir.path}.zip';
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    await for (final entity in sessionDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        final relativePath = entity.path
            .substring(sessionDir.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        encoder.addFile(entity, relativePath);
      }
    }

    encoder.close();
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
    final docDir = await getApplicationDocumentsDirectory();
    final sessionId = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final sessionDir = Directory(
      '${docDir.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}$sessionId',
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
      final line =
          '$frameNo,${now.toIso8601String()},${cam1Saved ? cam1Relative : ''},${cam2Saved ? cam2Relative : ''},$fotValue,${_fmt(_accX)},${_fmt(_accY)},${_fmt(_accZ)},${_fmt(_gyroX)},${_fmt(_gyroY)},${_fmt(_gyroZ)}\n';

      await csvFile.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (error) {
      final line =
          '${_frameIndex - 1},${DateTime.now().toUtc().toIso8601String()},,,ERROR:$error,,,,,,\n';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multicam Capture (S23)')),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _buildPreview(
                    _lastCam1Frame,
                    _cam1FrameKey,
                    'Arka Kamera 1',
                  ),
                ),
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
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  min: 200,
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
                    child: Text(_isRecording ? 'Kaydi Durdur' : 'Kaydi Baslat'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
