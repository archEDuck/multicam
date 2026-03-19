import 'package:flutter/material.dart';

import '../controllers/sam2_segmentation_state.dart';

class Sam2ControlPanel extends StatelessWidget {
  const Sam2ControlPanel({
    super.key,
    required this.state,
    required this.onTargetChanged,
    required this.onRunPressed,
    required this.onSavePressed,
    required this.onClearPressed,
    required this.onRemoveLastPointPressed,
    required this.canSaveOutput,
  });

  final Sam2SegmentationState state;
  final ValueChanged<Sam2PreviewTarget> onTargetChanged;
  final VoidCallback onRunPressed;
  final VoidCallback onSavePressed;
  final VoidCallback onClearPressed;
  final VoidCallback onRemoveLastPointPressed;
  final bool canSaveOutput;

  @override
  Widget build(BuildContext context) {
    final availabilityColor = state.availability.isReady
        ? Colors.lightGreenAccent
        : Colors.orangeAccent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SAM2: ${state.availability.isReady ? 'Hazır' : 'Hazır Değil'}',
          style: TextStyle(color: availabilityColor),
        ),
        const SizedBox(height: 4),
        Text(
          state.statusMessage,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        if (state.availability.modelDirectory.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Model dizini: ${state.availability.modelDirectory}',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Kaynak:', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            DropdownButton<Sam2PreviewTarget>(
              value: state.target,
              dropdownColor: Colors.grey.shade800,
              style: const TextStyle(color: Colors.white),
              onChanged: (value) {
                if (value != null) {
                  onTargetChanged(value);
                }
              },
              items: const [
                DropdownMenuItem(
                  value: Sam2PreviewTarget.camera1,
                  child: Text('Kamera 1'),
                ),
                DropdownMenuItem(
                  value: Sam2PreviewTarget.camera2,
                  child: Text('Kamera 2'),
                ),
              ],
            ),
            const Spacer(),
            Text(
              'Prompt: ${state.points.length}',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
        if (state.score > 0 || state.coverageRatio > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Skor: ${state.score.toStringAsFixed(3)} | Maske: ${(state.coverageRatio * 100).toStringAsFixed(1)}%',
              style: const TextStyle(color: Colors.lightBlueAccent),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: state.isSegmenting || !state.availability.isReady
                  ? null
                  : onRunPressed,
              icon: state.isSegmenting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_fix_high),
              label: Text(
                state.isSegmenting ? 'Çalışıyor...' : 'SAM2 Segment Et',
              ),
            ),
            OutlinedButton.icon(
              onPressed: state.points.isEmpty ? null : onRemoveLastPointPressed,
              icon: const Icon(Icons.undo),
              label: const Text('Son Noktayı Sil'),
            ),
            OutlinedButton.icon(
              onPressed: canSaveOutput ? onSavePressed : null,
              icon: const Icon(Icons.save_alt),
              label: const Text('Maskeyi Kaydet'),
            ),
            OutlinedButton.icon(
              onPressed: (!state.hasOverlay && state.points.isEmpty)
                  ? null
                  : onClearPressed,
              icon: const Icon(Icons.layers_clear),
              label: const Text('Temizle'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Dokun: pozitif nokta, uzun bas: negatif nokta.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}
