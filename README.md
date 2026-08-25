# iOS Multi-App Cloud Build System

面向多个独立 iOS App 仓库的 GitHub Actions 构建、签名、IPA 留存、App Store Connect 上传和 TestFlight 状态确认参考实现。

> 当前分支：`feature/flutter-support`。它是 Flutter iOS 专用分支，使用
> `schema_version: 2`；原生 iOS 的 v1 契约继续保留在 `main`。生产 App 必须
> 固定引用本分支的完整 commit SHA，不能直接引用分支名。

## 当前状态

| 部分 | 定位 | 可运行性 |
|---|---|---|
| `.github/actions/build-upload` | Flutter 正式参考实现 | 支持固定 Flutter SDK、嵌套工程和 Flutter 版本变量；仍需真实 App 接入验证 |
| `scripts/`、`schemas/` | composite action 的核心实现 | 可由 action 调用，CI 检查语法、配置、JWT、状态解析和安全归档 |
| `.github/workflows/core-self-test.yml` | 无真实密钥的 CI 自测 | Portable + macOS 工具链契约检查 |
| `examples/flutter-app-repository/` | Hearthio 结构的 Flutter 接入模板 | 必须补齐 ASC App ID、Environment、Secrets 和固定 SHA |
| `ios-multi-app-cloud-build-system-additions/` | Fastlane/Bitrise 备选思路 | **伪代码/草稿，不承诺复制后直接运行** |

仓库目前没有真实 Apple 签名、Archive、上传或 TestFlight 成功证据。CI 自测通过只证明静态接口和无密钥契约，不等于 App 已发布。

## 生产架构

每个 App 仓库负责自己的源码、非敏感配置、GitHub Environment 和 Secrets；本仓库只保存公共 action 和脚本。

```text
App repository production Environment
  ├── P12 + provisioning profiles
  ├── ASC P8 + Key ID + Issuer ID
  ├── .github/ios-build.yml（schema v2）
  └── thin release workflow
          └── pinned composite action SHA
                  └── Archive → IPA inspection → Artifact
                          → optional ASC upload → TestFlight state
```

之所以采用 composite action，是因为 caller 的 Environment secrets 不能通过 `workflow_call` 原样传给中央 reusable workflow。需要审批前不可读取的 App 密钥时，job 必须绑定 App 仓库自己的 Environment。

## 目录

```text
.github/actions/build-upload/action.yml    composite action
.github/workflows/core-self-test.yml       无密钥自测
schemas/ios-build-config.schema.json        配置 Schema
scripts/                                    预检、签名、Archive、Export、ASC 和清理
tests/                                      fixtures 与契约测试
examples/flutter-app-repository/            Flutter App 接入模板
ios-multi-app-cloud-build-system.md         完整实施与安全说明
ios-multi-app-cloud-build-system-additions/ Fastlane/Bitrise 草稿
```

## 接入步骤

1. 将 [`examples/flutter-app-repository/.github/ios-build.yml`](examples/flutter-app-repository/.github/ios-build.yml) 复制到 App 仓库并填写真实 ASC App ID，同时复核 Flutter 子目录、版本、SDK SHA-256、Target、Bundle ID、runner 和 Xcode。
2. 将 [`examples/flutter-app-repository/.github/workflows/ios-release.yml`](examples/flutter-app-repository/.github/workflows/ios-release.yml) 复制到 App 仓库。
3. 创建受保护的 GitHub Environment，例如 `hearthio-production`，添加：
   - `IOS_DISTRIBUTION_P12_BASE64`
   - `IOS_DISTRIBUTION_P12_PASSWORD`
   - `IOS_PROFILES_ARCHIVE_BASE64`
   - `ASC_API_KEY_P8_BASE64`
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
4. 把模板中的 `<PINNED_FULL_COMMIT_SHA>` 替换为经过审核的本仓库完整 commit SHA；不要使用 `main` 或可移动 Tag。
5. 先执行 `upload_to_asc=false`，只验证签名、Archive、Export、IPA 检查和 Artifact。
6. 再使用新的 build number 执行 ASC 上传，分别核对 Apple 接收、处理完成和 TestFlight 内测状态。

Flutter 分支的字段与 Donesome/Hearthio 目录示例见 [`docs/flutter-support.md`](docs/flutter-support.md)。

## 安全边界

- `.p12` 和 profiles 仅映射到签名步骤；P12 导入临时 Keychain 后立即删除原文件。
- `.p8` 仅在 `asc_increment` 解析 build number 或上传步骤局部映射，不传给依赖、Archive 或项目 Run Script。
- IPA 在调用 Apple 之前先保存为 GitHub Artifact。
- 所有外部 actions 固定完整 SHA。
- cleanup 使用 composite action 的 `if: always()`，只删除本次任务记录的 Keychain、profiles 和临时目录。
- App 构建会执行仓库中的 Run Script、Pods/SPM/Flutter 插件脚本；审批人必须审核此次运行的精确 ref 和 SHA。

## 本地自测

```bash
bash tests/run.sh
```

在 macOS 上还可以执行：

```bash
bash tests/macos-contract.sh
```

这些命令不使用 Apple 凭据，也不执行真实 Archive 或上传。

## Fastlane 与 Bitrise 草稿

`ios-multi-app-cloud-build-system-additions/` 用于说明如何把相同原则适配到 Fastlane/Bitrise。它们没有 App 工程、完整凭据接线或云端运行证据，因此只能作为设计起点。生产接入以根目录 composite action、Schema 和 App repository template 为准。

## 完整文档

见 [`ios-multi-app-cloud-build-system.md`](ios-multi-app-cloud-build-system.md)。

## License

[MIT](LICENSE)
