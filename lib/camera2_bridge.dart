import 'package:flutter/services.dart';

class Camera2Bridge {
  static const MethodChannel _channel = MethodChannel(
    'multicam/camera2_bridge',
  );
  static const MethodChannel _dualChannel = MethodChannel(
    'multicam/dual_camera',
  );

  /// Gets back camera report (IDs, concurrent pairs, capabilities).
  static Future<Map<String, dynamic>> getBackCameraReport() async {
    final dynamic raw = await _channel.invokeMethod('getBackCameraReport');
    return _asStringKeyedMap(raw);
  }

  /// Finds the best concurrent back camera pair for this device.
  /// Returns {found: true, cam1Id: '...', cam2Id: '...'} or {found: false}.
  static Future<Map<String, dynamic>> findBestPair() async {
    final dynamic raw = await _dualChannel.invokeMethod('findBestPair');
    return _asStringKeyedMap(raw);
  }

  /// Opens two back cameras concurrently using native Camera2 API.
  /// Returns {success: true/false, error?: '...'}.
  static Future<Map<String, dynamic>> openDualCameras(
    String cam1Id,
    String cam2Id,
  ) async {
    final dynamic raw = await _dualChannel.invokeMethod('openDualCameras', {
      'cam1Id': cam1Id,
      'cam2Id': cam2Id,
    });
    return _asStringKeyedMap(raw);
  }

  /// Captures a frame from both cameras and saves as JPEG.
  /// Returns {success: true/false, cam1Saved: true/false, cam2Saved: true/false}.
  static Future<Map<String, dynamic>> captureDualFrame(
    String cam1Path,
    String cam2Path,
  ) async {
    final dynamic raw = await _dualChannel.invokeMethod('captureDualFrame', {
      'cam1Path': cam1Path,
      'cam2Path': cam2Path,
    });
    return _asStringKeyedMap(raw);
  }

  /// Closes both camera sessions and releases resources.
  static Future<void> closeDualCameras() async {
    await _dualChannel.invokeMethod('closeDualCameras');
  }

  /// Returns current dual camera status.
  static Future<Map<String, dynamic>> getCameraStatus() async {
    final dynamic raw = await _dualChannel.invokeMethod('getCameraStatus');
    return _asStringKeyedMap(raw);
  }

  static Map<String, dynamic> _asStringKeyedMap(dynamic input) {
    if (input is Map) {
      return input.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }
}
