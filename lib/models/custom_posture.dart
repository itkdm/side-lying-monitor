/// 用户自定义姿势数据模型
class CustomPosture {
  const CustomPosture({
    required this.id,
    required this.name,
    required this.avgNx,
    required this.avgNy,
    required this.avgNz,
    required this.rawAx,
    required this.rawAy,
    required this.rawAz,
    required this.createdAt,
  });

  /// 唯一标识符
  final String id;
  
  /// 姿势名称（用户自定义）
  final String name;
  
  /// 归一化后的X轴平均值
  final double avgNx;
  
  /// 归一化后的Y轴平均值
  final double avgNy;
  
  /// 归一化后的Z轴平均值
  final double avgNz;
  
  /// 原始加速度X轴
  final double rawAx;
  
  /// 原始加速度Y轴
  final double rawAy;
  
  /// 原始加速度Z轴
  final double rawAz;
  
  /// 创建时间
  final DateTime createdAt;

  /// 从JSON创建
  factory CustomPosture.fromJson(Map<String, dynamic> json) {
    return CustomPosture(
      id: json['id'] as String,
      name: json['name'] as String,
      avgNx: (json['avgNx'] as num).toDouble(),
      avgNy: (json['avgNy'] as num).toDouble(),
      avgNz: (json['avgNz'] as num).toDouble(),
      rawAx: (json['rawAx'] as num).toDouble(),
      rawAy: (json['rawAy'] as num).toDouble(),
      rawAz: (json['rawAz'] as num).toDouble(),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'avgNx': avgNx,
      'avgNy': avgNy,
      'avgNz': avgNz,
      'rawAx': rawAx,
      'rawAy': rawAy,
      'rawAz': rawAz,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// 计算与当前传感器数据的相似度（欧氏距离）
  double calculateSimilarity(double nx, double ny, double nz, double ax, double ay, double az) {
    // 归一化向量的欧氏距离
    final normalizedDistance = 
        (nx - avgNx) * (nx - avgNx) +
        (ny - avgNy) * (ny - avgNy) +
        (nz - avgNz) * (nz - avgNz);
    
    // 原始加速度的欧氏距离（权重较低）
    final rawDistance = 
        (ax - rawAx) * (ax - rawAx) +
        (ay - rawAy) * (ay - rawAy) +
        (az - rawAz) * (az - rawAz);
    
    // 综合相似度：更强调重力方向一致性，将原始加速度权重调低
    return normalizedDistance * 0.9 + rawDistance * 0.1;
  }
}

