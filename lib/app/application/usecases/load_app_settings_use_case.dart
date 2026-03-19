import '../../domain/entities/app_settings.dart';
import '../../domain/repositories/app_settings_repository.dart';

class LoadAppSettingsUseCase {
  final AppSettingsRepository _repository;

  const LoadAppSettingsUseCase(this._repository);

  Future<AppSettings> call() {
    return _repository.load();
  }
}
