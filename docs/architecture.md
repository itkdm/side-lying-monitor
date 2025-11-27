# 枕边哨架构速览

> 目标：让 Flutter 层聚焦 UI 与状态、原生服务负责后台与传感器，二者通过 `MethodChannel` 和共享存储协作。

## 层次结构

| 层 | 目录 | 主要职责 |
| --- | --- | --- |
| UI Shell | `lib/main.dart` | `RootShell` 负责导航、依赖注入、监测开关与通知联动，同时协调权限/悬浮窗与原生服务。 |
| Feature Pages | `lib/pages/home_page.dart`, `lib/pages/settings_page.dart` | 每个页面只消费传入的状态回调，使用 `GlassCard` 等共享组件呈现玻璃拟态 UI。 |
| Services | `lib/services/` | `posture_monitor.dart`（姿态检测流）、`settings_repository.dart`（SharedPreferences cache）、`permission_coordinator.dart`（权限状态机）、`floating_window_manager.dart`（MethodChannel 桥）、`settings_repository` 负责状态持久化与广播。 |
| Native Service | `android/app/src/.../FloatingWindowService.kt` | 运行在前台服务中，接收设置广播，处理传感器、通知、悬浮窗。 |
| Documentation & Tests | `docs/*.md`, `test/*.dart` | 记录改造步骤与架构约定，提供最小 widget/单元测试保障。 |

## 权限与悬浮窗流程

1. `RootShell` 在 `initState` 中创建 `PermissionCoordinator` 并监听状态。
2. 当应用进入后台且开启监测时，`RootShell` 调用 `_showFloatingWindow()`，内部先 `ensureOverlayPermission()`：
   - 已授权：直接调用 `FloatingWindowManager.showFloatingWindow()`。
   - 未授权：通过 `MethodChannel` 触发原生授权页；若仍失败会弹出指导对话框。
3. `PermissionCoordinator` 保存最新授权状态并通过 `ChangeNotifier` 通知 UI，UI 可据此提示用户。

## 设置同步

```
RootShell -> SettingsRepository -> MethodChannel(syncSettings) -> MainActivity -> Broadcast -> FloatingWindowService
```

- Dart 端修改监测、震动、阈值或免打扰时立即调用 `syncSettings`。
- Android 端广播 `ACTION_SETTINGS_UPDATED`，前台服务实时刷新缓存，提醒逻辑读取内存值即可。

## 推荐的开发节奏

1. 业务改动前优先修改/扩展 `services` 层，暴露干净的 API。
2. 在 UI 层通过构造函数/回调接收依赖，保持 `StatelessWidget` 尽量纯粹。
3. 原生层新增能力时，在 `docs/architecture.md` 补充“责任边界 + 数据流”，并同步到 `SettingsRepository`/`PermissionCoordinator`。
4. 通过 `flutter test` 和 `flutter analyze` 保持 Flutter 层健康，再以真机验证悬浮窗与后台服务。

如需扩展更多页面，可在 `lib/pages/` 下新增文件，并让 `RootShell` 或路由管理器装配即可，做到“UI 只拿数据，逻辑在服务”。

