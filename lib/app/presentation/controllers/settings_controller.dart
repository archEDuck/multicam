import 'dart:async';

import '../../application/usecases/load_app_settings_use_case.dart';
import '../../application/usecases/save_app_settings_use_case.dart';
import '../../domain/entities/app_settings.dart';

class SettingsController {
  SettingsController({
    required LoadAppSettingsUseCase loadUseCase,
    required SaveAppSettingsUseCase saveUseCase,
  }) : _loadUseCase = loadUseCase,
       _saveUseCase = saveUseCase;

  final LoadAppSettingsUseCase _loadUseCase;
  final SaveAppSettingsUseCase _saveUseCase;

  AppSettings _current = AppSettings.defaults();
  AppSettings get current => _current;

  Timer? _autoSaveDebounce;

  Future<AppSettings> load() async {
    _current = await _loadUseCase();
    return _current;
  }

  Future<void> update(AppSettings next) async {
    _current = next;
    _scheduleAutoSave();
  }

  Future<void> flushNow() async {
    _autoSaveDebounce?.cancel();
    await _saveUseCase(_current);
  }

  void dispose() {
    _autoSaveDebounce?.cancel();
  }

  void _scheduleAutoSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 250), () {
      _saveUseCase(_current);
    });
  }
}
