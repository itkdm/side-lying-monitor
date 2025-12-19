import 'package:flutter/material.dart';
import 'package:flutter_application_1/services/custom_posture_repository.dart';
import 'package:flutter_application_1/pages/custom_posture_page.dart';
import '../widgets/glass_card.dart';
import '../services/theme_repository.dart';

/// 设置页：震动开关、时间阈值、免打扰时段
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.vibrationEnabled,
    required this.thresholdSeconds,
    required this.dndStart,
    required this.dndEnd,
    required this.dndEnabled,
    required this.onVibrationChanged,
    required this.onThresholdChanged,
    required this.onDndStartChanged,
    required this.onDndEndChanged,
    required this.onDndEnabledChanged,
    required this.useCustomPostures,
    required this.onUseCustomPosturesChanged,
  });

  final bool vibrationEnabled;
  final int thresholdSeconds;
  final TimeOfDay dndStart;
  final TimeOfDay dndEnd;
  final bool dndEnabled;
  final ValueChanged<bool> onVibrationChanged;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<TimeOfDay> onDndStartChanged;
  final ValueChanged<TimeOfDay> onDndEndChanged;
  final ValueChanged<bool> onDndEnabledChanged;
  final bool useCustomPostures;
  final ValueChanged<bool> onUseCustomPosturesChanged;

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = ThemeRepository.instance.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final textColorSecondary = isDark ? Colors.white70 : const Color(0xFF666666);
    final textColorTertiary = isDark ? Colors.white54 : const Color(0xFF999999);

    return Container(
      // 背景渐变已在 main.dart 的 builder 中处理，这里不需要重复
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(
                '设置',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '根据你的习惯，调节提醒的方式',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: textColorSecondary,
                ),
              ),
              const SizedBox(height: 24),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '震动提醒',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '轻柔震动，像朋友轻拍你的肩膀',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: textColorSecondary,
                              ),
                            ),
                          ],
                        ),
                        Switch(
                          value: vibrationEnabled,
                          onChanged: onVibrationChanged,
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
                      '侧躺持续时间阈值',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '仅当侧躺持续达到该时长才提醒，避免误判',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: textColorSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${thresholdSeconds.toString()} 秒',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '5 - 120 秒',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: textColorTertiary,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      min: 5,
                      max: 120,
                      divisions: 23,
                      value: thresholdSeconds.toDouble().clamp(5, 120),
                      onChanged: onThresholdChanged,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '免打扰时段',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '在该时间段内，不会弹出提醒或震动',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: textColorSecondary,
                              ),
                            ),
                          ],
                        ),
                        Switch.adaptive(
                          value: dndEnabled,
                          onChanged: onDndEnabledChanged,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _DndTimeChip(
                          label: '开始',
                          timeText: _formatTime(dndStart),
                          enabled: dndEnabled,
                          onTap: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: dndStart,
                            );
                            if (picked != null) {
                              onDndStartChanged(picked);
                            }
                          },
                        ),
                        const SizedBox(width: 12),
                        _DndTimeChip(
                          label: '结束',
                          timeText: _formatTime(dndEnd),
                          enabled: dndEnabled,
                          onTap: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: dndEnd,
                            );
                            if (picked != null) {
                              onDndEndChanged(picked);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: CustomPostureRepository.instance,
                builder: (context, _) {
                  final repo = CustomPostureRepository.instance;
                  return GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '自定义侧躺姿势',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: textColor,
                              ),
                            ),
                        Switch.adaptive(
                          value: useCustomPostures,
                          onChanged: onUseCustomPosturesChanged,
                        ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '为侧躺录制自定义姿势数据进行监测，或使用默认系统算法',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: textColorSecondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _CustomPostureList(),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: ThemeRepository.instance,
                builder: (context, _) {
                  final themeRepo = ThemeRepository.instance;
                  return GlassCard(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '主题模式',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              themeRepo.isDark ? '深色模式' : '亮色模式',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: textColorSecondary,
                              ),
                            ),
                          ],
                        ),
                        Switch.adaptive(
                          value: themeRepo.isDark,
                          onChanged: (value) {
                            themeRepo.setThemeMode(
                              value ? AppThemeMode.dark : AppThemeMode.light,
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '隐私与数据说明',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '本 App 仅使用设备传感器判断姿态，不采集、不上传任何个人隐私数据。所有设置与统计仅保存在本机，可随时卸载清除。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: textColorSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _DndTimeChip extends StatelessWidget {
  const _DndTimeChip({
    required this.label,
    required this.timeText,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String timeText;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = ThemeRepository.instance.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final textColorSecondary = isDark ? Colors.white70 : const Color(0xFF666666);
    final borderColor = isDark 
        ? Colors.white.withOpacity(enabled ? 0.18 : 0.08)
        : Colors.black.withOpacity(enabled ? 0.15 : 0.05);
    final bgColor = isDark
        ? Colors.white.withOpacity(enabled ? 0.06 : 0.02)
        : Colors.black.withOpacity(enabled ? 0.03 : 0.01);

    return Expanded(
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: bgColor,
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                      color: textColorSecondary,
                    ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    timeText,
                    style: theme.textTheme.titleMedium?.copyWith(
                          color: textColor.withOpacity(enabled ? 1 : 0.5),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: textColorSecondary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自定义姿势列表与操作
class _CustomPostureList extends StatefulWidget {
  @override
  State<_CustomPostureList> createState() => _CustomPostureListState();
}

class _CustomPostureListState extends State<_CustomPostureList> {
  final _repository = CustomPostureRepository.instance;

  @override
  void initState() {
    super.initState();
    _repository.addListener(_onRepositoryChanged);
  }

  @override
  void dispose() {
    _repository.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onRepositoryChanged() {
    setState(() {});
  }

  Future<void> _addPosture() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => const CustomPosturePage(),
      ),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('姿势已添加')),
      );
    }
  }

  Future<void> _deletePosture(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除姿势'),
        content: Text('确定要删除姿势 "$name" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _repository.removeCustomPosture(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('姿势已删除')),
        );
      }
    }
  }

  Future<void> _resetToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认算法'),
        content: const Text('确定要清除所有自定义姿势并恢复默认检测算法吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _repository.clearAllCustomPostures();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已恢复默认算法')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = ThemeRepository.instance.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final textColorSecondary = isDark ? Colors.white70 : const Color(0xFF666666);
    final textColorTertiary = isDark ? Colors.white54 : const Color(0xFF999999);
    final postures = _repository.customPostures;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (postures.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
                      '暂无自定义侧躺姿势',
              style: theme.textTheme.bodySmall?.copyWith(
                color: textColorTertiary,
              ),
              textAlign: TextAlign.center,
            ),
          )
        else
          ...postures.map(
            (posture) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: isDark 
                      ? Colors.white.withOpacity(0.05)
                      : Colors.black.withOpacity(0.03),
                  border: Border.all(
                    color: isDark 
                        ? Colors.white.withOpacity(0.1)
                        : Colors.black.withOpacity(0.08),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            posture.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '创建于 ${_formatDate(posture.createdAt)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: textColorTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _deletePosture(posture.id, posture.name),
                      tooltip: '删除',
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _addPosture,
                icon: const Icon(Icons.add),
                label: const Text('添加姿势'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: textColor,
                  side: BorderSide(
                    color: isDark 
                        ? Colors.white.withOpacity(0.3)
                        : Colors.black.withOpacity(0.2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (postures.isNotEmpty)
              OutlinedButton(
                onPressed: _resetToDefault,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
                child: const Text('恢复默认'),
              ),
          ],
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
