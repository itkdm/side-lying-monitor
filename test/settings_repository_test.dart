import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/services/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsRepository.instance.resetForTest();
    await SettingsRepository.instance.init();
  });

  test('persists monitoring flag through repository cache', () async {
    final repo = SettingsRepository.instance;
    expect(repo.monitoring, isFalse);

    await repo.setMonitoring(true);
    expect(repo.monitoring, isTrue);

    await repo.refreshFromDisk();
    expect(repo.monitoring, isTrue);
  });

  test('tracks today remind count with automatic day reset', () async {
    final repo = SettingsRepository.instance;
    await repo.incrementTodayRemindCount(at: DateTime(2025, 11, 27, 22));
    expect(repo.todayRemindCount, 1);

    await repo.incrementTodayRemindCount(at: DateTime(2025, 11, 27, 23));
    expect(repo.todayRemindCount, 2);

    await repo.resetTodayIfNeeded(DateTime(2025, 11, 28));
    expect(repo.todayRemindCount, 0);
    expect(repo.today.year, 2025);
    expect(repo.today.month, 11);
    expect(repo.today.day, 28);
  });
}

