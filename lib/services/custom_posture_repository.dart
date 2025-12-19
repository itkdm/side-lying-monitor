import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_application_1/models/custom_posture.dart';
import 'package:flutter_application_1/utils/logger.dart';

/// 管理用户自定义姿势的存储和检索
class CustomPostureRepository extends ChangeNotifier {
  CustomPostureRepository._internal();
  static final CustomPostureRepository instance = CustomPostureRepository._internal();
  
  static const MethodChannel _channel =
      MethodChannel('com.example.flutter_application_1/floating_window');

  SharedPreferences? _prefs;
  bool _initialized = false;
  bool _initializing = false;
  bool _useCustomPostures = false;
  List<CustomPosture> _customPostures = [];

  bool get useCustomPostures => _useCustomPostures;
  List<CustomPosture> get customPostures => List.unmodifiable(_customPostures);

  Future<void> init() async {
    AppLogger.d('CustomPostureRepository', '=== init() called ===');
    if (_initialized) {
      AppLogger.d('CustomPostureRepository', 'Already initialized, skipping');
      return;
    }
    if (_initializing) {
      AppLogger.d('CustomPostureRepository', 'Initialization already in progress, skipping');
      return;
    }
    _initializing = true;
    try {
      AppLogger.d('CustomPostureRepository', 'Getting SharedPreferences...');
      _prefs = await SharedPreferences.getInstance();
      AppLogger.d('CustomPostureRepository', 'Loading from prefs...');
      await _loadFromPrefs();
      _initialized = true;
      AppLogger.d('CustomPostureRepository', 'Syncing to native...');
      await _syncToNative(); // 初始化时同步到原生服务
      AppLogger.d('CustomPostureRepository', '=== init() completed ===');
    } catch (e, stackTrace) {
      AppLogger.e('CustomPostureRepository', 'Init failed', e, stackTrace);
      _initialized = true; // 标记为已初始化，避免重复尝试
    } finally {
      _initializing = false;
    }
  }

  Future<void> _ensureReady() async {
    if (_initializing) {
      return;
    }
    if (!_initialized) {
      await init();
    }
  }

  Future<void> _loadFromPrefs() async {
    // 加载是否使用自定义姿势
    _useCustomPostures = _prefs!.getBool('use_custom_postures') ?? false;
    
    // 加载自定义姿势列表
    final posturesJson = _prefs!.getString('custom_postures');
    if (posturesJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(posturesJson);
        _customPostures = decoded
            .map((json) => CustomPosture.fromJson(json as Map<String, dynamic>))
            .toList();
      } catch (e, stackTrace) {
        AppLogger.e('CustomPostureRepository', 'Failed to load custom postures', e, stackTrace);
        _customPostures = [];
      }
    } else {
      _customPostures = [];
    }
  }

  Future<void> _saveToPrefs() async {
    await _ensureReady();
    await _prefs!.setBool('use_custom_postures', _useCustomPostures);
    
    final posturesJson = jsonEncode(
      _customPostures.map((posture) => posture.toJson()).toList(),
    );
    await _prefs!.setString('custom_postures', posturesJson);
  }

  /// 添加自定义姿势
  Future<void> addCustomPosture({
    required String name,
    required double avgNx,
    required double avgNy,
    required double avgNz,
    required double rawAx,
    required double rawAy,
    required double rawAz,
  }) async {
    await _ensureReady();
    
    final posture = CustomPosture(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      avgNx: avgNx,
      avgNy: avgNy,
      avgNz: avgNz,
      rawAx: rawAx,
      rawAy: rawAy,
      rawAz: rawAz,
      createdAt: DateTime.now(),
    );
    
    _customPostures.add(posture);
    await _saveToPrefs();
    await _syncToNative();
    notifyListeners();
    
    AppLogger.d('CustomPostureRepository', 'Added custom posture: $name');
  }

  /// 删除自定义姿势
  Future<void> removeCustomPosture(String id) async {
    await _ensureReady();
    _customPostures.removeWhere((posture) => posture.id == id);
    await _saveToPrefs();
    await _syncToNative();
    notifyListeners();
    
    AppLogger.d('CustomPostureRepository', 'Removed custom posture: $id');
  }

  /// 设置是否使用自定义姿势
  Future<void> setUseCustomPostures(bool value) async {
    await _ensureReady();
    if (_useCustomPostures == value) return;
    _useCustomPostures = value;
    await _saveToPrefs();
    await _syncToNative();
    notifyListeners();
    
    AppLogger.d('CustomPostureRepository', 'Use custom postures: $value');
  }

  /// 清除所有自定义姿势
  Future<void> clearAllCustomPostures() async {
    await _ensureReady();
    _customPostures.clear();
    _useCustomPostures = false;
    await _saveToPrefs();
    await _syncToNative();
    notifyListeners();
    
    AppLogger.d('CustomPostureRepository', 'Cleared all custom postures');
  }
  
  /// 同步自定义姿势数据到原生服务
  Future<void> _syncToNative() async {
    try {
      AppLogger.d('CustomPostureRepository', 'Syncing to native: useCustomPostures=$_useCustomPostures, count=${_customPostures.length}');
      final payload = {
        'useCustomPostures': _useCustomPostures,
        'customPostures': _customPostures.map((p) => {
          'id': p.id,
          'name': p.name,
          'avgNx': p.avgNx,
          'avgNy': p.avgNy,
          'avgNz': p.avgNz,
          'rawAx': p.rawAx,
          'rawAy': p.rawAy,
          'rawAz': p.rawAz,
        }).toList(),
      };
      await _channel.invokeMethod('syncCustomPostures', payload);
      AppLogger.d('CustomPostureRepository', 'Sync to native completed');
    } catch (e, stackTrace) {
      AppLogger.e('CustomPostureRepository', 'Failed to sync custom postures to native', e, stackTrace);
      // 不抛出异常，避免阻塞初始化
    }
  }

  /// 检查当前传感器数据是否匹配任何自定义姿势
  /// 返回匹配的姿势和相似度，如果没有匹配则返回null
  ({CustomPosture posture, double similarity})? findMatchingPosture(
    double nx,
    double ny,
    double nz,
    double ax,
    double ay,
    double az,
    {double threshold = 0.5} // 相似度阈值，越小越严格
  ) {
    if (_customPostures.isEmpty) return null;
    
    CustomPosture? bestMatch;
    double bestSimilarity = double.infinity;
    
    for (final posture in _customPostures) {
      final similarity = posture.calculateSimilarity(nx, ny, nz, ax, ay, az);
      if (similarity < bestSimilarity) {
        bestSimilarity = similarity;
        bestMatch = posture;
      }
    }
    
    // 如果最佳匹配的相似度低于阈值，返回匹配结果
    if (bestMatch != null && bestSimilarity < threshold) {
      return (posture: bestMatch, similarity: bestSimilarity);
    }
    
    return null;
  }
}

