import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:multicam/app/application/usecases/calibrate_stereo_session_use_case.dart';
import 'package:multicam/app/infrastructure/repositories/method_channel_stereo_preprocess_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('multicam/stereo_preprocess');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'calibrateSession') {
        final rawArgs = call.arguments;
        if (rawArgs is! Map) {
          return {
            'success': false,
            'message': 'Argüman bulunamadı (mock).',
            'processedPairs': 0,
            'outputPath': '',
          };
        }

        final sessionDir = (rawArgs['sessionDir'] ?? '').toString();
        return _simulateStereoCalibrationFromSession(sessionDir);
      }

      return {
        'success': false,
        'message': 'Mock handler bu methodu desteklemiyor: ${call.method}',
        'processedPairs': 0,
        'outputPath': '',
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'Sentetik checkerboard çiftleri ile kalibrasyon başarılı olur',
    () async {
      final sessionDir = await _buildSyntheticSession(
        pairCount: 8,
        cam1HasCheckerboard: true,
        cam2HasCheckerboard: true,
      );
      addTearDown(() => sessionDir.delete(recursive: true));

      final repository = MethodChannelStereoPreprocessRepository(
        channel: channel,
      );
      final useCase = CalibrateStereoSessionUseCase(repository);

      final result = await useCase(sessionDir.path);

      expect(result.success, isTrue);
      expect(result.processedPairs, 8);
      expect(result.message, contains('Kalibrasyon tamamlandı'));
      expect(File(result.outputPath).existsSync(), isTrue);
    },
  );

  test(
    'İkinci kamerada checkerboard yoksa kalibrasyon başarısız olur',
    () async {
      final sessionDir = await _buildSyntheticSession(
        pairCount: 8,
        cam1HasCheckerboard: true,
        cam2HasCheckerboard: false,
      );
      addTearDown(() => sessionDir.delete(recursive: true));

      final repository = MethodChannelStereoPreprocessRepository(
        channel: channel,
      );
      final useCase = CalibrateStereoSessionUseCase(repository);

      final result = await useCase(sessionDir.path);

      expect(result.success, isFalse);
      expect(result.processedPairs, 0);
      expect(result.message, contains('Yeterli checkerboard çifti'));
    },
  );
}

Future<Directory> _buildSyntheticSession({
  required int pairCount,
  required bool cam1HasCheckerboard,
  required bool cam2HasCheckerboard,
}) async {
  final root = await Directory.systemTemp.createTemp('multicam_calib_test_');
  final cam1Dir = Directory('${root.path}${Platform.pathSeparator}cam1')
    ..createSync(recursive: true);
  final cam2Dir = Directory('${root.path}${Platform.pathSeparator}cam2')
    ..createSync(recursive: true);

  for (var index = 0; index < pairCount; index++) {
    final cam1File = File(
      '${cam1Dir.path}${Platform.pathSeparator}frame_$index.jpg',
    );
    final cam2File = File(
      '${cam2Dir.path}${Platform.pathSeparator}frame_$index.jpg',
    );

    _writeSyntheticCheckerboardImage(
      outFile: cam1File,
      includeCheckerboard: cam1HasCheckerboard,
      offsetX: 72 + (index * 7),
      offsetY: 58 + (index * 4),
      squareSize: 28 + (index % 3),
    );

    _writeSyntheticCheckerboardImage(
      outFile: cam2File,
      includeCheckerboard: cam2HasCheckerboard,
      offsetX: 114 + (index * 5),
      offsetY: 76 + (index * 3),
      squareSize: 30 + (index % 2),
    );
  }

  return root;
}

Map<String, dynamic> _simulateStereoCalibrationFromSession(
  String sessionDirPath,
) {
  if (sessionDirPath.trim().isEmpty) {
    return {
      'success': false,
      'message': 'sessionDir boş (mock).',
      'processedPairs': 0,
      'outputPath': '',
    };
  }

  final cam1Dir = Directory('$sessionDirPath${Platform.pathSeparator}cam1');
  final cam2Dir = Directory('$sessionDirPath${Platform.pathSeparator}cam2');

  if (!cam1Dir.existsSync() || !cam2Dir.existsSync()) {
    return {
      'success': false,
      'message': 'cam1/cam2 klasörü bulunamadı (mock).',
      'processedPairs': 0,
      'outputPath': '',
    };
  }

  final cam1Images = _sortedImageFiles(cam1Dir);
  final cam2Images = _sortedImageFiles(cam2Dir);
  final pairCount = math.min(cam1Images.length, cam2Images.length);

  var validPairs = 0;
  for (var i = 0; i < pairCount; i++) {
    final found1 = _looksLikeCheckerboard(cam1Images[i]);
    final found2 = _looksLikeCheckerboard(cam2Images[i]);
    if (found1 && found2) {
      validPairs += 1;
    }
  }

  if (validPairs < 5) {
    return {
      'success': false,
      'message': 'Yeterli checkerboard çifti bulunamadı (mock).',
      'processedPairs': validPairs,
      'outputPath': '',
    };
  }

  final outputPath =
      '$sessionDirPath${Platform.pathSeparator}mock_stereo_calibration.json';
  File(outputPath).writeAsStringSync(
    '{"validPairs":$validPairs,"source":"dart_test_mock"}',
    flush: true,
  );

  return {
    'success': true,
    'message': 'Kalibrasyon tamamlandı (mock).',
    'processedPairs': validPairs,
    'outputPath': outputPath,
  };
}

List<File> _sortedImageFiles(Directory dir) {
  return dir.listSync().whereType<File>().where((file) {
    final ext = file.path.toLowerCase();
    return ext.endsWith('.jpg') ||
        ext.endsWith('.jpeg') ||
        ext.endsWith('.png');
  }).toList()..sort((a, b) => a.path.compareTo(b.path));
}

void _writeSyntheticCheckerboardImage({
  required File outFile,
  required bool includeCheckerboard,
  required int offsetX,
  required int offsetY,
  required int squareSize,
}) {
  final canvas = img.Image(width: 640, height: 480);
  img.fill(canvas, color: img.ColorRgb8(128, 128, 128));

  if (includeCheckerboard) {
    const squaresPerSide = 8;

    for (var row = 0; row < squaresPerSide; row++) {
      for (var col = 0; col < squaresPerSide; col++) {
        final isWhite = (row + col).isEven;
        final shade = isWhite ? 240 : 18;

        final x1 = offsetX + (col * squareSize);
        final y1 = offsetY + (row * squareSize);
        final x2 = x1 + squareSize - 1;
        final y2 = y1 + squareSize - 1;

        img.fillRect(
          canvas,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: img.ColorRgb8(shade, shade, shade),
        );
      }
    }
  }

  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(img.encodeJpg(canvas, quality: 94), flush: true);
}

bool _looksLikeCheckerboard(File imageFile) {
  final bytes = imageFile.readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return false;
  }

  final bounds = _findBoardBounds(decoded);
  if (bounds == null || bounds.width < 40 || bounds.height < 40) {
    return false;
  }

  final matchA = _matchAlternatingGrid(
    decoded,
    bounds,
    whiteStartsTopLeft: true,
  );
  final matchB = _matchAlternatingGrid(
    decoded,
    bounds,
    whiteStartsTopLeft: false,
  );

  return math.max(matchA, matchB) >= 54;
}

int _matchAlternatingGrid(
  img.Image image,
  _IntRect bounds, {
  required bool whiteStartsTopLeft,
}) {
  const cells = 8;
  var score = 0;

  for (var row = 0; row < cells; row++) {
    for (var col = 0; col < cells; col++) {
      final sampleX =
          bounds.left + ((col + 0.5) * bounds.width / cells).floor();
      final sampleY =
          bounds.top + ((row + 0.5) * bounds.height / cells).floor();

      final clampedX = sampleX.clamp(0, image.width - 1);
      final clampedY = sampleY.clamp(0, image.height - 1);
      final p = image.getPixel(clampedX, clampedY);
      final luminance = ((p.r + p.g + p.b) / 3).toDouble();

      final expectsWhite = (((row + col).isEven) == whiteStartsTopLeft);
      final matchesCell = expectsWhite ? luminance > 170 : luminance < 95;
      if (matchesCell) {
        score += 1;
      }
    }
  }

  return score;
}

_IntRect? _findBoardBounds(img.Image image) {
  final cornerAverage =
      ((image.getPixel(0, 0).r +
                  image.getPixel(image.width - 1, 0).r +
                  image.getPixel(0, image.height - 1).r +
                  image.getPixel(image.width - 1, image.height - 1).r) /
              4)
          .toDouble();

  const threshold = 32.0;

  var minX = image.width;
  var minY = image.height;
  var maxX = -1;
  var maxY = -1;

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      final luminance = ((p.r + p.g + p.b) / 3).toDouble();
      if ((luminance - cornerAverage).abs() > threshold) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }

  if (maxX <= minX || maxY <= minY) {
    return null;
  }

  return _IntRect(left: minX, top: minY, right: maxX, bottom: maxY);
}

class _IntRect {
  final int left;
  final int top;
  final int right;
  final int bottom;

  const _IntRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  int get width => right - left + 1;

  int get height => bottom - top + 1;
}
