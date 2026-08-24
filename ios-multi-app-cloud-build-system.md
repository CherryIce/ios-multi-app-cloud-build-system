# iOS 多 App 通用云打包与 TestFlight 自动上传实施方案

> 文档版本：1.0  
> 更新日期：2026-08-22  
> 适用范围：多个独立 iOS App 仓库，共用一套 GitHub Actions 构建、签名、导出、上传及 App Store Connect 状态确认能力。

## 1. 结论

这套系统完全可以实现，并且适合做成真正的多 App 通用能力。每个 App 只维护自己的非敏感配置和独立签名凭据，中央仓库维护约 80%～90% 的公共打包逻辑。

最终目标是：开发或发布人员在 App 仓库中进入 GitHub Actions，选择受允许的分支或 Tag、版本号及上传策略，审批通过后，系统自动完成以下工作：

1. 固定并检出准确的源码提交。
2. 选择指定的 macOS runner 和 Xcode。
3. 安装 CocoaPods、SPM、Flutter 等项目依赖。
4. 恢复并校验签名证书、所有 provisioning profiles 和 App Store Connect API Key。
5. 生成唯一 build number。
6. Archive 并导出 App Store Connect 类型的 IPA。
7. 校验 IPA 内实际的 Bundle ID、版本、签名和嵌套扩展。
8. 无论后续上传是否成功，都保存必要产物和诊断日志。
9. 上传 IPA 到 App Store Connect。
10. 查询 Apple 的异步处理状态，区分“上传命令成功”“Apple 已接收”“处理完成”和“TestFlight 可测试”。
11. 清理 runner 中的临时 Keychain、证书、profiles 和 `.p8`。

推荐的生产架构不是“所有密钥都放在中央仓库”，而是由每个 App 仓库保管自己的签名材料，中央仓库只提供经过版本固定的执行逻辑。

## 2. 一个必须先明确的 GitHub 限制

原方案中的“每个 App 使用受保护 Environment，并把 Environment secrets 传给中央 reusable workflow”不能原样实现。

GitHub 官方说明：caller workflow 的 Environment secrets 不能通过 `on.workflow_call` 传给 reusable workflow；如果 called workflow 的 job 自己声明 `environment`，它使用的是 called workflow 所在仓库的 Environment，而不是 caller 仓库的 Environment。[G1]

因此有两种落地模式。

### 2.1 模式 A：Environment 安全优先，推荐用于正式发布

```text
App A workflow job（绑定 app-a-production Environment）
  ├── 审批通过后读取 App A Environment secrets
  ├── 检出 App A 源码
  └── 调用 ios-build-core 中央 composite action（固定 commit SHA）
          └── Archive → IPA → ASC → TestFlight 状态确认
```

特点：

- 构建 job 真实运行在 App 仓库上下文中，因此能够使用该 App 的 Environment 审批、分支限制和 Environment secrets。
- 公共 shell、Ruby/Python 工具及 composite action 保存在 `ios-build-core`。
- 中央 action 本身不保存任何 App 密钥。
- 每个 App 的 workflow 比纯 reusable workflow 稍厚，但仍然只需约几十行。
- 这是本文的默认推荐方案。

### 2.2 模式 B：reusable workflow 极简优先

```text
App A：Repository/Organization Secrets ─┐
App B：Repository/Organization Secrets ─┼→ ios-build-core reusable workflow
App C：Repository/Organization Secrets ─┘
```

特点：

- App 仓库只需要一个非常薄的调用 workflow。
- 密钥必须使用 App 仓库的 Repository secrets，或限制到指定仓库的 Organization secrets，再显式传给 called workflow。
- 不能把 caller 的 Environment secrets 直接传入 reusable workflow。
- 可以在调用前增加 Environment 审批 gate，但真正传给 reusable workflow 的仍是 Repository/Organization secrets，密钥本身不受该 Environment 的原生读取边界保护。
- 适合内部低风险构建，或组织已有其他审批和工作流变更管控的情况。

如果“每个 App 的生产密钥必须在审批前不可读取”是硬要求，应选择模式 A。

## 3. 系统边界

### 3.1 系统负责

- 构建输入检查。
- 源码提交锁定与记录。
- Xcode 和依赖准备。
- 本地手动签名材料的恢复、校验与清理。
- 多 Target、多 Bundle ID、多 profile 支持。
- Archive、IPA 导出、产物检查。
- App Store Connect 上传。
- Apple 异步处理状态轮询。
- 可选的 TestFlight 内测分组分发。
- 日志、元数据和构建产物留存。

### 3.2 系统默认不负责

- 自动创建 Apple Developer Program 账号。
- 自动接受 Apple 最新协议。
- 自动创建首次 App Store Connect App 记录。
- 自动修改业务代码来解决编译或签名问题。
- 自动提交 App Store 审核。
- 自动通过 TestFlight 外部测试审核。
- 自动决定出口合规、加密声明或隐私合规答案。
- 自动创建或轮换 Apple Distribution 证书，除非后续单独采用 Xcode cloud-managed signing 方案。

“上传到 TestFlight”在本文中默认表示：IPA 上传到 App Store Connect，Apple 处理完成，并达到内部测试可用状态。把 build 分配给外部测试组是另一阶段，首次外部测试还可能需要 Beta App Review。[A8]

## 4. 总体架构

```text
┌──────────────────────── App 仓库 A ────────────────────────┐
│ App 源码                                                     │
│ .github/workflows/ios-release.yml                            │
│ .github/ios-build.yml（非敏感配置）                           │
│ Environment: app-a-production                               │
│ Secrets: P12 / profiles / P8 / passwords                    │
└───────────────────────────┬─────────────────────────────────┘
                            │ 固定完整 commit SHA 调用
┌───────────────────────────▼─────────────────────────────────┐
│ ios-build-core                                               │
│ .github/actions/build-upload/action.yml                      │
│ scripts/preflight.sh                                         │
│ scripts/install-signing.sh                                   │
│ scripts/archive.sh                                           │
│ scripts/export.sh                                            │
│ scripts/inspect-ipa.sh                                       │
│ scripts/upload.sh                                            │
│ scripts/wait-asc.sh                                          │
│ scripts/cleanup.sh                                           │
└───────────────────────────┬─────────────────────────────────┘
                            │
                  ┌─────────▼──────────┐
                  │ App Store Connect │
                  │ Upload processing │
                  │ TestFlight status │
                  └────────────────────┘
```

`ios-build-core` 可以同时提供：

- 推荐的 composite action，供绑定 App Environment 的普通 job 调用。
- 可选的 reusable workflow，供不依赖 caller Environment secrets 的 App 使用。
- 通用脚本和 JSON Schema，确保两种入口最终执行同一套核心逻辑。

## 5. 仓库职责与目录建议

### 5.1 中央仓库 `ios-build-core`

```text
ios-build-core/
├── .github/
│   ├── actions/
│   │   └── build-upload/
│   │       └── action.yml
│   └── workflows/
│       ├── reusable-ios-release.yml
│       └── core-self-test.yml
├── schemas/
│   └── ios-build-config.schema.json
├── scripts/
│   ├── preflight.sh
│   ├── resolve-build-number.sh
│   ├── install-dependencies.sh
│   ├── install-signing.sh
│   ├── validate-profiles.sh
│   ├── make-export-options.sh
│   ├── archive.sh
│   ├── export.sh
│   ├── inspect-ipa.sh
│   ├── create-asc-jwt.rb
│   ├── upload.sh
│   ├── wait-asc.sh
│   └── cleanup.sh
├── tests/
│   ├── fixtures/
│   └── test-*.sh
├── CHANGELOG.md
└── README.md
```

中央仓库只保存通用逻辑、Schema、测试样例和文档，不保存任何真实 `.p12`、`.mobileprovision`、`.p8`、密码或真实 JWT。

### 5.2 每个 App 仓库

```text
app-a/
├── .github/
│   ├── workflows/
│   │   └── ios-release.yml
│   └── ios-build.yml
├── AppA.xcworkspace
├── Podfile / Package.resolved / pubspec.lock
└── 业务源码
```

每个 App 仓库负责：

- workspace/project、scheme、configuration。
- Team ID、Bundle IDs、App Store Connect App ID。
- 依赖类型和安装命令。
- 版本与 build number 策略。
- 每个 Target 的签名配置。
- 自己的 GitHub Environment 和 Secrets。

## 6. App 非敏感配置规范

建议每个 App 保存 `.github/ios-build.yml`：

```yaml
schema_version: 1

app:
  name: AppA
  team_id: ABCDE12345
  asc_app_id: "1234567890"
  primary_bundle_id: com.example.appa
  bundle_ids:
    - bundle_id: com.example.appa
      target: AppA
      profile_alias: app
    - bundle_id: com.example.appa.widget
      target: AppAWidget
      profile_alias: widget

build:
  container_type: workspace       # workspace 或 project
  container_path: AppA.xcworkspace
  scheme: AppA
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: cocoapods      # none / cocoapods / spm / flutter / custom
  dependency_command: ""

versioning:
  marketing_version_source: input
  build_number_strategy: asc_increment
  build_number_override_allowed: true

export:
  method: app-store-connect
  upload_symbols: true
  strip_swift_symbols: true

upload:
  enabled_by_default: true
  asc_key_type: team
  wait_level: testflight_internal_ready
  timeout_minutes: 45
  poll_interval_seconds: 30
  internal_beta_group_ids: []

artifacts:
  retention_days: 30
  keep_xcarchive: false
```

要求：

- 配置文件中只能出现非敏感数据。
- `asc_app_id` 是 App Store Connect 中 App 资源的数字 ID，不是 Bundle ID。
- `xcode_path` 必须是 runner 上真实存在的路径；GitHub runner 镜像会变化，应定期对照官方软件清单。[G8]
- 主 App、Widget、Notification Service、Share Extension、Watch App、App Clip 等必须逐一列出。
- `profile_alias` 只用于把 Bundle ID 与解码后的 profile 对应起来，不是 Secret 名称。
- 自定义依赖命令只能来自受保护分支中的配置，不能让 `workflow_dispatch` 接受任意 shell 字符串。

## 7. Secrets 设计

### 7.1 标准 Secret 名称

| Secret | 用途 | 是否每 App 独立 |
|---|---|---:|
| `IOS_DISTRIBUTION_P12_BASE64` | Apple Distribution 证书及私钥 | 是 |
| `IOS_DISTRIBUTION_P12_PASSWORD` | `.p12` 导出密码 | 是 |
| `IOS_PROFILES_ARCHIVE_BASE64` | 该 App 所有 `.mobileprovision` 的压缩包 | 是 |
| `ASC_API_KEY_P8_BASE64` | App Store Connect API 私钥 | 推荐独立 |
| `ASC_KEY_ID` | API Key ID | 是 |
| `ASC_ISSUER_ID` | Team API Key 的 Issuer ID | 是 |

临时 Keychain 密码无需长期保存为 Secret，应在 runner 上通过安全随机数即时生成。

本文的标准接口以 Team API Key 为基线，因此 `ASC_ISSUER_ID` 必填。若后续需要支持 Individual API Key，应新增显式的 `asc_key_type` 分支并单独验证上传工具兼容性，不能把两种 JWT 结构混用。

### 7.2 `.p12` 的准备

前提是 Mac Keychain 中存在 Apple Distribution 证书及其私钥。

操作：

1. 打开“钥匙串访问”。
2. 在“我的证书”中找到有效的 `Apple Distribution: ...`。
3. 展开证书，确认下面存在对应私钥；只有证书没有私钥不能用于 CI 签名。
4. 同时选中证书和私钥，导出为 `.p12`。
5. 设置一个高强度、唯一的导出密码。
6. 本地记录证书主题、SHA-256 指纹和过期时间，便于轮换审计。
7. Base64 编码后存入 App 的 Environment Secret：

```bash
base64 -i AppleDistribution.p12 | pbcopy
```

GitHub 官方的 iOS 签名示例也是把 `.p12` 和 provisioning profile 编码后存入 Secrets，再在 macOS runner 的临时 Keychain 中恢复。[G2]

### 7.3 provisioning profiles 的准备

每个需要独立签名的 Bundle ID 通常需要一个 App Store Connect distribution profile，例如：

```text
com.example.appa                      → 主 App profile
com.example.appa.widget               → Widget profile
com.example.appa.notification-service → Notification Service profile
```

在 Apple Developer 网站中：

1. 为每个 Target 确认存在显式 App ID。
2. 确认 App ID 的 Capabilities 与工程 Entitlements 一致。
3. 创建 `App Store Connect` 类型的 distribution profile。
4. 选择与 `.p12` 对应的 Apple Distribution certificate。
5. 下载所有 `.mobileprovision`。
6. 使用下面的命令逐个检查，不要只相信文件名：

```bash
security cms -D -i AppA.mobileprovision > AppA-profile.plist
/usr/libexec/PlistBuddy -c 'Print :Name' AppA-profile.plist
/usr/libexec/PlistBuddy -c 'Print :UUID' AppA-profile.plist
/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' AppA-profile.plist
/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' AppA-profile.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' AppA-profile.plist
```

7. 将所有 profiles 打包并编码：

```bash
tar -czf ios-profiles.tar.gz ./*.mobileprovision
base64 -i ios-profiles.tar.gz | pbcopy
```

Apple 的 App Store Connect profile 使用显式 App ID，并包含一个 distribution certificate；profile 的 App ID、能力、证书和有效期都必须与实际构建匹配。[A2]

#### GitHub Secret 大小限制

单个 GitHub Secret 最大为 48 KB。[G6] 多个 profiles 压缩并 Base64 后可能超过限制。处理顺序建议：

1. 先检查压缩包 Base64 后的字节数。
2. 未超过 48 KB 时使用 `IOS_PROFILES_ARCHIVE_BASE64`。
3. 超过时，把 profiles 拆成多个明确命名的 Secret，并由 App workflow 在调用中央 action 前组合到临时目录。
4. 如果 profiles 数量很多，可把压缩包使用 GPG 对称加密后提交到私有 App 仓库，只把解密口令存入 Environment Secret；GitHub 官方将这种方式作为大 Secret 的替代方案，但这类内容不会自动被日志脱敏，因此脚本必须禁止输出明文。[G7]

不要把 `.p12` 或 `.p8` 放进仓库，即使仓库是私有的。

### 7.4 App Store Connect `.p8` 的准备

用途必须分清：

- `.p12 + profile`：用于对 App 和扩展签名。
- `.p8 + Key ID + Issuer ID`：用于生成 JWT、上传和查询 App Store Connect。
- `.p8` 不能代替签名证书或 provisioning profile。

创建 Team API Key：

1. App Store Connect → Users and Access → Integrations。
2. 首次使用时，由 Account Holder 申请 App Store Connect API 访问。
3. 进入 Team Keys，创建新 Key。
4. 只授予满足上传和查询要求的最低角色；Apple 当前允许 Account Holder、Admin、App Manager 或 Developer 上传 build。[A1]
5. 下载 `.p8`。私钥只能下载一次，应立即安全备份。
6. 记录 Key ID 和 Issuer ID。
7. 编码 `.p8` 并存入对应 App Environment Secret：

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

Team Key 默认可跨 Team 中所有 App，不能按单个 App 隔离。若组织的权限模型允许，可评估为专门 CI 用户限制 App 访问并使用 Individual API Key；但 Individual Key 的 JWT 使用 `sub: user`，不使用 `iss`，而且上传工具的认证参数需要独立验证。因此第一版应只启用已验证的 Team Key 路径，把 Individual Key 作为后续适配器，而不是静默兼容。[A3][A5]

### 7.5 Secret 轮换

至少维护以下信息：

| 凭据 | 检查内容 | 建议动作 |
|---|---|---|
| Apple Distribution cert | 到期时间、是否撤销、私钥是否存在 | 到期前 30～60 天轮换 |
| provisioning profiles | 到期时间、证书、App ID、Entitlements | 证书或能力变化后重新生成 |
| ASC API Key | 使用人、角色、最后使用时间 | 定期轮换；疑似泄露立即撤销 |

轮换时先在非生产演练构建中验证新凭据，再替换 production Environment secrets。

## 8. Apple 侧一次性准备

每个 App 上线自动化前必须完成：

1. Apple Developer Program 会员有效。
2. 最新协议已由有权限人员接受。
3. 主 App 和所有扩展的 App IDs 已创建，Capabilities 正确。
4. App Store Connect 中已经创建 App 记录；Apple 要求首次上传前先有 App 记录。[A4]
5. App 记录的 Bundle ID 与主 App 完全一致。
6. Apple Distribution 证书有效。
7. 所有 App Store Connect profiles 有效。
8. App Store Connect API Key 已创建并具有最低必要权限。
9. 如需自动分发 TestFlight，内部测试组已经创建并记录 group ID。
10. 出口合规信息已确定。若 App 不使用或仅使用豁免加密，可由业务和法务确认后在 Info.plist 中正确设置，不能由 CI 猜测。

## 9. GitHub 侧一次性准备

### 9.1 建立并保护 `ios-build-core`

1. 创建私有中央仓库。
2. 在 Settings → Actions → General 中允许组织内指定私有仓库访问中央 actions/workflows。[G5]
3. 保护默认分支，至少要求 Pull Request、Reviewer 和状态检查。
4. 使用 `CODEOWNERS` 保护以下路径：

```text
/.github/ @release-engineering
/scripts/ @release-engineering
/schemas/ @release-engineering
```

5. 给中央 action/reusable workflow 发布语义化 Tag，但 App 仓库生产调用必须固定到经过审核的完整 commit SHA。完整 SHA 是不可变引用，比可移动 Tag 或分支安全。[G4]
6. 为中央脚本建立无真实密钥的 fixture 测试，例如无效 profile、过期 profile、Bundle ID 不匹配、多扩展映射和 ASC 状态 JSON 解析。

### 9.2 每个 App 建立 production Environment

例如：

```text
app-a-production
app-b-production
app-c-production
```

对每个 Environment：

1. 配置 Required reviewers。
2. 开启 Prevent self-review。
3. 禁止管理员绕过保护规则，若组织流程允许。
4. 只允许受保护分支和发布 Tag，例如 `main`、`release/*`、`ios-v*`。
5. 添加该 App 自己的 Secrets。
6. 添加非敏感 Environment variables 时只使用 `vars`，不要把秘密放入 variables。

GitHub 的 Environment 保护规则在 job 启动和读取 Environment secrets 之前生效，可限制审批者以及允许部署的分支和 Tag。[G3]

注意：部分私有仓库的 Environment 审批能力取决于 GitHub 套餐，实施前应在实际组织中确认可用性。[G3]

### 9.3 限制 workflow 改动

每个 App 建议保护：

```text
/.github/workflows/ios-release.yml @release-engineering
/.github/ios-build.yml             @release-engineering
```

同时设置：

- 禁止从 `pull_request`、fork 或任意外部分支触发带签名密钥的 job。
- `GITHUB_TOKEN` 默认只给 `contents: read`；未显式授予的权限设为 `none`。[G9]
- 组织层面限制可使用的第三方 actions。
- 所有第三方 actions，包括 `actions/checkout` 和 `actions/upload-artifact`，固定到审核过的完整 SHA。
- 不允许用户通过 workflow input 传入任意命令、路径遍历内容或未校验的 runner label。

## 10. 推荐调用 workflow 骨架

下面只展示结构。`<FULL_COMMIT_SHA>` 必须替换为真实的完整 SHA，不能直接复制占位符运行。

```yaml
name: iOS Release

on:
  workflow_dispatch:
    inputs:
      marketing_version:
        description: CFBundleShortVersionString, for example 2.3.0
        required: true
        type: string
      build_number:
        description: Optional CFBundleVersion override
        required: false
        type: string
      upload_to_asc:
        description: Upload to App Store Connect
        required: true
        default: true
        type: boolean

permissions:
  contents: read

concurrency:
  group: ios-production-${{ github.repository }}
  cancel-in-progress: false
  queue: max

jobs:
  release:
    environment: app-a-production
    runs-on: macos-26
    timeout-minutes: 90

    steps:
      - name: Checkout exact source
        uses: actions/checkout@<FULL_COMMIT_SHA>
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Build, export and upload
        uses: your-org/ios-build-core/.github/actions/build-upload@<FULL_COMMIT_SHA>
        with:
          config_path: .github/ios-build.yml
          marketing_version: ${{ inputs.marketing_version }}
          build_number: ${{ inputs.build_number }}
          upload_to_asc: ${{ inputs.upload_to_asc }}
          ios_distribution_p12_base64: ${{ secrets.IOS_DISTRIBUTION_P12_BASE64 }}
          ios_distribution_p12_password: ${{ secrets.IOS_DISTRIBUTION_P12_PASSWORD }}
          ios_profiles_archive_base64: ${{ secrets.IOS_PROFILES_ARCHIVE_BASE64 }}
          asc_api_key_p8_base64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
```

说明：

- `workflow_dispatch` workflow 文件必须存在于默认分支，之后由 GitHub UI、CLI 或 API 选择运行 ref；源码应直接使用此次运行的 `github.ref`/`github.sha`，不要再接受第二个可与部署策略脱节的源码 ref 输入。[G9]
- 中央脚本必须再次验证 `github.ref`，只接受配置允许的受保护分支或发布 Tag。
- `concurrency` 防止同一 App 同时计算出重复 build number；当前 GitHub 还支持 `queue: max` 保留等待任务。[G9]
- 如果所在 GitHub 实例尚不支持 `queue: max`，删除该字段，但要接受默认最多保留一个 pending run 的行为。
- job 绑定 App 自己的 Environment，所以 Secrets 只有在审批通过后才进入 runner。
- Secret 通过 action inputs 传入，中央 `action.yml` 再把每个 Secret 只映射给需要它的内部步骤；禁止把全部 Secret 设置为整个 action 或整个 job 的全局环境变量。

## 11. 中央 action 的输入、输出和失败原则

### 11.1 必需输入

| 输入 | 校验 |
|---|---|
| `config_path` | 必须在仓库内、存在、通过 Schema |
| `marketing_version` | 只接受项目允许的版本格式 |
| `build_number` | 空或只接受项目允许的数字格式 |
| `upload_to_asc` | Boolean |

### 11.2 标准输出

| 输出 | 示例 |
|---|---|
| `source_sha` | 完整 Git SHA |
| `marketing_version` | `2.3.0` |
| `build_number` | `1042` |
| `archive_path` | runner 临时路径 |
| `ipa_path` | runner 临时路径 |
| `ipa_sha256` | SHA-256 |
| `asc_build_id` | Apple build resource ID |
| `asc_upload_state` | `COMPLETE` |
| `asc_processing_state` | `VALID` |
| `testflight_internal_state` | `READY_FOR_BETA_TESTING` |

### 11.3 失败原则

- 输入、签名或 Bundle ID 不匹配：立即失败，不尝试“自动修正”。
- Archive 或 export 失败：保留日志，不上传。
- IPA 本地校验失败：保留 IPA 和日志，但禁止上传。
- 上传网络异常：先查询 ASC 是否已经收到同一版本/build，再决定是否重试。
- Apple 明确返回 `FAILED`、`INVALID` 或 `PROCESSING_EXCEPTION`：任务失败并保存 Apple 返回的错误信息。
- 超时仍在 `PROCESSING`：标记为“上传已接受，但处理状态超时”，不能报告 TestFlight 已可用。
- 清理步骤必须使用 `if: always()` 或 shell `trap`，不因前一步失败而跳过。

## 12. 完整执行流程

以下每一步都写明“做什么、怎么做、成功判据和失败处理”。

### 步骤 1：验证触发来源和输入

做什么：确认此次发布来自允许的人、分支或 Tag，输入格式安全。

怎么做：

1. 依靠 Environment deployment branch/tag policy 做第一层限制。
2. 脚本再次检查 `github.ref` 是否匹配白名单，并确认该 ref 解析到本次 `github.sha`。
3. 禁止 PR 和 fork 事件进入签名 job。
4. 使用 JSON Schema 校验 `.github/ios-build.yml`。
5. 检查版本号、build number、路径、scheme 和 Xcode path 中没有换行、shell 元字符或路径穿越。

成功判据：所有输入通过 Schema 和白名单，Environment 审批完成。

失败处理：停止任务，不解码任何 Secret。

### 步骤 2：固定源码提交

做什么：把用户选择的分支或 Tag 解析成一个不可变的 Git SHA。

怎么做：

1. 由 `actions/checkout` 检出 workflow run 已锁定的 `github.sha`，不再从任意文本 input 解析另一个 ref。
2. 获取并记录 `git rev-parse HEAD`。
3. 若输入是 Tag，检查 Tag 指向的实际 commit。
4. 把 `github.ref`、完整 SHA、触发者、workflow run URL 写入 `build-metadata.json`。
5. `persist-credentials: false`，避免后续脚本意外使用 checkout 凭据写仓库。

成功判据：工作区 HEAD 与记录的 `source_sha` 一致。

失败处理：停止构建，不接受“脚本已触发”作为源码确认。

### 步骤 3：选择并验证 runner 与 Xcode

做什么：使用可复现的 macOS/Xcode 组合。

怎么做：

1. `runs-on` 使用明确的 macOS 标签，不使用不可控的 `macos-latest`。
2. 检查 `xcode_path` 是否存在。
3. 设置：

```bash
export DEVELOPER_DIR="/Applications/Xcode_<exact-version>.app/Contents/Developer"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
swift --version
```

4. 将结果写入构建元数据和日志。
5. 定期检查 GitHub runner 镜像软件清单，因为预装 Xcode 会随镜像生命周期变化。[G8]

成功判据：实际 Xcode version/build 与配置允许值完全一致，iPhoneOS SDK 可用。

失败处理：提示需要更新 runner 或 Xcode 配置，不自动降级到其他版本。

### 步骤 4：安装依赖

做什么：根据 App 配置准备 CocoaPods、SPM、Flutter 或自定义依赖。

怎么做：

#### CocoaPods

1. 若有 `Gemfile.lock`，使用锁定的 Bundler/CocoaPods：

```bash
bundle config set path vendor/bundle
bundle install --jobs 4 --retry 3
bundle exec pod install --deployment
```

2. 要求 `Podfile.lock` 已提交。
3. 构建 `.xcworkspace`，不是 `.xcodeproj`。

#### Swift Package Manager

```bash
xcodebuild -resolvePackageDependencies \
  -workspace App.xcworkspace \
  -scheme App
```

要求 `Package.resolved` 已提交并与项目策略一致。

#### Flutter

1. 选择项目锁定的 Flutter 版本。
2. 执行 `flutter pub get`。
3. 按项目既有方式生成 iOS 配置和 Pods。
4. 最终仍使用 `Runner.xcworkspace` 或项目指定 workspace Archive。

#### Custom

自定义命令只能写在受保护配置或中央脚本的已审核 adapter 中，不从用户输入直接执行。

成功判据：依赖安装退出码为 0，lockfile 未被意外修改。

失败处理：保存依赖日志；若 lockfile 发生变化则失败，要求在源码仓库中先修复并提交。

### 步骤 5：建立临时敏感目录和清理钩子

做什么：所有签名材料只存在于 runner 临时区域。

怎么做：

1. 在 `$RUNNER_TEMP` 下创建权限为 `700` 的任务目录。
2. 提前注册 `trap` 或最终 `always()` cleanup。
3. 禁止 `set -x`，避免命令展开时输出 Secret。
4. 对需要额外脱敏的值使用 GitHub `::add-mask::`。
5. 任何文件路径只允许落在本次任务的显式临时目录内。
6. action inputs 中的 Secret 只在需要它的内部步骤映射为环境变量；完成解码或导入后立即 `unset`，不能让后续 `xcodebuild`、Pod script phase 或项目自定义脚本继承原始 Secret 值。

成功判据：临时目录存在、权限正确、清理钩子已注册。

失败处理：立即执行清理并退出。

### 步骤 6：解码并预检 `.p12` 和 profiles

做什么：在导入 Keychain 之前检查签名文件是否可解析、是否过期、是否属于正确 App。ASC `.p8` 延迟到上传阶段才解码，避免它暴露给 App 构建脚本。

怎么做：

1. 使用 macOS Base64 解码到临时文件：

```bash
printf '%s' "$IOS_DISTRIBUTION_P12_BASE64" | base64 -D > distribution.p12
printf '%s' "$IOS_PROFILES_ARCHIVE_BASE64" | base64 -D > profiles.tar.gz
```

2. 只向预先创建的空临时目录解压，拒绝绝对路径和 `..` 成员。
3. 用 `openssl pkcs12` 检查 `.p12` 密码、证书主题和到期日；密码使用环境变量传入，不能直接拼接进命令行或日志。
4. 用 `security cms -D -i` 解析每个 profile。
5. 校验：

   - `ExpirationDate` 晚于当前时间，并保留建议的最小余量。
   - `TeamIdentifier` 等于配置的 Team ID。
   - `application-identifier` 的 Team 前缀和 Bundle ID 正确。
   - profile 为 distribution/App Store Connect 用途，而不是 Development 或 Ad Hoc。
   - profile 中的 Entitlements 覆盖 Target 所需 Entitlements。
   - 配置中的每个 Bundle ID 恰好匹配一个 profile。
   - 不允许多余的未知 profile 静默参与签名。

6. 解码和导入完成后立即清除原始 Base64 和 `.p12` 密码环境变量；运行 Archive 前不应存在 `.p8` 文件。

成功判据：证书、所有 Bundle ID 与 profiles 一一匹配且均有效。

失败处理：输出不含秘密的差异摘要，例如“Widget profile 的 Team ID 不匹配”，然后清理并停止。

### 步骤 7：创建临时 Keychain 并安装 profiles

做什么：让 `codesign` 和 `xcodebuild` 能找到本次任务的签名身份。

怎么做：

1. 生成随机 Keychain 密码。
2. 创建、解锁临时 Keychain。
3. 导入 `.p12`。
4. 执行 `security set-key-partition-list`，允许 Apple 签名工具非交互访问私钥。
5. 临时把该 Keychain 加入 user keychain search list，并保留原列表供清理时恢复。
6. 使用 `security find-identity -v -p codesigning` 确认至少存在预期的 Apple Distribution identity。
7. 把 profiles 按解析出的 UUID 安装到：

```text
~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision
```

8. 记录本次安装的 UUID 清单，只删除本次安装的文件。

成功判据：签名 identity 可见，所有 profiles 均按 UUID 安装。

失败处理：恢复原 Keychain search list，删除本次 Keychain 和 profiles，停止构建。

GitHub-hosted runner 会在 job 结束后销毁虚拟机，但仍应显式清理；如果改用 self-hosted runner，显式清理是必须项，因为 Keychain 和 profiles 可能残留。[G2]

### 步骤 8：再次校验工程签名设置

做什么：确认工程 Release 配置不会使用错误 Team、Bundle ID 或自动生成的其他 profile。

怎么做：

1. 使用 `xcodebuild -showBuildSettings` 读取 scheme 关联 Target 的构建设置。
2. 检查 `PRODUCT_BUNDLE_IDENTIFIER`、`DEVELOPMENT_TEAM`、`CODE_SIGN_STYLE`、`CODE_SIGN_IDENTITY`。
3. 多 Target 项目必须在工程或受保护的 Release `.xcconfig` 中配置每个 Target 的签名规则。
4. 中央系统不应通过一个全局 `PROVISIONING_PROFILE_SPECIFIER` 强行覆盖所有 Target，因为主 App 和扩展通常使用不同 profiles。
5. Export 阶段再通过 Bundle ID → profile Name 映射明确指定每个 profile。

成功判据：工程发现的签名 Target 集合与配置文件中的 Bundle ID 集合一致。

失败处理：列出缺失或多出的 Target，不进入 Archive。

### 步骤 9：确定版本号和 build number

做什么：产生 App Store Connect 可接受且不会重复的 `CFBundleShortVersionString` 和 `CFBundleVersion`。

推荐策略：

1. `marketing_version` 由人工输入并校验。
2. `build_number` 若人工指定，则先查询 ASC 确认同一 App、版本和 build number 尚不存在。
3. 若未指定，使用 API 查询该 App 和 marketing version 的最大纯整数 build number，再加 1。
4. 整个过程受 App 级 concurrency lock 保护。
5. 仍需考虑 Xcode Cloud、人工上传等外部通道；上传前再做一次唯一性查询。
6. 推荐只使用单调递增整数，避免复杂版本比较。

构建时可通过命令行覆盖，不修改源码：

```bash
MARKETING_VERSION="$MARKETING_VERSION" \
CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
```

成功判据：值符合项目规则，并且 ASC 中没有同一 App 的重复 build number。

失败处理：若发现冲突，重新分配一次；连续冲突则停止并提示存在其他发布通道或锁失效。

Apple 使用 Bundle ID 和版本号把上传关联到 App/版本记录，并用 build string 唯一标识 build。[A1]

### 步骤 10：执行 Archive

做什么：生成签名的 `.xcarchive`。

怎么做：

1. 为本次任务创建唯一的 DerivedData、Archive 和 result bundle 路径。
2. 使用 `set -o pipefail`，确保 `tee` 不吞掉 `xcodebuild` 退出码。
3. workspace 示例：

```bash
set -o pipefail
xcodebuild \
  -workspace AppA.xcworkspace \
  -scheme AppA \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  -resultBundlePath "$ARCHIVE_RESULT_PATH" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive | tee "$ARCHIVE_LOG_PATH"
```

4. project 模式把 `-workspace` 换为 `-project`。
5. 不使用模拟器 destination 证明发布 Archive。
6. Archive 后检查 `<Archive>.xcarchive/Info.plist` 和主 `.app` 是否存在。

成功判据：`xcodebuild` 返回 0、Archive 存在、Archive 中的版本和 build number 正确。

失败处理：保存 `.xcresult` 和经过脱敏的日志；不执行 export 或 upload。

### 步骤 11：生成 `ExportOptions.plist`

做什么：明确告诉 Xcode 使用 App Store Connect 导出方式和各 Bundle ID 对应的 profile。

示例结构：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>ABCDE12345</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.example.appa</key>
    <string>AppA AppStore Profile</string>
    <key>com.example.appa.widget</key>
    <string>AppA Widget AppStore Profile</string>
  </dict>
  <key>uploadSymbols</key>
  <true/>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
```

要求：

- `provisioningProfiles` 必须由已解析 profile 的真实 `Name` 自动生成，不相信用户随意输入。
- 每个 Bundle ID 都必须存在映射。
- 在所选 Xcode 上先检查 `xcodebuild -help` 支持的 export option；较老 Xcode 可能使用旧的 `app-store` method，不能跨版本盲目复用。
- 生成后执行 `plutil -lint`。

成功判据：plist 合法，Team ID 和映射与预检结果一致。

失败处理：停止 export，输出不含凭据的配置差异。

### 步骤 12：导出 IPA

做什么：从 `.xcarchive` 导出用于 App Store Connect 的 IPA。

怎么做：

```bash
set -o pipefail
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
  | tee "$EXPORT_LOG_PATH"
```

Apple 的标准导出流程使用 `xcodebuild -exportArchive`、Archive 路径、导出目录和 ExportOptions plist。[A7]

成功判据：命令返回 0，导出目录中恰好找到预期 IPA，并计算 SHA-256。

失败处理：保存 export 日志和 distribution logs，不上传。

### 步骤 13：检查导出的 IPA

做什么：验证“实际要上传的文件”，避免只验证工程配置。

怎么做：

1. 解压 IPA 到本次临时目录。
2. 找到 `Payload/*.app`。
3. 检查主 App：

   - `CFBundleIdentifier`
   - `CFBundleShortVersionString`
   - `CFBundleVersion`
   - `ApplicationIdentifierPrefix`
   - `embedded.mobileprovision`
   - 实际 codesign authority 和 TeamIdentifier

4. 遍历 `PlugIns/*.appex`、Watch、App Clips 等嵌套 bundle，逐一执行同样检查。
5. 使用 `codesign --verify --strict --verbose=4` 验证签名。
6. 比较 IPA 内 profile Entitlements 与实际签名 Entitlements。
7. 生成不含秘密的 `ipa-inspection.json`。

成功判据：IPA 中所有 bundle、版本、Team、profile 和签名均与配置一致。

失败处理：保留 IPA 供诊断，但设置 `upload_allowed=false` 并使任务失败。

### 步骤 14：保存 Artifact

做什么：确保即使 Apple 上传失败，也能下载 IPA 和诊断证据。

建议保存：

```text
AppA-2.3.0-1042.ipa
AppA-2.3.0-1042.dSYM.zip
build-metadata.json
ipa-inspection.json
archive.log
export.log
upload.log（脱敏）
archive.xcresult
export/distribution logs
```

`.xcarchive` 体积很大，默认不保存；只有确有符号、重导出或审计需求时才短期保存。

Artifact 上传步骤应使用 `if: always()`。不得上传：

- `.p12`
- `.p8`
- 解码后的 profiles 压缩包
- 临时 Keychain
- JWT
- 包含明文 Secret 的日志

GitHub Artifact 默认保留期可在仓库/组织层配置，也可以由上传 action 为单个 Artifact 指定 retention；生产 IPA 的保留期应与内部安全和审计政策一致。[G10]

成功判据：Artifact 页面能看到预期文件和 SHA-256，敏感文件扫描通过。

失败处理：如果 IPA 已生成但 Artifact 保存失败，默认停止上传，避免唯一产物只存在于即将销毁的 runner。

### 步骤 15：上传 IPA 到 App Store Connect

做什么：先验证包，再向 Apple 上传。

怎么做：

1. 把 `.p8` 临时安装为 `AuthKey_<KEY_ID>.p8`，放到上传工具要求的私有 Key 目录。
2. 仅在 IPA 检查通过且 Artifact 已保存后，才把 `ASC_API_KEY_P8_BASE64` 映射到该步骤，解码 `.p8` 并用 OpenSSL 检查它是可解析的 EC private key；随后立即清除原始 Base64 环境变量。
3. 先执行验证：

```bash
xcrun altool --validate-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
```

4. 验证成功后上传：

```bash
xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
```

5. 记录上传工具版本、请求标识、开始/结束时间和脱敏输出。
6. 不把上传命令返回 0 直接当成 TestFlight 完成。

Apple 当前支持通过 Xcode、Transporter、altool 或 App Store Connect API 上传 build；API/JWT 可用于自动化认证。[A1]

成功判据：上传工具确认 Apple 接收上传请求，并取得可追踪的请求信息。

失败处理：

- 明确的认证、版本重复、Bundle ID 或签名错误：直接失败。
- 网络中断或响应不确定：先执行步骤 16 查询同一 App、版本和 build number 是否已出现，再决定是否重传。
- 不能因为网络异常立即更换 build number重打；Apple 可能已经接收了原 IPA。

### 步骤 16：轮询 App Store Connect 异步状态

做什么：确认 Apple 实际接收并处理了对应 build。

怎么做：

#### 16.1 生成短期 JWT

Team API Key 的 JWT：

- Header：`alg=ES256`、`kid=<Key ID>`。
- Payload：`iss=<Issuer ID>`、`iat`、`exp`、`aud=appstoreconnect-v1`。
- 大多数请求的 token lifetime 不得超过 20 分钟；长轮询应周期性重新生成，而不是使用长期 JWT。[A5]

Individual Key 使用 `sub=user`，不使用 `iss`，实现时必须分开处理。

JWT 只存内存或临时变量，加入日志 mask，不写入 Artifact。

#### 16.2 查询 build upload

调用：

```text
GET /v1/apps/{asc_app_id}/buildUploads
  ?filter[cfBundleShortVersionString]={marketing_version}
  &filter[cfBundleVersion]={build_number}
  &filter[platform]=IOS
  &include=build
```

`BuildUploadState` 可能为：

- `AWAITING_UPLOAD`
- `PROCESSING`
- `FAILED`
- `COMPLETE`

Apple 提供按 App、marketing version、build number 和 platform 过滤 build uploads 的接口。[A9][A10]

#### 16.3 查询 build processing state

当 build resource 已出现后，检查：

```text
GET /v1/builds?filter[app]={asc_app_id}&filter[version]={build_number}
```

并确认关联的 prerelease version 等于 `marketing_version`。`processingState` 可能为：

- `PROCESSING`
- `FAILED`
- `INVALID`
- `VALID`

#### 16.4 查询 TestFlight 内测状态

取得 build ID 后查询其 `buildBetaDetail`，确认 `internalBuildState`：

- `PROCESSING`
- `PROCESSING_EXCEPTION`
- `MISSING_EXPORT_COMPLIANCE`
- `READY_FOR_BETA_TESTING`
- `IN_BETA_TESTING`
- `EXPIRED`
- `IN_EXPORT_COMPLIANCE_REVIEW`

`READY_FOR_BETA_TESTING` 或 `IN_BETA_TESTING` 才能证明内部 TestFlight 已可用。[A6]

#### 16.5 轮询策略

建议：

- 初始等待：30 秒。
- 轮询间隔：30 秒，遇到 429 使用响应头和指数退避。
- 默认总超时：45 分钟，可按 App 调整。
- 每轮重新确认 App ID、marketing version 和 build number，不能只取“最新 build”。
- 每隔不超过 20 分钟刷新 JWT。
- 保存最终非敏感 JSON 摘要，不保存 Authorization header。

成功判据由 `wait_level` 决定：

| `wait_level` | 成功条件 |
|---|---|
| `upload_accepted` | 上传工具确认 Apple 接收 |
| `asc_appeared` | 精确版本/build 的 upload 或 build 资源出现 |
| `processing_complete` | BuildUpload `COMPLETE` 且 Build `VALID` |
| `testflight_internal_ready` | `READY_FOR_BETA_TESTING` 或 `IN_BETA_TESTING` |

推荐 production 默认使用 `testflight_internal_ready`。

失败处理：

- `FAILED`、`INVALID`、`PROCESSING_EXCEPTION`：立即失败并输出 Apple 返回的诊断。
- `MISSING_EXPORT_COMPLIANCE`：报告“build 已处理但需要出口合规处理”，不能声称 TestFlight 已可测试。
- 超时：报告最后确认的状态以及 ASC build/upload ID，不把超时写成上传失败，也不写成成功。

Apple 明确说明 build 上传后需要在其系统中异步处理，处理完成前可能不会出现在 App Store Connect；官方也将 Build Upload 状态区分为 Processing、Failed 和 Complete。[A1][A11]

### 步骤 17：可选地分配 TestFlight 测试组

做什么：把已经可测试的 build 分配到指定内部测试组。

怎么做：

1. 只在 `internalBuildState` 已就绪后执行。
2. 使用配置中固定的 beta group IDs，禁止由任意 workflow input 提供未知 ID。
3. 调用 App Store Connect API 建立 build 与 beta group 的关系。
4. 再查询关系确认 build 已加入目标组。
5. 是否自动通知测试者由单独配置控制。

外部测试需额外准备 Beta App Review 信息，首次 build 可能需要审核，不能与内部测试使用同一成功判据。[A8]

成功判据：API 查询确认目标 build 已属于配置的内部测试组。

失败处理：构建和上传状态仍可记录为成功，但整个“自动分发”阶段标记失败或部分成功，不能隐藏分组失败。

### 步骤 18：清理

做什么：无论成功、失败、取消或超时，都移除敏感材料。

怎么做：

1. 恢复原 user keychain search list。
2. 删除本次临时 Keychain。
3. 删除本次安装的 provisioning profile UUID 文件。
4. 删除 `.p12`、`.p8`、profiles 解压目录和 JWT 临时文件。
5. 删除临时 DerivedData 和未要求保留的 `.xcarchive`。
6. 检查已上传 Artifact 清单不包含敏感文件名。

成功判据：临时敏感目录不存在，Keychain 和 profiles 恢复到任务前状态。

失败处理：cleanup 失败应产生显著告警；self-hosted runner 应进入隔离状态，人工清理前不再接收签名任务。

## 13. 发布结果的证据等级

必须把结果按层级报告，不能把前一层冒充后一层。

| 等级 | 含义 | 最低证据 |
|---:|---|---|
| 1 | 源码已锁定 | `github.ref` + 完整 `github.sha` |
| 2 | Archive 成功 | `xcodebuild archive` 返回 0 + `.xcarchive` |
| 3 | IPA 导出成功 | IPA 存在 + SHA-256 + 本地检查通过 |
| 4 | Artifact 已保存 | GitHub Artifact ID/URL + digest |
| 5 | Apple 接收上传 | 上传工具成功和请求标识 |
| 6 | ASC 中出现对应 build | 精确 App/version/build 的 API 资源 |
| 7 | Apple 处理完成 | BuildUpload `COMPLETE` + Build `VALID` |
| 8 | TestFlight 内测可用 | `READY_FOR_BETA_TESTING` 或 `IN_BETA_TESTING` |
| 9 | 已分发测试组 | build 与目标 beta group 关系确认 |

标准成功摘要示例：

```text
Source: tag ios-v2.3.0 → 7a1b...f92c
Archive: succeeded
IPA: AppA-2.3.0-1042.ipa
SHA-256: ...
Artifact: uploaded, retention 30 days
Apple upload: accepted
ASC Build ID: ...
Build upload state: COMPLETE
Processing state: VALID
TestFlight internal state: READY_FOR_BETA_TESTING
Tester group assignment: not requested
```

## 14. 安全基线

正式版本至少满足：

- 只允许 `workflow_dispatch`、受保护分支或发布 Tag。
- production job 使用 Environment 审批并防止自审批。
- 每个 App 的 `.p12`、profiles、`.p8` 独立保存。
- 中央仓库不保存任何 App 的真实密钥。
- 中央 action 固定完整 commit SHA。
- 所有第三方 actions 固定完整 commit SHA。
- `GITHUB_TOKEN` 最小权限，通常只需 `contents: read`。
- 不在 PR/fork 事件中暴露签名 Secrets。
- 不执行用户输入的任意 shell。
- 不在日志中打印 Secret、JWT、Authorization header 或完整 profile 内容。
- 每个 App 使用 concurrency lock，生产任务不相互取消。
- Artifact 先于 ASC 上传保存。
- Secret 解码、签名、上传后均执行显式清理。
- self-hosted runner 不与普通 PR 构建共享，并应使用一次性 runner 或任务后销毁。
- workflow、构建配置和中央 action 均由 CODEOWNERS 审核。
- 定期轮换证书和 API Key，并进行失效演练。

### 14.1 必须承认的源码信任边界

Environment 审批只能保证“审批前 job 不能读取 Environment secrets”。一旦 job 开始，App 的编译过程会执行工程中的 Run Script phase、CocoaPods 脚本、插件脚本和其他受信任构建代码；签名阶段也必然需要访问临时 Keychain。因此审批者必须审核的是此次运行的精确 `github.ref` 和完整 `github.sha`，不能只看分支名称。

最低要求：

- 只构建受保护分支或签名 Tag 的精确 SHA。
- 审查 workflow、`.xcconfig`、Podfile、Package.resolved、Flutter/React Native 插件锁定文件和 Xcode Run Script phase 的变化。
- 禁止未受信任的 submodule、动态下载脚本和未锁定依赖进入生产签名任务。
- `.p12` 密码和 Base64 原文完成导入后立即从环境中清除。
- `.p8` 只在 IPA 已生成、检查并保存 Artifact 后才注入上传步骤，绝不传给 Archive 阶段。

如果安全级别更高，可进一步拆成两个 job 和两个 Environment：

```text
app-a-signing：只保存 P12 和 profiles → 生成并保存 IPA
app-a-appstore：只保存 P8              → 下载已校验 IPA 并上传 ASC
```

这种拆分让 App 编译脚本永远接触不到 ASC API Key，也能为“生成包”和“向 Apple 发布”设置不同审批人。代价是 workflow 和 Artifact 交接更复杂，第二个 job 必须验证下载 Artifact 的 digest、源码 SHA、版本和 build number。

## 15. 常见故障与处理

| 现象 | 常见原因 | 处理 |
|---|---|---|
| `No signing certificate` | `.p12` 无私钥、密码错误、Keychain 未解锁 | 预检 `.p12`，检查 `security find-identity` |
| `No profiles for ... were found` | Bundle ID 无对应 profile 或未安装 | 解析 profile 的 `application-identifier`，按 UUID 安装 |
| 主 App 成功、Widget 失败 | 只提供了主 App profile | 为每个扩展配置独立 profile |
| profile 过期或无效 | 证书轮换或 capability 变化 | 在 Apple Developer 重新生成 profile |
| Entitlement 不匹配 | App ID/profile 未包含工程能力 | 对比签名 Entitlements 与 profile Entitlements |
| Archive 成功、export 失败 | ExportOptions 映射或 method 不适配 Xcode | 检查真实 profile Name 和 `xcodebuild -help` |
| 重复 build number | 并发任务或人工/Xcode Cloud 上传 | concurrency + ASC 查询 + 单调递增策略 |
| 上传命令成功但 ASC 看不到 | Apple 正在异步处理 | 按 App/version/build 查询 buildUploads 和 builds |
| 网络错误后重传提示重复版本 | 首次上传可能已被 Apple 接收 | 查询 ASC，不要立即换号重打 |
| `MISSING_EXPORT_COMPLIANCE` | 出口合规未完成 | 由有权限人员或已审核自动化补充合规信息 |
| `INVALID` / `FAILED` | Apple 验证发现签名、版本或包内容问题 | 保存 Apple errors，修复后使用新 build number 重传；仅 BuildUpload 明确 `FAILED` 时可依据 Apple规则判断是否允许复用号码 |
| reusable workflow 读不到 Environment secrets | GitHub `workflow_call` 限制 | 改用模式 A，或改用 Repository/Organization secrets |
| Xcode path 不存在 | runner 镜像更新移除旧 Xcode | 更新 runner/Xcode 显式配置，不自动使用 latest |
| Artifact 保存失败 | 路径错误、容量或权限问题 | 默认阻止后续上传，先保证产物可追溯 |

## 16. 分阶段实施建议

### 阶段 1：单 App、只构建不上传

目标：验证配置、依赖、签名、Archive、export 和 IPA 检查。

验收：

- 主 App 和所有扩展签名通过。
- IPA Artifact 可下载。
- 不调用 App Store Connect 上传。
- cleanup 完成。

### 阶段 2：单 App 上传 ASC

目标：验证 `.p8`、altool 和 build upload 查询。

验收：

- Apple 接收上传。
- 精确 build 出现在 ASC。
- BuildUpload `COMPLETE`、Build `VALID`。
- 能区分处理超时与失败。

### 阶段 3：TestFlight 状态与分组

目标：轮询到内部测试可用，并可选分配内部组。

验收：

- `internalBuildState` 达到 ready/testing。
- 可选 group 关系查询确认。
- 出口合规缺失时能准确停在部分成功。

### 阶段 4：接入第二、第三个 App

目标：验证通用性，而不是复制脚本。

验收：

- 中央脚本不出现 App 名、固定 Bundle ID 或固定 Team ID。
- 新 App 只增加配置、workflow 和 Secrets。
- 多扩展 App 与无扩展 App 都能运行。
- App A 的任务无法读取 App B 的密钥。

### 阶段 5：生产加固

目标：完成权限、审计、轮换和故障演练。

验收：

- Environment 审批和分支/Tag 限制生效。
- workflow/code owners 生效。
- actions 全部固定 SHA。
- Secret 泄露和证书轮换演练完成。
- 网络中断、Apple processing 超时和 duplicate build 演练完成。
- self-hosted runner 如存在，完成隔离和销毁策略。

## 17. 上线前检查清单

### Apple

- [ ] App Store Connect App 记录已创建。
- [ ] 主 Bundle ID 与 App 记录一致。
- [ ] 所有扩展 App IDs 已创建。
- [ ] Capabilities/Entitlements 一致。
- [ ] Apple Distribution 证书有效且含私钥。
- [ ] 所有 App Store Connect profiles 有效。
- [ ] API Key 权限足够且不过度授权。
- [ ] 最新协议已接受。
- [ ] 出口合规策略已确定。
- [ ] 如需分发，TestFlight 测试组已创建。

### GitHub

- [ ] `ios-build-core` 访问范围只开放给需要的仓库。
- [ ] 中央 action 固定完整 SHA。
- [ ] App workflow 和配置有 CODEOWNERS。
- [ ] production Environment 已创建。
- [ ] Required reviewers 和 prevent self-review 已启用。
- [ ] 允许的 branch/tag 已限制。
- [ ] 每个 App 的 Secrets 独立。
- [ ] `GITHUB_TOKEN` 为最小权限。
- [ ] PR/fork 不会进入签名 job。
- [ ] concurrency 已配置。
- [ ] Artifact retention 已确认。

### 构建与交付

- [ ] Xcode 版本在 runner 上真实存在。
- [ ] lockfiles 已提交且构建过程不修改它们。
- [ ] 每个签名 Target 都有 profile。
- [ ] Archive 使用 generic iOS device destination。
- [ ] ExportOptions 与所选 Xcode 兼容。
- [ ] IPA 内主 App 和扩展均已检查。
- [ ] Artifact 在上传前保存。
- [ ] ASC 使用 App/version/build 精确查询。
- [ ] TestFlight 成功标准不是“上传命令返回 0”。
- [ ] cleanup 在成功、失败、取消时都会执行。

## 18. 最终推荐

生产环境采用以下组合：

```text
每个 App：受保护 Environment + 独立 Secrets + 薄 workflow
                                  ↓
中央仓库：固定 SHA 的 composite action + 公共脚本
                                  ↓
Archive → IPA 检查 → Artifact → ASC 上传 → TestFlight 状态确认
```

如果组织明确接受 Repository/Organization secrets，且更看重 caller 极简化，可以额外提供 reusable workflow 入口；但文档、代码和安全评审中必须保留 Environment secrets 不能直接传入 reusable workflow 的限制说明。

系统的最终成功条件不应是“Actions 变绿”，而应是：指定源码 SHA 生成的指定 IPA 已保存，Apple 精确识别到相同 App、marketing version 和 build number，处理状态有效，并达到配置要求的 TestFlight 状态。

## 19. 官方参考资料

### GitHub

- [G1] [Reuse workflows：inputs、secrets 与 Environment secrets 限制](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
- [G2] [Installing an Apple certificate on macOS runners for Xcode development](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [G3] [Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [G4] [Secure use reference：固定完整 commit SHA](https://docs.github.com/en/actions/reference/security/secure-use)
- [G5] [Sharing actions and workflows with your organization](https://docs.github.com/en/actions/how-tos/reuse-automations/share-with-your-organization)
- [G6] [Secrets reference：48 KB 限制](https://docs.github.com/en/actions/reference/security/secrets)
- [G7] [Using secrets：大 Secret 的加密文件方案](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
- [G8] [GitHub Actions runner images 与 Xcode 清单](https://github.com/actions/runner-images)
- [G9] [Workflow syntax：workflow_dispatch、permissions、concurrency](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [G10] [GitHub Actions Artifact retention](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/remove-workflow-artifacts)

### Apple

- [A1] [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [A2] [Create an App Store Connect provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)
- [A3] [Creating API Keys for App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [A4] [Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [A5] [Generating Tokens for API Requests](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [A6] [InternalBetaState](https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate)
- [A7] [Xcode exportArchive 示例](https://developer.apple.com/documentation/xcode/reducing-your-app-s-size)
- [A8] [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [A9] [List All Build Uploads for an App](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-builduploads)
- [A10] [BuildUploadState](https://developer.apple.com/documentation/appstoreconnectapi/builduploadstate)
- [A11] [Build upload statuses](https://developer.apple.com/help/app-store-connect/reference/app-uploads/build-upload-statuses)
- [A12] [List builds](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds)
