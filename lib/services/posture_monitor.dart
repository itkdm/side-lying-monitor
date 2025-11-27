import 'dart:async';
import 'dart:math';

import 'package:sensors_plus/sensors_plus.dart';

/// 传感器姿态监测输出。仅包含 UI/提醒需要的核心字段。
class PostureState {
  const PostureState({
    required this.isSideLying,
    this.sideLyingSince,
  });

  final bool isSideLying;
  final DateTime? sideLyingSince;

  PostureState copyWith({
    bool? isSideLying,
    DateTime? sideLyingSince,
  }) {
    return PostureState(
      isSideLying: isSideLying ?? this.isSideLying,
      sideLyingSince: sideLyingSince,
    );
  }
}

/// 将加速度传感器的处理逻辑封装，方便 UI / 服务复用。
class PostureMonitor {
  PostureMonitor({
    required Stream<AccelerometerEvent> sensorStream,
    Duration stabilizationDuration = const Duration(seconds: 2),
    double deltaGResetThreshold = 0.8,
    double verticalAbsThreshold = 0.8,
    double horizontalDominantThreshold = 0.4,
    double rawAxThreshold = 6.5,
    double rawAzMax = 5.0,
  })  : _sensorStream = sensorStream,
        _stabilizationDuration = stabilizationDuration,
        _deltaGResetThreshold = deltaGResetThreshold,
        _verticalAbsThreshold = verticalAbsThreshold,
        _horizontalDominantThreshold = horizontalDominantThreshold,
        _rawAxThreshold = rawAxThreshold,
        _rawAzMax = rawAzMax;

  final Stream<AccelerometerEvent> _sensorStream;
  final Duration _stabilizationDuration;
  final double _deltaGResetThreshold;
  final double _verticalAbsThreshold;
  final double _horizontalDominantThreshold;
  final double _rawAxThreshold;
  final double _rawAzMax;

  StreamSubscription<AccelerometerEvent>? _subscription;
  final StreamController<PostureState> _stateController =
      StreamController<PostureState>.broadcast();

  double _avgNx = 0;
  double _avgNy = 0;
  double _avgNz = 1;
  double? _lastG;

  DateTime? _sideCandidateSince;
  PostureState _currentState = const PostureState(isSideLying: false);

  Stream<PostureState> get stateStream => _stateController.stream;
  PostureState get currentState => _currentState;

  void start() {
    if (_subscription != null) return;
    _subscription = _sensorStream.listen(
      _handleEvent,
      onError: (Object error, StackTrace stack) {
        // 避免异常终止整个监听
      },
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _resetState();
  }

  Future<void> dispose() async {
    stop();
    await _stateController.close();
  }

  void _handleEvent(AccelerometerEvent event) {
    final ax = event.x;
    final ay = event.y;
    final az = event.z;
    final g = sqrt(ax * ax + ay * ay + az * az);

    if (g < 1e-3) {
      return;
    }

    final nx = ax / g;
    final ny = ay / g;
    final nz = az / g;

    const alpha = 0.15;
    _avgNx = alpha * nx + (1 - alpha) * _avgNx;
    _avgNy = alpha * ny + (1 - alpha) * _avgNy;
    _avgNz = alpha * nz + (1 - alpha) * _avgNz;

    double deltaG = 0;
    if (_lastG != null) {
      deltaG = (g - _lastG!).abs();
    }
    _lastG = g;

    if (deltaG > _deltaGResetThreshold) {
      _sideCandidateSince = null;
      if (_currentState.isSideLying) {
        _emitState(const PostureState(isSideLying: false));
      }
      return;
    }

    final bool isScreenRoughlyVertical = _avgNz.abs() < _verticalAbsThreshold;
    final bool isGravityMostlySide =
        _avgNx.abs() > _horizontalDominantThreshold ||
            _avgNy.abs() > _horizontalDominantThreshold;
    final bool isSideByDirection =
        isScreenRoughlyVertical && isGravityMostlySide;
    final bool isSideByRaw = ax.abs() > _rawAxThreshold && az.abs() < _rawAzMax;
    final bool isSide = isSideByDirection || isSideByRaw;
    final now = DateTime.now();

    if (isSide) {
      _sideCandidateSince ??= now;
      final stableDuration = now.difference(_sideCandidateSince!);
      if (!_currentState.isSideLying &&
          stableDuration >= _stabilizationDuration) {
        _emitState(PostureState(isSideLying: true, sideLyingSince: now));
      }
    } else {
      _sideCandidateSince = null;
      if (_currentState.isSideLying) {
        _emitState(const PostureState(isSideLying: false));
      }
    }
  }

  void _emitState(PostureState next) {
    _currentState = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  void _resetState() {
    _avgNx = 0;
    _avgNy = 0;
    _avgNz = 1;
    _lastG = null;
    _sideCandidateSince = null;
    if (_currentState.isSideLying) {
      _emitState(const PostureState(isSideLying: false));
    }
  }
}

