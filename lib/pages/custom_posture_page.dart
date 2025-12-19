import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_application_1/models/custom_posture.dart';
import 'package:flutter_application_1/services/custom_posture_repository.dart';
import 'package:flutter_application_1/widgets/glass_card.dart';
import 'package:flutter_application_1/utils/logger.dart';
import 'dart:math' as math;

/// 添加自定义姿势页面
class CustomPosturePage extends StatefulWidget {
  const CustomPosturePage({super.key});

  @override
  State<CustomPosturePage> createState() => _CustomPosturePageState();
}

class _CustomPosturePageState extends State<CustomPosturePage> {
  final _repository = CustomPostureRepository.instance;
  final _nameController = TextEditingController();
  StreamSubscription<AccelerometerEvent>? _subscription;
  
  // 传感器数据
  double _avgNx = 0.0;
  double _avgNy = 0.0;
  double _avgNz = 1.0;
  double _rawAx = 0.0;
  double _rawAy = 0.0;
  double _rawAz = 0.0;
  
  // 采样计数
  int _sampleCount = 0;
  bool _isRecording = false;
  bool _isSaving = false;
  
  // 平滑参数
  static const double _alpha = 0.15;
  static const int _minSamples = 30; // 至少采样30次（约1秒）

  @override
  void initState() {
    super.initState();
    _nameController.text = '自定义姿势 ${_repository.customPostures.length + 1}';
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  void _startRecording() {
    if (_isRecording) return;
    
    setState(() {
      _isRecording = true;
      _sampleCount = 0;
      _avgNx = 0.0;
      _avgNy = 0.0;
      _avgNz = 1.0;
      _rawAx = 0.0;
      _rawAy = 0.0;
      _rawAz = 0.0;
    });

    _subscription = accelerometerEventStream().listen((event) {
      if (!_isRecording) return;
      
      final ax = event.x;
      final ay = event.y;
      final az = event.z;
      final g = math.sqrt(ax * ax + ay * ay + az * az);
      
      if (g < 1e-3) return;
      
      final nx = ax / g;
      final ny = ay / g;
      final nz = az / g;
      
      setState(() {
        // 指数平滑
        _avgNx = _alpha * nx + (1 - _alpha) * _avgNx;
        _avgNy = _alpha * ny + (1 - _alpha) * _avgNy;
        _avgNz = _alpha * nz + (1 - _alpha) * _avgNz;
        
        // 原始值（使用最后一次的值）
        _rawAx = ax;
        _rawAy = ay;
        _rawAz = az;
        
        _sampleCount++;
      });
    });
  }

  void _stopRecording() {
    setState(() {
      _isRecording = false;
    });
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _savePosture() async {
    if (_nameController.text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入姿势名称')),
        );
      }
      return;
    }

    if (_sampleCount < _minSamples) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请至少记录 ${_minSamples} 个样本（约1秒）')),
        );
      }
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await _repository.addCustomPosture(
        name: _nameController.text.trim(),
        avgNx: _avgNx,
        avgNy: _avgNy,
        avgNz: _avgNz,
        rawAx: _rawAx,
        rawAy: _rawAy,
        rawAz: _rawAz,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('姿势已保存')),
        );
        Navigator.of(context).pop(true); // 返回true表示已保存
      }
    } catch (e, stackTrace) {
      AppLogger.e('CustomPosturePage', 'Failed to save posture', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，请重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1E),
      appBar: AppBar(
        title: const Text('添加自定义姿势'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '姿势名称',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameController,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: Colors.white,
                      ),
                      decoration: InputDecoration(
                        hintText: '请输入姿势名称',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.2),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.2),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.4),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '记录姿势',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '保持你想要的姿势，然后点击开始记录。建议记录3-5秒以获得更准确的数据。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!_isRecording)
                      ElevatedButton.icon(
                        onPressed: _startRecording,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('开始记录'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4361EE),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      )
                    else
                      Column(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _stopRecording,
                            icon: const Icon(Icons.stop),
                            label: const Text('停止记录'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '已记录: $_sampleCount 个样本',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                          if (_sampleCount < _minSamples)
                            Text(
                              '建议至少记录 $_minSamples 个样本',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.orange,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前传感器数据',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildDataRow('归一化 X', _avgNx.toStringAsFixed(3)),
                    _buildDataRow('归一化 Y', _avgNy.toStringAsFixed(3)),
                    _buildDataRow('归一化 Z', _avgNz.toStringAsFixed(3)),
                    const SizedBox(height: 8),
                    _buildDataRow('原始 X', _rawAx.toStringAsFixed(2)),
                    _buildDataRow('原始 Y', _rawAy.toStringAsFixed(2)),
                    _buildDataRow('原始 Z', _rawAz.toStringAsFixed(2)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: (_isSaving || _sampleCount < _minSamples) ? null : _savePosture,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4361EE),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text('保存姿势'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
          ),
        ],
      ),
    );
  }
}

