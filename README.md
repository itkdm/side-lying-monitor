# Side Lying Monitor - 智能侧躺监测与健康提醒应用

> 帮助您养成良好的手机使用习惯，保护颈椎健康

[![GitHub](https://img.shields.io/badge/GitHub-itkdm-blue)](https://github.com/itkdm/side-lying-monitor)
[![Gitee](https://img.shields.io/badge/Gitee-itkdm-red)](https://gitee.com/itkdm/side-lying-monitor)

## 📱 应用简介

Side Lying Monitor（枕边哨）是一款智能侧躺监测应用，通过实时监测手机姿态，帮助用户避免长时间侧躺使用手机，从而保护颈椎健康。

### 核心功能

- ✅ **实时姿态监测**：通过传感器实时监测手机姿态，识别侧躺姿势
- ✅ **智能提醒**：检测到侧躺姿势后，通过震动和通知提醒用户
- ✅ **自定义姿势**：支持录制和识别自定义姿势
- ✅ **免打扰模式**：支持设置免打扰时间段
- ✅ **统计功能**：记录每日提醒次数
- ✅ **主题切换**：支持深色/浅色主题切换
- ✅ **后台运行**：支持后台持续监测（Android）

## 🛠️ 技术栈

- **框架**：Flutter 3.24.3
- **语言**：Dart 3.5.3
- **主要依赖**：
  - `sensors_plus` - 传感器数据采集
  - `vibration` - 震动反馈
  - `shared_preferences` - 本地数据存储
  - `flutter_local_notifications` - 本地通知

## 📦 项目结构

```
lib/
├── controllers/          # 控制器（提醒、生命周期）
├── models/              # 数据模型
├── pages/               # 页面组件
├── services/           # 服务层（监测、设置、通知等）
├── utils/              # 工具类
└── widgets/            # 通用组件
```

## 🚀 快速开始

### 环境要求

- Flutter SDK >= 3.5.0
- Dart SDK >= 3.5.0
- Android Studio / VS Code
- Android SDK (Android 8.0+)

### 安装步骤

1. **克隆项目**

   **GitHub:**
   ```bash
   git clone git@github.com:itkdm/side-lying-monitor.git
   cd side-lying-monitor
   ```

   **Gitee:**
   ```bash
   git clone git@gitee.com:itkdm/side-lying-monitor.git
   cd side-lying-monitor
   ```

2. **安装依赖**
   ```bash
   flutter pub get
   ```

3. **运行项目**
   ```bash
   flutter run
   ```

### 构建发布版本

**Android APK**
```bash
flutter build apk --release
```

**Android App Bundle**
```bash
flutter build appbundle --release
```

## 📝 配置说明

### Android 签名配置

1. 复制 `android/key.properties.example` 为 `android/key.properties`
2. 填写实际的签名信息：
   ```properties
   storePassword=你的密钥库密码
   keyPassword=你的密钥密码
   keyAlias=publish-key
   storeFile=app/publish-key.jks
   ```
3. 将签名密钥文件放置在 `android/app/publish-key.jks`

> ⚠️ **重要**：`key.properties` 和 `publish-key.jks` 文件已添加到 `.gitignore`，不会提交到版本控制。

## 🔧 开发说明

### 架构设计

项目采用分层架构：
- **UI层**：Flutter Widgets，负责用户界面展示
- **控制器层**：管理业务逻辑和状态
- **服务层**：提供核心功能服务（监测、设置、通知等）
- **原生层**：Android 原生服务，负责后台监测和悬浮窗

### 核心服务

- `PostureMonitor` - 姿态监测服务
- `SettingsRepository` - 设置管理
- `ReminderController` - 提醒控制
- `LifecycleCoordinator` - 生命周期协调
- `FloatingWindowManager` - 悬浮窗管理

## 📄 许可证

本项目采用私有许可证，未经授权不得使用。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request。

## ⚠️ 注意事项

1. **权限要求**：
   - Android 需要悬浮窗权限（用于后台监测）
   - 需要通知权限（用于提醒）
   - 需要忽略电池优化权限（保证后台运行）

2. **兼容性**：
   - 最低支持 Android 8.0 (API 26)
   - 推荐 Android 10.0+ (API 29)

3. **性能优化**：
   - 传感器采样频率已优化，降低电池消耗
   - 使用 WakeLock 保证后台服务稳定运行

## 📞 联系方式

如有问题或建议，请通过 Issue 反馈。

---

**最后更新**：2025-01-28
