import 'package:flutter/material.dart';

import '../../../domain/entities/app_settings.dart';
import '../../../domain/entities/camera_option.dart';

class CameraSelectionPhasePanel extends StatelessWidget {
  const CameraSelectionPhasePanel({
    super.key,
    required this.availableBackCameraIds,
    required this.cameraOptionsById,
    required this.cam1Id,
    required this.cam2Id,
    required this.isRecording,
    required this.isReady,
    required this.settings,
    required this.onCam1Changed,
    required this.onCam2Changed,
    required this.onViewModeChanged,
    required this.onIntervalChanged,
    required this.onToggleStats,
    required this.onToggleImu,
    required this.onToggleFot,
    required this.onGoCalibration,
  });

  final List<String> availableBackCameraIds;
  final Map<String, CameraOption> cameraOptionsById;
  final String? cam1Id;
  final String? cam2Id;
  final bool isRecording;
  final bool isReady;
  final AppSettings settings;
  final ValueChanged<String?> onCam1Changed;
  final ValueChanged<String?> onCam2Changed;
  final ValueChanged<String> onViewModeChanged;
  final ValueChanged<double> onIntervalChanged;
  final ValueChanged<bool> onToggleStats;
  final ValueChanged<bool> onToggleImu;
  final ValueChanged<bool> onToggleFot;
  final VoidCallback onGoCalibration;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (availableBackCameraIds.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: _CameraSelectorField(
                  label: 'Kamera 1',
                  value: cam1Id,
                  availableBackCameraIds: availableBackCameraIds,
                  cameraOptionsById: cameraOptionsById,
                  onChanged: isRecording ? null : onCam1Changed,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CameraSelectorField(
                  label: 'Kamera 2',
                  value: cam2Id,
                  availableBackCameraIds: availableBackCameraIds,
                  cameraOptionsById: cameraOptionsById,
                  onChanged: isRecording ? null : onCam2Changed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _SelectedCameraInfo(
            cam1: cam1Id == null ? null : cameraOptionsById[cam1Id!],
            cam2: cam2Id == null ? null : cameraOptionsById[cam2Id!],
          ),
          const SizedBox(height: 8),
        ],
        const Text(
          'Faz 2’de checkerboard her tespit edildiğinde açı otomatik kaydedilir.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: isReady ? onGoCalibration : null,
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
                value: settings.effectiveViewMode,
                isExpanded: true,
                dropdownColor: Colors.grey.shade800,
                style: const TextStyle(color: Colors.white),
                onChanged: (value) {
                  if (value == null) return;
                  onViewModeChanged(value);
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
                value: settings.effectiveCaptureIntervalMs.toDouble(),
                min: 20,
                max: 2000,
                divisions: 18,
                label: '${settings.effectiveCaptureIntervalMs} ms',
                onChanged: onIntervalChanged,
              ),
            ),
            Text(
              '${settings.effectiveCaptureIntervalMs}ms',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              selected: settings.effectiveEnableStats,
              label: const Text('Stats'),
              onSelected: onToggleStats,
            ),
            FilterChip(
              selected: settings.effectiveEnableImu,
              label: const Text('IMU'),
              onSelected: onToggleImu,
            ),
            FilterChip(
              selected: settings.effectiveEnableFot,
              label: const Text('FoT'),
              onSelected: onToggleFot,
            ),
          ],
        ),
      ],
    );
  }
}

class CalibrationPhasePanel extends StatelessWidget {
  const CalibrationPhasePanel({
    super.key,
    required this.capturedCalibrationPairs,
    required this.requiredCalibrationPairs,
    required this.minRequiredCalibrationPairs,
    required this.maxRequiredCalibrationPairs,
    required this.isStereoProcessing,
    required this.isCheckerboardDetecting,
    required this.isCalibrationCaptureRunning,
    required this.canUseCachedCalibration,
    required this.canRunCalibration,
    required this.hasCachedCalibration,
    required this.checkerboardStatus,
    required this.cachedCalibrationLabel,
    required this.sessionName,
    required this.onRequiredPairsChanged,
    required this.onToggleCapture,
    required this.onCheckCheckerboard,
    required this.onRunCalibration,
    required this.onUseCachedCalibration,
    required this.onBackToPhaseOne,
  });

  final int capturedCalibrationPairs;
  final int requiredCalibrationPairs;
  final int minRequiredCalibrationPairs;
  final int maxRequiredCalibrationPairs;
  final bool isStereoProcessing;
  final bool isCheckerboardDetecting;
  final bool isCalibrationCaptureRunning;
  final bool canUseCachedCalibration;
  final bool canRunCalibration;
  final bool hasCachedCalibration;
  final String checkerboardStatus;
  final String cachedCalibrationLabel;
  final String sessionName;
  final ValueChanged<double> onRequiredPairsChanged;
  final VoidCallback onToggleCapture;
  final VoidCallback onCheckCheckerboard;
  final VoidCallback onRunCalibration;
  final VoidCallback onUseCachedCalibration;
  final VoidCallback onBackToPhaseOne;

  @override
  Widget build(BuildContext context) {
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
          'Toplanan açı: $capturedCalibrationPairs/$requiredCalibrationPairs',
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
                value: requiredCalibrationPairs.toDouble(),
                min: minRequiredCalibrationPairs.toDouble(),
                max: maxRequiredCalibrationPairs.toDouble(),
                divisions:
                    maxRequiredCalibrationPairs - minRequiredCalibrationPairs,
                label: '$requiredCalibrationPairs',
                onChanged: isStereoProcessing || isCheckerboardDetecting
                    ? null
                    : onRequiredPairsChanged,
              ),
            ),
            Text(
              '$requiredCalibrationPairs',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          checkerboardStatus,
          style: TextStyle(
            color: checkerboardStatus.startsWith('✓')
                ? Colors.lightGreenAccent
                : Colors.orangeAccent,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          cachedCalibrationLabel,
          style: TextStyle(
            color: hasCachedCalibration
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
              onPressed: isStereoProcessing || isCheckerboardDetecting
                  ? null
                  : onToggleCapture,
              icon: Icon(
                isCalibrationCaptureRunning
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(
                isCalibrationCaptureRunning ? 'Çekimi Durdur' : 'Çekimi Başlat',
              ),
            ),
            OutlinedButton.icon(
              onPressed: isStereoProcessing || isCheckerboardDetecting
                  ? null
                  : onCheckCheckerboard,
              icon: const Icon(Icons.grid_4x4),
              label: const Text('Dama Tahtası Ara'),
            ),
            FilledButton.icon(
              onPressed: canRunCalibration ? onRunCalibration : null,
              icon: const Icon(Icons.tune),
              label: const Text('OpenCV Kalibrasyon'),
            ),
            OutlinedButton.icon(
              onPressed: canUseCachedCalibration
                  ? onUseCachedCalibration
                  : null,
              icon: const Icon(Icons.memory),
              label: const Text('Kayıtlı Kalibrasyon ile Faz 3'),
            ),
            OutlinedButton(
              onPressed: onBackToPhaseOne,
              child: const Text('Faz 1'),
            ),
          ],
        ),
      ],
    );
  }
}

class StereoMatchingPhasePanel extends StatelessWidget {
  const StereoMatchingPhasePanel({
    super.key,
    required this.isStereoProcessing,
    required this.showRectifiedPreview,
    required this.sessionName,
    required this.rectifiedOutputPath,
    required this.onToggleLiveRectify,
    required this.onBackToPhaseOne,
  });

  final bool isStereoProcessing;
  final bool showRectifiedPreview;
  final String sessionName;
  final String? rectifiedOutputPath;
  final VoidCallback onToggleLiveRectify;
  final VoidCallback onBackToPhaseOne;

  @override
  Widget build(BuildContext context) {
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
        if ((rectifiedOutputPath ?? '').isNotEmpty)
          Text(
            'Çıktı: $rectifiedOutputPath',
            style: const TextStyle(color: Colors.lightGreenAccent),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: isStereoProcessing ? null : onToggleLiveRectify,
                icon: Icon(
                  showRectifiedPreview
                      ? Icons.pause_circle_outline
                      : Icons.auto_fix_high,
                ),
                label: Text(
                  showRectifiedPreview
                      ? 'Canlı Rectify Durdur'
                      : 'Canlı Rectify Başlat',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: isStereoProcessing ? null : onBackToPhaseOne,
              child: const Text('Faz 1'),
            ),
          ],
        ),
      ],
    );
  }
}

class DepthMapPhasePanel extends StatelessWidget {
  const DepthMapPhasePanel({
    super.key,
    required this.isStereoProcessing,
    required this.showDepthPreview,
    required this.onToggleLiveDepth,
    required this.onBackToPhaseOne,
  });

  final bool isStereoProcessing;
  final bool showDepthPreview;
  final VoidCallback onToggleLiveDepth;
  final VoidCallback onBackToPhaseOne;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'AI stereo modeli ile canlı derinlik haritası üretilir.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 6),
        const Text(
          'Canlı derinlik her uygun preview karesinde çalışır.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        const Text(
          'Giriş modelin beklediği boyutta verilir, çıkış model çözünürlüğünde alınır.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: isStereoProcessing ? null : onToggleLiveDepth,
                icon: Icon(
                  showDepthPreview ? Icons.pause_circle_outline : Icons.blur_on,
                ),
                label: Text(
                  showDepthPreview
                      ? 'Canlı Derinlik Durdur'
                      : 'Canlı Derinlik Başlat',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: isStereoProcessing ? null : onBackToPhaseOne,
              child: const Text('Faz 1'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CameraSelectorField extends StatelessWidget {
  const _CameraSelectorField({
    required this.label,
    required this.value,
    required this.availableBackCameraIds,
    required this.cameraOptionsById,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> availableBackCameraIds;
  final Map<String, CameraOption> cameraOptionsById;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final effectiveValue =
        (value != null && availableBackCameraIds.contains(value))
        ? value
        : (availableBackCameraIds.isNotEmpty
              ? availableBackCameraIds.first
              : null);

    return DropdownButtonFormField<String>(
      initialValue: effectiveValue,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
        filled: true,
      ),
      isExpanded: true,
      onChanged: onChanged,
      items: availableBackCameraIds.map((id) {
        final option = cameraOptionsById[id];
        final text = option?.compactLabel ?? 'Back • id=$id';
        return DropdownMenuItem(
          value: id,
          child: Text(text, overflow: TextOverflow.ellipsis),
        );
      }).toList(),
    );
  }
}

class _SelectedCameraInfo extends StatelessWidget {
  const _SelectedCameraInfo({required this.cam1, required this.cam2});

  final CameraOption? cam1;
  final CameraOption? cam2;

  @override
  Widget build(BuildContext context) {
    if (cam1 == null && cam2 == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cam1 != null)
            Text(
              'Kamera 1: ${cam1!.compactLabel}',
              style: theme.textTheme.bodySmall,
            ),
          if (cam2 != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Kamera 2: ${cam2!.compactLabel}',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
