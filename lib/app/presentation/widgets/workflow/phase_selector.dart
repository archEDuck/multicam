import 'package:flutter/material.dart';

import '../../../domain/entities/capture_workflow_phase.dart';

class WorkflowPhaseSelector extends StatelessWidget {
  const WorkflowPhaseSelector({
    super.key,
    required this.selectedPhase,
    required this.onPhaseSelected,
    this.enabled = true,
  });

  final CaptureWorkflowPhase selectedPhase;
  final ValueChanged<CaptureWorkflowPhase> onPhaseSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final phases = CaptureWorkflowPhase.values;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: phases.map((phase) {
        final isSelected = selectedPhase == phase;

        return ChoiceChip(
          selected: isSelected,
          label: Text('${phase.shortLabel} • ${phase.title}'),
          onSelected: enabled
              ? (_) {
                  onPhaseSelected(phase);
                }
              : null,
        );
      }).toList(),
    );
  }
}
