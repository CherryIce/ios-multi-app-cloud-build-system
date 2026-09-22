# iOS Multi-App Cloud Build System

面向多个独立 iOS App 仓库的 GitHub Actions 构建、签名、IPA 留存、App Store Connect 上传、TestFlight 状态确认、商店版本准备和可选自动提审参考实现。

## 当前状态

| 部分 | 定位 | 可运行性 |
|---|---|---|
| `.github/actions/build-upload` | 正式参考实现 | 已有脚本级自测；仍需使用真实 App、签名材料和 ASC 账号做接入验证 |
| `scripts/`、`schemas/` | composite action 的核心实现 | 可由 action 调用，CI 检查语法、配置、JWT、状态解析和安全归档 |
| `.github/workflows/core-self-test.yml` | 无真实密钥的 CI 自测 | Portable + macOS 工具链契约检查 |
| `examples/app-repository/` | App 接入伪代码/字段草稿 | 必须补齐真实工程值、Environment、Secrets 和固定 SHA；不承诺原样运行 |
| `ios-multi-app-cloud-build-system-additions/` | Fastlane/Bitrise 备选思路 | **伪代码/草稿，不承诺复制后直接运行** |

仓库目前没有真实 Apple 签名、Archive、上传、TestFlight、App Review 提交或自动发布成功证据。CI 自测通过只证明静态接口和无密钥契约，不等于 App 已发布。

## 生产架构

每个 App 仓库负责自己的源码、非敏感配置、GitHub Environment 和 Secrets；本仓库只保存公共 action 和脚本。

```text
App repository production Environment
  ├── P12 + provisioning profiles
  ├── ASC P8 + Key ID + Issuer ID
  ├── .github/ios-build.yml
  └── thin release workflow
          └── pinned composite action SHA
                  └── Archive → IPA inspection → Artifact
                          → optional ASC upload → TestFlight state
                          → optional App Store version → App Review submission
```

之所以采用 composite action，是因为 caller 的 Environment secrets 不能通过 `workflow_call` 原样传给中央 reusable workflow。需要审批前不可读取的 App 密钥时，job 必须绑定 App 仓库自己的 Environment。

## 目录

```text
.github/actions/build-upload/action.yml    composite action
.github/workflows/core-self-test.yml       无密钥自测
schemas/ios-build-config.schema.json        配置 Schema
scripts/                                    预检、签名、Archive、Export、ASC 和清理
tests/                                      fixtures 与契约测试
examples/app-repository/                    App 仓库接入草稿
ios-multi-app-cloud-build-system.md         完整实施与安全说明
ios-multi-app-cloud-build-system-additions/ Fastlane/Bitrise 草稿
```

## 接入步骤

1. 将 [`examples/app-repository/.github/ios-build.yml`](examples/app-repository/.github/ios-build.yml) 复制到 App 仓库并填写真实 Target、Bundle ID、runner 和 Xcode。
2. 将 [`examples/app-repository/.github/workflows/ios-release.yml`](examples/app-repository/.github/workflows/ios-release.yml) 复制到 App 仓库。
3. 将 [`examples/app-repository/.github/app-store-metadata.yml`](examples/app-repository/.github/app-store-metadata.yml) 复制到 App 仓库并填写非敏感本地化、版本更新说明和审核联系信息。
4. 创建受保护的 GitHub Environment，例如 `app-production`，添加：
   - `IOS_DISTRIBUTION_P12_BASE64`
   - `IOS_DISTRIBUTION_P12_PASSWORD`
   - `IOS_PROFILES_ARCHIVE_BASE64`
   - `ASC_API_KEY_P8_BASE64`
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `ASC_REVIEW_DEMO_ACCOUNT_NAME`、`ASC_REVIEW_DEMO_ACCOUNT_PASSWORD`（仅 App Review 需要登录时）
5. 把模板中的 `<PINNED_FULL_COMMIT_SHA>` 替换为经过审核的本仓库完整 commit SHA；不要使用 `main` 或可移动 Tag。
6. 先执行 `upload_to_asc=false`，只验证签名、Archive、Export、IPA 检查和 Artifact。
7. 再执行 `upload_to_asc=true`、`submit_to_review=false`，验证 Apple 处理完成、商店版本创建/复用和精确 build 绑定；文本、截图和预览仍默认不修改。
8. 需要修改文本时，先在 metadata YAML 中只声明要改的字段，再显式执行 `update_asc_text_metadata=true`；需要替换媒体时，只声明要替换的 locale/display type 集合并执行 `replace_asc_media=true`。
9. 最后显式执行 `submit_to_review=true`；`app_store.automatic_release=true` 时，审核通过后的发布由 App Store Connect 负责。

## 商店版本与提审

当 `app_store.enabled=true` 且 `upload_to_asc=true` 时，action 会：

1. 按 App、平台和 marketing version 创建或复用唯一 App Store version。
2. 拒绝创建不高于当前已发布版本的版本号。
3. 仅在 `update_asc_text_metadata=true` 时，同步配置文件中明确声明的 App 信息、版本本地化文本和可选 App Review 联系信息，并回读核验；未声明字段和 locale 保持不变。
4. 仅在 `replace_asc_media=true` 时，替换配置文件中明确声明的截图/App Preview locale + display type 集合；未声明集合保持不变。每个文件都完成预留、分片上传、MD5 提交、处理状态轮询、排序和回读核验。
5. 确认精确 ASC build 为 `VALID`，处理可选出口合规声明，并绑定该 build。
6. 仅在 `submit_to_review=true` 时创建或复用 Review Submission、加入版本并提交。
7. 同版本仍可编辑（包括 `READY_FOR_REVIEW`）时，复用该版本、绑定本次处理完成的 build，并按开关继续提审。
8. 同版本已经提审或已经发布时，且没有请求元数据/媒体变更，App Store 阶段以成功 no-op 结束；若明确请求了已不可编辑的变更，则失败并说明状态，不会静默跳过。

metadata YAML 是补丁清单：`name`、`subtitle`、`description`、`whats_new`、`keywords` 等字段都可按 locale 选择性声明；没有声明就不会覆盖。媒体替换对明确声明的集合是破坏性操作，脚本会先完成本地文件预检，再删除该集合的旧资源并上传新资源；因此必须使用受保护 Environment 审批。若 ASC 缺少其他必填字段，提审 API 会失败并保留 `app-store-status.json` 诊断。`automatic_release` 只设置审核后的发布策略，不代表 Apple 已审核通过，也不代表 App 已经在商店可见。

## 安全边界

- `.p12` 和 profiles 仅映射到签名步骤；P12 导入临时 Keychain 后立即删除原文件。
- `.p8` 仅在 `asc_increment`、上传和 App Store 提交步骤局部映射，不传给依赖、Archive 或项目 Run Script。
- App Review demo account 只能通过受保护 Secrets 传入，不能写入 metadata 文件或 Artifact。
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
