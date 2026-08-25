# Flutter iOS 支持分支

`feature/flutter-support` 从原生 iOS `main` 分支派生，但使用独立的
`schema_version: 2`。App 仓库必须固定引用本分支某个经过审核的完整 commit
SHA，不应在生产工作流中直接引用分支名。

## 与原生 main 的边界

- `main` 保持原生 iOS 配置契约和脚本行为。
- Flutter 分支只接受 `build.dependency_mode: flutter`。
- Flutter 分支要求显式提供 Flutter 工程子目录、SDK 版本、Runner 架构和
  Flutter 官方 SDK 归档 SHA-256。
- 两个分支继续共用 Archive、签名、IPA 检查、Artifact、ASC 上传和状态轮询
  的安全边界。

## 嵌套工程

配置中的路径始终相对于 App 的远程 Git 仓库根目录。例如 Donesome：

```text
Donesome/
├── .github/ios-build.yml
└── Hearthio/
    ├── pubspec.yaml
    ├── pubspec.lock
    └── ios/Runner.xcworkspace
```

对应配置：

```yaml
schema_version: 2

flutter:
  project_directory: Hearthio
  version: 3.35.7
  channel: stable
  architecture: arm64
  sdk_sha256: 4d7aaadc4893f9216d4e2ecbe0e8fb4213e9bd49d29fd5f441f34fcc05758e2b

build:
  container_type: workspace
  container_path: Hearthio/ios/Runner.xcworkspace
  scheme: Run-Release
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: flutter
  dependency_command: ""
```

`flutter.project_directory` 可以是 `.`，也可以是 `Hearthio` 这样的规范化仓库
相对路径。`build.container_path` 必须位于该 Flutter 工程目录内。预检会解析
真实路径并拒绝目录穿越或通过符号链接逃出仓库。

Hearthio 的 Xcode target 名称仍是 `Runner`，因此
`app.bundle_ids[].target` 必须写 `Runner`；`Run-Release` 是共享 scheme，写在
`build.scheme`。首次设置 `upload_to_asc=false` 只是关闭上传，不会把 Archive
改成 Profile；云构建仍使用 `Run-Release` 和 `Release` configuration。

## Flutter SDK

中央 action 根据 `version`、`channel` 和 `architecture` 构造 Flutter 官方
`storage.googleapis.com/flutter_infra_release` 下载地址，并在解压前核对
`sdk_sha256`。SDK 安装在本次任务的隔离工作目录，任务结束时随工作目录删除。

更新 Flutter 版本时，应从 Flutter 官方 macOS releases manifest 取得对应架构
的 SHA-256，同时更新配置、锁文件并先执行不上传构建。

## 依赖与版本号

- `pubspec.lock` 必须提交。
- 存在 `ios/Podfile` 时，`ios/Podfile.lock` 也必须提交；依赖安装使用
  `pod install --deployment`。
- Archive 同时注入 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 和
  `FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`。
- 依赖安装若修改任何已跟踪文件，构建会失败，要求先提交锁定后的状态。

## 首次接入证据

第一次运行应设置 `upload_to_asc=false`。成功只表示精确远程 SHA 已完成签名
Archive、Export、IPA 内容检查和 Artifact 留存；它不表示 Apple 已接收或
TestFlight 已可测试。
