enum CaptureWorkflowPhase {
  cameraSelection,
  calibration,
  stereoMatching,
  rawStreamingUpload,
}

extension CaptureWorkflowPhaseLabel on CaptureWorkflowPhase {
  String get shortLabel {
    switch (this) {
      case CaptureWorkflowPhase.cameraSelection:
        return 'Faz 1';
      case CaptureWorkflowPhase.calibration:
        return 'Faz 2';
      case CaptureWorkflowPhase.stereoMatching:
        return 'Faz 3';
      case CaptureWorkflowPhase.rawStreamingUpload:
        return 'Faz 4';
    }
  }

  String get title {
    switch (this) {
      case CaptureWorkflowPhase.cameraSelection:
        return 'Kamera Seçimi';
      case CaptureWorkflowPhase.calibration:
        return 'Kalibrasyon';
      case CaptureWorkflowPhase.stereoMatching:
        return 'Stereo Eşleme';
      case CaptureWorkflowPhase.rawStreamingUpload:
        return 'Ham Kayıt + Upload';
    }
  }
}
