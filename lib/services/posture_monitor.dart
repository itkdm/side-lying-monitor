/// 传感器姿态监测状态数据模型
/// 用于在Flutter层和原生服务之间传递姿态检测结果
class PostureState {
  const PostureState({
    required this.isSideLying,
    this.sideLyingSince,
  });

  /// 是否处于侧躺状态
  final bool isSideLying;
  
  /// 侧躺状态开始的时间戳（用于计算持续时间）
  final DateTime? sideLyingSince;

  /// 创建新的状态副本，允许选择性更新字段
  PostureState copyWith({
    bool? isSideLying,
    DateTime? sideLyingSince,
  }) {
    return PostureState(
      isSideLying: isSideLying ?? this.isSideLying,
      sideLyingSince: sideLyingSince ?? this.sideLyingSince,
    );
  }
}

