import 'package:flutter/material.dart';

import '../../domain/entities/app_settings.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.isRecording,
    required this.ipController,
    required this.onSessionModeChanged,
    required this.onViewModeChanged,
    required this.onIntervalChanged,
    required this.onToggleAutoZip,
    required this.onToggleAutoUpload,
    required this.onToggleStats,
    required this.onToggleImu,
    required this.onToggleFot,
    required this.onToggleAutoSelectPair,
    required this.onIpChanged,
  });

  final AppSettings settings;
  final bool isRecording;
  final TextEditingController ipController;
  final ValueChanged<String> onSessionModeChanged;
  final ValueChanged<String> onViewModeChanged;
  final ValueChanged<double> onIntervalChanged;
  final ValueChanged<bool> onToggleAutoZip;
  final ValueChanged<bool> onToggleAutoUpload;
  final ValueChanged<bool> onToggleStats;
  final ValueChanged<bool> onToggleImu;
  final ValueChanged<bool> onToggleFot;
  final ValueChanged<bool> onToggleAutoSelectPair;
  final ValueChanged<String> onIpChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildModeDropdown(),
        _buildViewModeSelector(),
        _buildIntervalSlider(),
        const SizedBox(height: 12),
        _buildToggles(),
        const SizedBox(height: 12),
        TextField(
          controller: ipController,
          style: const TextStyle(color: Colors.black),
          decoration: InputDecoration(
            labelText: 'Hedef Bilgisayar IP (Ayni Wifi)',
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.0),
            ),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: onIpChanged,
        ),
      ],
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
            value: settings.effectiveSessionMode,
            dropdownColor: Colors.grey.shade800,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontWeight: FontWeight.bold,
            ),
            items: AppSettings.sessionModes
                .map((mode) => DropdownMenuItem(value: mode, child: Text(mode)))
                .toList(),
            onChanged: isRecording
                ? null
                : (val) {
                    if (val != null) onSessionModeChanged(val);
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
            value: settings.effectiveViewMode,
            dropdownColor: Colors.grey.shade800,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontWeight: FontWeight.bold,
            ),
            items: AppSettings.viewModes
                .map((mode) => DropdownMenuItem(value: mode, child: Text(mode)))
                .toList(),
            onChanged: (val) {
              if (val != null) onViewModeChanged(val);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildIntervalSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Yakala araligi: ${settings.effectiveCaptureIntervalMs} ms (${(1000 / settings.effectiveCaptureIntervalMs).toStringAsFixed(2)} FPS)',
          style: const TextStyle(color: Colors.white),
        ),
        Slider(
          value: settings.effectiveCaptureIntervalMs.toDouble(),
          min: 20,
          max: 2000,
          divisions: 18,
          label: '${settings.effectiveCaptureIntervalMs} ms',
          onChanged: onIntervalChanged,
        ),
      ],
    );
  }

  Widget _buildToggles() {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        _toggle('Auto ZIP', settings.effectiveAutoZipOnStop, onToggleAutoZip),
        _toggle(
          'Auto Upload',
          settings.effectiveAutoUploadOnStop,
          onToggleAutoUpload,
        ),
        _toggle('Stats', settings.effectiveEnableStats, onToggleStats),
        _toggle('IMU', settings.effectiveEnableImu, onToggleImu),
        _toggle('FoT', settings.effectiveEnableFot, onToggleFot),
        _toggle(
          'Auto Pair',
          settings.effectiveAutoSelectCameraPair,
          onToggleAutoSelectPair,
        ),
      ],
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      selected: value,
      label: Text(label),
      labelStyle: TextStyle(color: value ? Colors.black : Colors.white),
      selectedColor: Colors.lightBlueAccent,
      backgroundColor: Colors.white24,
      onSelected: onChanged,
    );
  }
}
