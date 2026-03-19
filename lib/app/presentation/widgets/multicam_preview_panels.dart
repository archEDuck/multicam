import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class CameraPreviewPanel extends StatelessWidget {
  const CameraPreviewPanel({
    super.key,
    required this.previewBytes,
    required this.lastFrame,
    required this.label,
    required this.isRecording,
    required this.isReady,
    required this.showCheckerboardOverlay,
    required this.checkerCorners,
    required this.checkerFound,
  });

  final Uint8List? previewBytes;
  final File? lastFrame;
  final String label;
  final bool isRecording;
  final bool isReady;
  final bool showCheckerboardOverlay;
  final List<Offset> checkerCorners;
  final bool checkerFound;

  @override
  Widget build(BuildContext context) {
    final hasPreviewBytes = previewBytes != null && previewBytes!.isNotEmpty;
    final hasLastFrame = lastFrame != null && lastFrame!.existsSync();

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
                  isRecording
                      ? 'Yakala...'
                      : isReady
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
            previewBytes!,
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
        if (showCheckerboardOverlay)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: CheckerboardOverlayPainter(
                  checkerCorners: checkerCorners,
                  checkerFound: checkerFound,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class DepthPreviewPanel extends StatelessWidget {
  const DepthPreviewPanel({super.key, required this.depthBytes});

  final Uint8List? depthBytes;

  @override
  Widget build(BuildContext context) {
    final hasDepth = depthBytes != null && depthBytes!.isNotEmpty;

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasDepth)
            Image.memory(
              depthBytes!,
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
}

class CheckerboardOverlayPainter extends CustomPainter {
  const CheckerboardOverlayPainter({
    required this.checkerCorners,
    required this.checkerFound,
  });

  final List<Offset> checkerCorners;
  final bool checkerFound;

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
  bool shouldRepaint(covariant CheckerboardOverlayPainter oldDelegate) {
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
