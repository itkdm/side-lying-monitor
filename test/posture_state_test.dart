import 'package:flutter_application_1/services/posture_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PostureState.copyWith', () {
    test('keeps existing timestamp when not provided', () {
      final initialTime = DateTime(2025, 11, 27, 22, 0);
      const state = PostureState(isSideLying: true);
      final enriched = state.copyWith(sideLyingSince: initialTime);

      final toggled = enriched.copyWith(isSideLying: false);

      expect(toggled.isSideLying, isFalse);
      expect(toggled.sideLyingSince, same(initialTime));
    });

    test('keeps existing timestamp when passing null in copyWith', () {
      final initialTime = DateTime(2025, 11, 27, 22, 0);
      final initial = PostureState(
        isSideLying: true,
        sideLyingSince: initialTime,
      );

      // copyWith中传入null时保留原值（这是标准行为）
      final unchanged = initial.copyWith(sideLyingSince: null);

      expect(unchanged.sideLyingSince, equals(initialTime));
    });
  });
}

