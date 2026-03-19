import '../../domain/entities/app_settings.dart';
import '../../domain/repositories/app_settings_repository.dart';

class SaveAppSettingsUseCase {
  final AppSettingsRepository _repository;

  const SaveAppSettingsUseCase(this._repository);

  Future<void> call(AppSettings settings) {
    return _repository.save(settings);
  }
}
