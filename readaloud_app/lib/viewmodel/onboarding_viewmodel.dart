import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repository/settings_repository.dart';
import '../model/setting.dart';

class OnboardingState {
  final bool isCompleted;
  final bool isLoading;

  OnboardingState({
    this.isCompleted = false,
    this.isLoading = false,
  });

  OnboardingState copyWith({
    bool? isCompleted,
    bool? isLoading,
  }) =>
      OnboardingState(
        isCompleted: isCompleted ?? this.isCompleted,
        isLoading: isLoading ?? this.isLoading,
      );
}

class OnboardingViewModel extends StateNotifier<OnboardingState> {
  final SettingsRepository _settingsRepo;

  OnboardingViewModel(this._settingsRepo) : super(OnboardingState()) {
    _checkOnboardingStatus();
  }

  Future<void> _checkOnboardingStatus() async {
    state = state.copyWith(isLoading: true);
    final completed =
        await _settingsRepo.get(SettingKeys.onboardingCompleted);
    state = state.copyWith(
      isCompleted: completed == 'true',
      isLoading: false,
    );
  }

  Future<void> completeOnboarding() async {
    await _settingsRepo.set(SettingKeys.onboardingCompleted, 'true');
    state = state.copyWith(isCompleted: true);
  }
}
