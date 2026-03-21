import '../../domain/entities/capture_workflow_phase.dart';

enum PhaseTransitionIntent {
  manual,
  calibrationCompleted,
  cachedCalibrationShortcut,
}

class PhaseTransitionPlan {
  const PhaseTransitionPlan({
    required this.allowed,
    this.blockMessage,
    this.statusMessage,
    this.stereoStatusMessage,
    this.clearStereoStatus = false,
  });

  final bool allowed;
  final String? blockMessage;
  final String? statusMessage;
  final String? stereoStatusMessage;
  final bool clearStereoStatus;
}

class WorkflowPhaseTransitionController {
  const WorkflowPhaseTransitionController();

  PhaseTransitionPlan plan({
    required CaptureWorkflowPhase currentPhase,
    required CaptureWorkflowPhase nextPhase,
    required bool isStereoProcessing,
    required bool isOpeningCameras,
    required bool isReady,
    required bool hasCachedCalibration,
    PhaseTransitionIntent intent = PhaseTransitionIntent.manual,
  }) {
    if (currentPhase == nextPhase) {
      return const PhaseTransitionPlan(allowed: true);
    }

    if (isStereoProcessing || isOpeningCameras) {
      return const PhaseTransitionPlan(
        allowed: false,
        blockMessage:
            'Aktif işlem sürerken faz değiştirilemez. İşlem bitince tekrar deneyin.',
      );
    }

    if (nextPhase == CaptureWorkflowPhase.calibration && !isReady) {
      return const PhaseTransitionPlan(
        allowed: false,
        blockMessage:
            'Kameralar hazır değil. Önce Faz 1’de kamera çiftini açın.',
      );
    }

    if (nextPhase == CaptureWorkflowPhase.stereoMatching &&
        !hasCachedCalibration) {
      return const PhaseTransitionPlan(
        allowed: false,
        blockMessage: 'Bu faz için önce Faz 2 kalibrasyonunu tamamlamalısınız.',
      );
    }

    switch (nextPhase) {
      case CaptureWorkflowPhase.cameraSelection:
        return const PhaseTransitionPlan(
          allowed: true,
          statusMessage:
              'Faz 1 hazır. Kamera çiftini seçip iş akışını başlatabilirsiniz.',
          clearStereoStatus: true,
        );
      case CaptureWorkflowPhase.calibration:
        return const PhaseTransitionPlan(
          allowed: true,
          statusMessage:
              'Faz 2 hazır. Checkerboard ile çekimi başlatabilirsiniz.',
          clearStereoStatus: true,
        );
      case CaptureWorkflowPhase.stereoMatching:
        if (intent == PhaseTransitionIntent.cachedCalibrationShortcut) {
          return const PhaseTransitionPlan(
            allowed: true,
            statusMessage:
                'Kayıtlı kalibrasyon ile Faz 3 açıldı. Checkerboard çekimine gerek yok.',
            stereoStatusMessage:
                'Kayıtlı kalibrasyon hazır. Faz 3’te canlı rectify başlatabilirsiniz.',
          );
        }

        if (intent == PhaseTransitionIntent.calibrationCompleted) {
          return const PhaseTransitionPlan(
            allowed: true,
            statusMessage:
                'Kalibrasyon tamamlandı. Faz 3 ile stereo rectify başlatın.',
          );
        }

        return const PhaseTransitionPlan(
          allowed: true,
          statusMessage: 'Faz 3 hazır. Canlı rectify başlatabilirsiniz.',
        );
    }
  }
}
