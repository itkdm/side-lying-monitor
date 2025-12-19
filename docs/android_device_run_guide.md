# Android 真机运行指南

> **设备信息**：JAD AL00 (Android 12, API 31)

---

## ✅ 设备连接状态

- **设备名称**：JAD AL00
- **设备ID**：L2E0221B30000291
- **系统版本**：Android 12 (API 31)
- **架构**：android-arm64
- **连接状态**：✅ 已连接

---

## 🚀 运行方式

### 方式1：使用设备ID运行（推荐）
```bash
flutter run -d L2E0221B30000291
```

### 方式2：使用设备名称运行
```bash
flutter run -d "JAD AL00"
```

### 方式3：直接运行（如果只有一个设备）
```bash
flutter run
```

---

## 📱 运行参数说明

### 常用参数
- `-d <device-id>` - 指定设备ID
- `--release` - 发布模式（性能更好，但编译时间更长）
- `--debug` - 调试模式（默认，支持热重载）
- `--profile` - 性能分析模式

### 示例
```bash
# 调试模式（默认）
flutter run -d L2E0221B30000291

# 发布模式
flutter run -d L2E0221B30000291 --release

# 性能分析模式
flutter run -d L2E0221B30000291 --profile
```

---

## 🔥 热重载功能

应用运行后，可以使用以下快捷键：

- **r** - 热重载（Hot Reload）- 快速刷新UI
- **R** - 热重启（Hot Restart）- 重启应用
- **q** - 退出应用
- **h** - 显示帮助信息

---

## ⚠️ 常见问题

### 1. 设备未识别
**问题**：`flutter devices` 显示没有设备

**解决方案**：
```bash
# 检查ADB连接
adb devices

# 如果显示 "unauthorized"，需要在手机上允许USB调试
# 如果显示 "offline"，尝试：
adb kill-server
adb start-server
adb devices
```

### 2. 编译错误
**问题**：编译时出现错误

**解决方案**：
```bash
# 清理构建缓存
flutter clean

# 重新获取依赖
flutter pub get

# 重新运行
flutter run -d L2E0221B30000291
```

### 3. 安装失败
**问题**：应用安装失败

**解决方案**：
- 检查手机存储空间
- 检查是否已安装同名应用（需要先卸载）
- 检查USB调试权限

### 4. 权限问题
**问题**：应用需要悬浮窗权限等

**解决方案**：
- 应用首次运行时，会提示请求权限
- 按照提示在系统设置中授予权限
- 悬浮窗权限：设置 → 应用 → 特殊权限 → 在其他应用上层显示

---

## 📋 运行前检查清单

- [x] 设备已通过USB连接到电脑
- [x] 已开启USB调试模式
- [x] 设备已在 `flutter devices` 中显示
- [x] 已运行 `flutter pub get` 安装依赖
- [ ] 手机已解锁并允许USB调试
- [ ] 手机有足够的存储空间

---

## 🎯 运行步骤总结

1. **连接设备**
   ```bash
   adb devices  # 确认设备连接
   ```

2. **检查设备**
   ```bash
   flutter devices  # 查看可用设备
   ```

3. **运行应用**
   ```bash
   flutter run -d L2E0221B30000291
   ```

4. **等待编译完成**
   - 首次运行可能需要几分钟
   - 后续运行会更快（增量编译）

5. **使用热重载**
   - 修改代码后按 `r` 快速刷新
   - 修改后按 `R` 重启应用

---

## 📝 注意事项

1. **首次运行**：首次运行到真机可能需要较长时间（5-10分钟），因为需要编译APK
2. **网络要求**：确保手机和电脑在同一网络，或使用USB连接
3. **电池优化**：建议关闭应用的电池优化，确保后台监测功能正常
4. **权限授予**：应用需要以下权限：
   - 悬浮窗权限（用于后台显示悬浮窗）
   - 通知权限（用于后台提醒）
   - 传感器权限（用于姿态检测）

---

## 🔧 故障排除

### 如果遇到问题，按以下顺序尝试：

1. **重启ADB服务**
   ```bash
   adb kill-server
   adb start-server
   ```

2. **清理并重新构建**
   ```bash
   flutter clean
   flutter pub get
   flutter run -d L2E0221B30000291
   ```

3. **检查Flutter环境**
   ```bash
   flutter doctor
   ```

4. **检查Android SDK**
   ```bash
   flutter doctor -v
   ```

---

**设备信息**：JAD AL00 (L2E0221B30000291)  
**系统版本**：Android 12 (API 31)  
**状态**：✅ 已连接，可以运行

