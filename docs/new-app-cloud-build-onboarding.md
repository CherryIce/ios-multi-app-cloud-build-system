# 新 App 接入 iOS 云构建分类运行手册

> 文档日期：2026-08-25
>
> 适用系统：[CherryIce/ios-multi-app-cloud-build-system](https://github.com/CherryIce/ios-multi-app-cloud-build-system)
>
> 目标：新增原生 iOS 或 Flutter App 时复用中央构建能力，只重复 App 专属接入，不重新开发整套云构建系统。

## 1. 先明确：哪些要重做，哪些不用重做

新增 App 不需要重写中央 Action、签名脚本、IPA 检查、Artifact 或 App Store Connect 状态轮询。需要重复的是每个 App 自己的配置和 Apple/GitHub 资源。

| 层级 | 新 App 是否重复 | 内容 |
| --- | --- | --- |
| 中央构建能力 | 否 | composite action、脚本、Schema、测试和 ASC 状态轮询 |
| App 工程接入 | 是，每个 App 一次 | 配置、薄工作流、依赖锁文件、固定中央 SHA |
| Apple App 资源 | 是，每个 App/Bundle ID 一次 | App ID、ASC App 记录、provisioning profiles |
| GitHub 生产环境 | 是，每个 App 一次 | Environment、Secrets、reviewers、允许分支 |
| 日常发布 | 是，每个版本一次 | dry-run、正式上传、证据归档 |

同一 Apple Team 下，团队成员资格、Team ID、有效的 Apple Distribution identity 和 ASC Team API Key 可以按安全策略复用；Bundle ID、App Store Connect App 记录和 provisioning profile 不能跨 App 直接复用。

## 2. 当前中央分支边界

截至本文日期，中央实现分为两条契约：

| App 类型 | 中央分支 | Schema | 当前远端 SHA 快照 | 状态边界 |
| --- | --- | --- | --- | --- |
| 原生 iOS | `main` | `schema_version: 1` | `902bbc7a72edb2eccd3db06a5410891a98d1ad3b` | 脚本级自测已完成，仍需每个真实 App 做签名接入验证 |
| Flutter iOS | `feature/flutter-support` | `schema_version: 2` | `838cd4f0009b94381ed186da0366323a25d34988` | 支持固定 Flutter SDK 和嵌套目录；Hearthio 首次真实 dry-run 仍待执行 |

生产 App 必须固定引用经过审核的完整 40 位提交 SHA。上表只是 2026-08-25 的快照，不代表未来永远使用这些提交；中央代码变更后，应审核新提交并重新 dry-run。

禁止在生产工作流中引用：

```yaml
uses: CherryIce/ios-multi-app-cloud-build-system/.github/actions/build-upload@main
```

或：

```yaml
uses: CherryIce/ios-multi-app-cloud-build-system/.github/actions/build-upload@feature/flutter-support
```

## 3. 场景选择表

先根据工程确定接入路径：

| 场景 | 选择 |
| --- | --- |
| 原生 iOS，无 CocoaPods/SPM | 原生 v1，`dependency_mode: none` |
| 原生 iOS，使用 CocoaPods | 原生 v1，`dependency_mode: cocoapods` |
| 原生 iOS，使用 Swift Package Manager | 原生 v1，`dependency_mode: spm` |
| 原生 iOS，有特殊生成/依赖脚本 | 原生 v1，`dependency_mode: custom`，必须安全审查命令 |
| Flutter 位于仓库根目录 | Flutter v2，`flutter.project_directory: .` |
| Flutter 位于仓库子目录 | Flutter v2，填写仓库相对路径，例如 `Hearthio` |
| 主 App 带 Widget/Notification Extension | 在 `app.bundle_ids` 中逐个声明 Bundle ID、Target 和 profile alias |
| 一个仓库只有一个 App | 使用默认 `.github/ios-build.yml` 和 `ios-release.yml` |
| 一个仓库包含多个独立 App | 每个 App 使用独立配置、工作流、Environment 和 concurrency group |
| 新 App 与已有 App 属于同一 Apple Team | 可按策略复用团队级证书/API Key；App ID、profiles、ASC App 记录必须新建 |
| 新 App 属于不同 Apple Team/公司 | Team ID、证书、profiles、ASC Key、Secrets 全部重新准备 |

不要根据语言是 Swift/Objective-C 来选择契约；原生项目的关键区别是依赖管理方式。Flutter 项目即使 iOS Runner 使用 CocoaPods，也仍应选择 Flutter v2，由中央流程先执行 `flutter pub get`，再执行 iOS Pods 安装。

## 4. 资源复用矩阵

| 资源 | 作用域 | 同 Team 新 App | 不同 Team 新 App |
| --- | --- | --- | --- |
| Apple Developer Program membership | Apple Team | 复用 | 重新加入/邀请 |
| Team ID | Apple Team | 复用 | 必须更换 |
| Apple Distribution `.p12` | Apple Team/签名身份 | 可复用，取决于安全策略和有效期 | 不可复用 |
| Explicit App ID | Bundle ID | 必须新建/确认 | 必须新建/确认 |
| Provisioning profile | Bundle ID + 证书 | 必须新建 | 必须新建 |
| ASC App 记录/数字 App ID | App | 必须新建/确认 | 必须新建/确认 |
| ASC Team API Key | ASC Team | 可复用，但无法限制到单个 App | 不可复用 |
| TestFlight beta group | ASC App | 每个 App 独立配置 | 每个 App 独立配置 |
| GitHub Environment | App/仓库 | 每个 App 独立创建 | 每个 App 独立创建 |
| Environment Secrets | App Environment | 逐个 Environment 配置 | 全部重新配置 |
| `.github/ios-build*.yml` | App | 每个 App 独立 | 每个 App 独立 |
| release workflow | App | 每个 App 独立 | 每个 App 独立 |

即使复用同一个 `.p12` 或 Team API Key，也应把它们放入新 App 自己的受保护 Environment；不要让一个 App 工作流读取另一个 App 的 Environment。

## 5. 接入前信息表

开始前先收齐以下信息。未知项不要猜测，更不要复制其他 App 的值：

```text
App display name:
Repository owner/name:
Repository default branch:
App type: native / flutter
Repository layout: one app / multiple apps
Flutter project directory: N/A / . / relative path
Apple legal entity/team name:
Apple Team ID:
Primary Bundle ID:
Extension Bundle IDs:
ASC numeric App ID:
Xcode container type: workspace / project
Xcode container path:
Archive scheme:
Release configuration:
Main target:
Extension targets:
Dependency mode: none / cocoapods / spm / flutter / custom
Flutter version/channel/architecture/SHA-256: N/A or values
GitHub runner:
Xcode application path:
Build number strategy:
Production Environment name:
Internal TestFlight group IDs: optional
Central branch and reviewed full SHA:
```

### 5.1 Xcode 字段核对

使用 Xcode 或以下命令确认工程入口与 scheme，不要把 Target、Scheme 和 Configuration 混用：

```bash
xcodebuild -list -workspace AppName.xcworkspace
```

如果没有 workspace：

```bash
xcodebuild -list -project AppName.xcodeproj
```

字段含义：

| 配置字段 | 示例 | 含义 |
| --- | --- | --- |
| `app.bundle_ids[].target` | `Runner`、`ExampleWidget` | 产出对应 Bundle ID 的 Xcode target |
| `build.scheme` | `Run-Release`、`ExampleApp` | Archive 使用的共享 scheme |
| `build.configuration` | `Release` | Archive 配置 |
| `build.container_path` | `App.xcworkspace` | 相对仓库根目录的工程入口 |

scheme 必须是 Shared Scheme 并提交到 Git，否则本机可见但云端可能找不到。

### 5.2 Apple 标识核对

应从实际 App Store distribution profile 解码核对 Team ID 和 App Identifier：

```bash
PROFILE_FILE="/absolute/path/to/AppStore.mobileprovision"
PROFILE_PLIST="$(mktemp -t app-profile)"

security cms -D -i "$PROFILE_FILE" > "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST"
/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROFILE_PLIST"
rm -f -- "$PROFILE_PLIST"
```

验收条件：

- TeamIdentifier 与配置的 `app.team_id` 完全相同；
- application-identifier 为 `TEAMID.BundleID`；
- profile 未过期；
- profile 类型是 App Store Connect distribution，而不是 Development、Ad Hoc 或 Enterprise。

## 6. 所有 App 通用的接入流程

### 步骤 1：确认中央基线

原生与 Flutter 使用不同中央分支。先取得目标分支的远端完整 SHA：

```bash
CENTRAL_REPO_DIR="/absolute/path/to/ios-multi-app-cloud-build-system"

git -C "$CENTRAL_REPO_DIR" fetch origin
git -C "$CENTRAL_REPO_DIR" rev-parse origin/main
git -C "$CENTRAL_REPO_DIR" rev-parse origin/feature/flutter-support
```

选择对应提交后检查变更、中央 CI 和安全边界。不能因为 SHA 来自远端就自动视为已批准。

成功条件：

- 已选择正确的原生或 Flutter 契约；
- SHA 为完整 40 位提交；
- 中央自测通过；
- 已知真实 App Archive/TestFlight 证据被如实记录，没有用脚本自测代替。

### 步骤 2：创建或确认 Apple App 资源

如果是全新 App：

1. 在 Apple Developer 中创建 explicit App ID。
2. 配置 App 实际需要的 Capabilities。
3. 在 App Store Connect 创建 App 记录并取得数字 App ID。
4. 为主 App 和每个 Extension 分别创建 App Store Connect distribution profile。
5. 确认 profile 选择的 distribution certificate 与 CI 使用的 `.p12` 匹配。

如果是已有 App：

1. 不要重新创建 Bundle ID。
2. 核对当前 App ID、Capabilities 和 ASC App ID。
3. 检查现有 profile 类型、证书和到期时间。
4. 缺失或不匹配时重新生成 profile，而不是修改配置去迎合错误材料。

成功条件：每一个待签名 Bundle ID 都能映射到唯一、有效、同 Team 的 App Store distribution profile。

### 步骤 3：创建 App 接入分支

在 App 仓库中从已同步的默认分支创建专用分支：

```bash
APP_REPO_DIR="/absolute/path/to/app-repository"

git -C "$APP_REPO_DIR" status --short
git -C "$APP_REPO_DIR" switch -c chore/ios-cloud-build
```

如果工作树已有其他人的未提交修改，应保留并只暂存本次允许的文件；不要使用 `git add .`，不要清理或重置无关文件。

### 步骤 4：复制对应模板

原生 iOS：

```bash
APP_REPO_DIR="/absolute/path/to/app-repository"
CENTRAL_REPO_DIR="/absolute/path/to/ios-multi-app-cloud-build-system-main"

mkdir -p "$APP_REPO_DIR/.github/workflows"
cp "$CENTRAL_REPO_DIR/examples/app-repository/.github/ios-build.yml" \
  "$APP_REPO_DIR/.github/ios-build.yml"
cp "$CENTRAL_REPO_DIR/examples/app-repository/.github/workflows/ios-release.yml" \
  "$APP_REPO_DIR/.github/workflows/ios-release.yml"
```

Flutter：

```bash
APP_REPO_DIR="/absolute/path/to/app-repository"
CENTRAL_REPO_DIR="/absolute/path/to/ios-multi-app-cloud-build-system-flutter"

mkdir -p "$APP_REPO_DIR/.github/workflows"
cp "$CENTRAL_REPO_DIR/examples/flutter-app-repository/.github/ios-build.yml" \
  "$APP_REPO_DIR/.github/ios-build.yml"
cp "$CENTRAL_REPO_DIR/examples/flutter-app-repository/.github/workflows/ios-release.yml" \
  "$APP_REPO_DIR/.github/workflows/ios-release.yml"
```

模板内所有 `Example`、Hearthio、Environment 名称和 `<PINNED_FULL_COMMIT_SHA>` 都必须替换。不要直接提交示例 ASC App ID、Bundle ID 或 Team ID。

### 步骤 5：填写非敏感配置

共同必须核对：

- `release.allowed_ref_patterns`；
- App name、Team ID、ASC numeric App ID；
- 主 Bundle ID；
- 每个 Bundle ID 的 target 和 profile alias；
- workspace/project、scheme 和 Release configuration；
- runner 与 Xcode path；
- build number 策略；
- Artifact 保留策略；
- ASC wait level 和 beta group IDs。

配置文件只能包含非敏感标识，不得写入 `.p12` 密码、`.p8` 内容、Issuer 私钥、PAT 或其他 Token。

build number 策略会影响 dry-run 是否调用 ASC：

| 策略 | build number 留空时 | dry-run 对 ASC Key 的证明范围 |
| --- | --- | --- |
| `github_run_number` | 使用 GitHub run number | 不读取 ASC，不能证明 Key 有效 |
| `asc_increment` | 查询 ASC 当前最大 build 后递增 | 能证明 Key 的认证/读取满足本次查询，不能证明上传权限 |
| 任一策略 + 手动 override | 使用输入的正整数 | 不为解析 build number 读取 ASC |

无论使用哪种策略，`upload_to_asc=false` 都不会执行 IPA validate/upload，也不能证明 Apple 接收、processing 或 TestFlight 状态。

### 步骤 6：锁定依赖

依赖安装必须产生可重复状态，并把锁文件提交到 Git。中央 Action 会在依赖安装后检查已跟踪文件是否发生变化；有变化就失败。

| 类型 | 必须提交的典型锁文件 |
| --- | --- |
| 原生，无依赖 | 无额外锁文件 |
| CocoaPods | `Podfile.lock`；若有 Gemfile，还要 `Gemfile.lock` |
| SwiftPM | `Package.resolved` |
| Flutter | `pubspec.lock`；存在 `ios/Podfile` 时还要 `ios/Podfile.lock` |
| Custom | 由自定义命令产生的全部可重复输入和锁定结果 |

锁文件被全局 Git Ignore 忽略时，应先确认原因，再只对目标文件使用 `git add -f`；不要强制添加整个目录。

### 步骤 7：创建 App 专属 GitHub Environment

建议命名：

```text
<app-slug>-production
```

在 App 仓库进入：

```text
Settings → Environments → New environment
```

添加六个 Environment Secrets：

```text
IOS_DISTRIBUTION_P12_BASE64
IOS_DISTRIBUTION_P12_PASSWORD
IOS_PROFILES_ARCHIVE_BASE64
ASC_API_KEY_P8_BASE64
ASC_KEY_ID
ASC_ISSUER_ID
```

推荐保护规则：

- 至少一名 Required reviewer；
- 条件允许时禁止发起人自审；
- Deployment branches/tags 只允许 `main` 和明确批准的 release ref；
- 生产 Environment 尽量关闭管理员绕过；
- reviewer 审批时必须核对运行的精确 ref 和 SHA。

### 步骤 8：准备 Environment Secret 值

所需材料：

```text
Apple Distribution .p12 + 密码
主 App/所有 Extension 的 App Store profiles
ASC Team API .p8
与 .p8 匹配的 Key ID
ASC Issuer ID
```

`.cer` 不含私钥，不能代替 `.p12`。Key ID、Issuer ID 和 Apple Team ID 是三个不同字段。

安全生成 Base64：

```bash
P12_FILE="/absolute/path/to/distribution.p12"
P8_FILE="/absolute/path/to/AuthKey_KEYID.p8"
PROFILES_SOURCE_DIR="/absolute/path/to/app-store-profiles"
APP_SIGNING_TMP="$(mktemp -d)"

openssl base64 -A -in "$P12_FILE" | pbcopy
# 立即保存为 IOS_DISTRIBUTION_P12_BASE64

tar -C "$PROFILES_SOURCE_DIR" -czf "$APP_SIGNING_TMP/profiles.tar.gz" .
openssl base64 -A -in "$APP_SIGNING_TMP/profiles.tar.gz" | pbcopy
# 立即保存为 IOS_PROFILES_ARCHIVE_BASE64

openssl base64 -A -in "$P8_FILE" | pbcopy
# 立即保存为 ASC_API_KEY_P8_BASE64

rm -rf -- "$APP_SIGNING_TMP"
pbcopy </dev/null
```

profiles 归档中只应包含该 App 实际需要的 `.mobileprovision` 文件。不要放 `.p12`、`.p8`、密码文本、其他 App 的无关 profiles 或临时 Keychain。

### 步骤 9：固定中央 Action SHA 和 Environment

在 App release workflow 中同时修改：

```yaml
jobs:
  release:
    environment: newapp-production
```

以及：

```yaml
uses: CherryIce/ios-multi-app-cloud-build-system/.github/actions/build-upload@FULL_40_CHARACTER_SHA
```

如果一个仓库中有多个 App，还要修改 `config_path` 和 concurrency group，见第 8 节。

### 步骤 10：精确暂存和 PR 审核

单 App 仓库的典型暂存范围：

```bash
APP_REPO_DIR="/absolute/path/to/app-repository"

git -C "$APP_REPO_DIR" add .github/ios-build.yml
git -C "$APP_REPO_DIR" add .github/workflows/ios-release.yml
# 再逐个添加本项目实际生成的锁文件
git -C "$APP_REPO_DIR" diff --cached --name-status
git -C "$APP_REPO_DIR" diff --cached --check
```

PR 必须审核：

- 没有示例 Team ID、ASC App ID、Bundle ID 或 Environment；
- 使用正确中央分支的完整 SHA；
- workflow permissions 保持最小；
- 没有私钥、profiles 原文件、密码或 Token；
- 依赖锁文件完整；
- Run Script、Pods/SPM/Flutter 插件变更已被审核，因为它们会在持有签名材料的 job 中运行。

### 步骤 11：首次不上传构建

PR 合并后，从允许的生产 ref 手动运行 workflow：

```text
marketing_version: 三段数字，例如 1.0.0
build_number: 按策略留空或填写唯一正整数
upload_to_asc: false
```

成功条件不是“Actions 绿色”四个字，而是：

1. checkout 的 ref/SHA 与批准内容一致；
2. 依赖安装未修改已跟踪文件；
3. 临时签名材料安装成功；
4. Release Archive 成功；
5. 唯一 IPA 导出成功；
6. IPA Bundle ID、版本、build number、Team ID 和 embedded profile 正确；
7. Artifact 已生成；
8. Artifact 中没有 `.p12`、`.p8`、`.mobileprovision` 或 Keychain。

`upload_to_asc=false` 不会验证 IPA 上传权限，也不会证明 Apple 已接收或 TestFlight 可用。仅当策略是 `asc_increment` 且 build number 留空时，它会提前使用 ASC Key 查询并解析 build number；这只证明本次认证/读取调用成功。

### 步骤 12：首次正式上传

只有相同配置的 dry-run 通过后，才使用新的唯一 build number 运行：

```text
upload_to_asc: true
```

正式成功证据链：

```text
精确 github.ref / github.sha
→ Archive
→ IPA inspection / Artifact
→ Apple upload receipt
→ 精确 ASC build 出现
→ processing_state=VALID
→ READY_FOR_BETA_TESTING 或 IN_BETA_TESTING
→ 如配置 beta group：回读确认关联
```

任何中间节点都不能单独代表最终 TestFlight 成功。

## 7. 按项目类型填写配置

以下片段只展示类型差异；完整配置仍应从对应中央模板复制，并填写第 5 节的全部字段。

### 7.1 原生 iOS：无外部依赖

适用于不使用 CocoaPods、SwiftPM，也不需要自定义依赖命令的工程：

```yaml
schema_version: 1

build:
  container_type: project
  container_path: NewApp.xcodeproj
  scheme: NewApp
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: none
  dependency_command: ""
```

如果工程实际提交了 workspace，应使用：

```yaml
container_type: workspace
container_path: NewApp.xcworkspace
```

成功条件：云端无需额外依赖安装即可找到共享 scheme 并完成 Archive。

### 7.2 原生 iOS：CocoaPods

配置：

```yaml
schema_version: 1

build:
  container_type: workspace
  container_path: NewApp.xcworkspace
  scheme: NewApp
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: cocoapods
  dependency_command: ""
```

本地准备：

```bash
APP_REPO_DIR="/absolute/path/to/app-repository"

cd "$APP_REPO_DIR"
pod install
git ls-files --error-unmatch Podfile.lock
```

若仓库有 `Gemfile`，中央流程还要求提交 `Gemfile.lock`，并使用 `bundle exec pod install --deployment`；没有 Gemfile 时使用 `pod install --deployment`。

成功条件：

- `Podfile.lock` 已跟踪；
- 有 Gemfile 时 `Gemfile.lock` 已跟踪；
- `pod install --deployment` 不改变锁文件；
- Archive 从 `.xcworkspace` 进入，而不是绕过 Pods 使用 `.xcodeproj`。

### 7.3 原生 iOS：Swift Package Manager

配置：

```yaml
schema_version: 1

build:
  container_type: workspace
  container_path: NewApp.xcworkspace
  scheme: NewApp
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: spm
  dependency_command: ""
```

必须提交 `Package.resolved`。常见位置包括：

```text
NewApp.xcworkspace/xcshareddata/swiftpm/Package.resolved
NewApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

检查：

```bash
APP_REPO_DIR="/absolute/path/to/app-repository"

find "$APP_REPO_DIR" -type f -name Package.resolved -print
git -C "$APP_REPO_DIR" ls-files | grep 'Package.resolved$'
```

中央流程会执行 `xcodebuild -resolvePackageDependencies`。如果仓库中存在多个 `Package.resolved`，应确认所有实际构建使用的锁文件都已提交，并在首次 dry-run 中核对解析结果。

### 7.4 原生 iOS：自定义依赖命令

只有 `none/cocoapods/spm` 无法覆盖项目时才使用：

```yaml
schema_version: 1

build:
  dependency_mode: custom
  dependency_command: "bash scripts/prepare-release-dependencies.sh"
```

风险边界：该命令会在 App 仓库 checkout 后、签名材料安装前执行，但仍属于发布流水线代码。必须审核脚本及其下载源、校验和、日志输出和锁定策略。

自定义命令必须满足：

- 非交互；
- `set -euo pipefail` 或等价失败策略；
- 下载内容固定版本并校验；
- 不读取或打印 GitHub Secrets；
- 不修改已跟踪文件；
- 失败时返回非零状态；
- 不把凭据或临时制品写入 Artifact 目录。

不要把临时修复命令直接堆进 YAML；优先提交可审查的仓库脚本。

### 7.5 Flutter：工程位于仓库根目录

目录示例：

```text
NewFlutterApp/
├── pubspec.yaml
├── pubspec.lock
├── ios/
│   ├── Podfile
│   ├── Podfile.lock
│   └── Runner.xcworkspace
└── .github/
```

配置差异：

```yaml
schema_version: 2

flutter:
  project_directory: .
  version: 3.35.7
  channel: stable
  architecture: arm64
  sdk_sha256: REPLACE_WITH_OFFICIAL_ARCHIVE_SHA256

build:
  container_type: workspace
  container_path: ios/Runner.xcworkspace
  scheme: Runner
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: flutter
  dependency_command: ""
```

`version`、`channel`、`architecture` 和 `sdk_sha256` 必须对应 Flutter 官方同一个 SDK 归档。不要复制 Hearthio 的 checksum 后只改版本号。

锁文件：

```bash
APP_REPO_DIR="/absolute/path/to/flutter-repository"

cd "$APP_REPO_DIR"
flutter pub get
cd ios
pod install
cd ..
git ls-files --error-unmatch pubspec.lock
git ls-files --error-unmatch ios/Podfile.lock
```

### 7.6 Flutter：工程位于仓库子目录

目录示例：

```text
ProductRepository/
├── NewFlutterApp/
│   ├── pubspec.yaml
│   ├── pubspec.lock
│   └── ios/
│       ├── Podfile.lock
│       └── Runner.xcworkspace
└── .github/
```

配置：

```yaml
schema_version: 2

flutter:
  project_directory: NewFlutterApp
  version: 3.35.7
  channel: stable
  architecture: arm64
  sdk_sha256: REPLACE_WITH_OFFICIAL_ARCHIVE_SHA256

build:
  container_type: workspace
  container_path: NewFlutterApp/ios/Runner.xcworkspace
  scheme: Runner
  configuration: Release
  runner: macos-26
  xcode_path: /Applications/Xcode_26.4.app
  dependency_mode: flutter
  dependency_command: ""
```

约束：

- `flutter.project_directory` 是仓库相对路径；
- `build.container_path` 也相对仓库根目录；
- container 必须位于 Flutter 工程目录内；
- 不允许 `..`、绝对路径或符号链接逃出仓库；
- Target 通常仍为 `Runner`，但 scheme 必须以该项目实际共享 scheme 为准。

锁文件路径相应变为：

```text
NewFlutterApp/pubspec.lock
NewFlutterApp/ios/Podfile.lock
```

### 7.7 主 App 带 Widget 或其他 Extension

每个可签名 Bundle ID 都要声明独立映射：

```yaml
app:
  name: NewApp
  team_id: ABCDE12345
  asc_app_id: "1234567890"
  primary_bundle_id: com.company.newapp
  bundle_ids:
    - bundle_id: com.company.newapp
      target: NewApp
      profile_alias: app
    - bundle_id: com.company.newapp.widget
      target: NewAppWidget
      profile_alias: widget
    - bundle_id: com.company.newapp.NotificationService
      target: NotificationService
      profile_alias: notification-service
```

要求：

- 每个 Bundle ID 都是 Apple Developer 中的 explicit App ID；
- 每个 Bundle ID 都有 App Store distribution profile；
- 所有 profiles 与 CI `.p12` 中的 distribution certificate 匹配；
- profile archive 同时包含这些 profiles；
- Target 名称与 Xcode 工程完全一致；
- Capabilities/entitlements 与各自 profile 一致。

只为主 App 提供 profile 会导致 Archive 或 Export 在 Extension 签名阶段失败。

## 8. 按仓库结构接入

### 8.1 一个仓库一个 App

这是默认且推荐的结构：

```text
.github/ios-build.yml
.github/workflows/ios-release.yml
<app-slug>-production
```

优点是 Environment、并发、Artifact 和发布权限天然隔离，模板改动最少。

### 8.2 一个仓库包含多个独立 App

为每个 App 使用独立文件：

```text
.github/ios-build-app-a.yml
.github/ios-build-app-b.yml
.github/workflows/app-a-ios-release.yml
.github/workflows/app-b-ios-release.yml
```

独立 Environment：

```text
app-a-production
app-b-production
```

App A workflow 的关键差异：

```yaml
name: App A iOS Release

concurrency:
  group: app-a-ios-production-${{ github.repository }}
  cancel-in-progress: false
  queue: max

jobs:
  release:
    environment: app-a-production
    steps:
      - name: Build, retain, and optionally upload App A
        uses: CherryIce/ios-multi-app-cloud-build-system/.github/actions/build-upload@FULL_40_CHARACTER_SHA
        with:
          config_path: .github/ios-build-app-a.yml
```

App B 必须使用不同 workflow name、config path、Environment 和 concurrency group。

若同一仓库同时含原生 App 与 Flutter App：

- 原生 workflow 固定引用中央 `main` 的审核 SHA；
- Flutter workflow 固定引用 Flutter 分支的审核 SHA；
- 两份配置分别使用 schema v1 和 v2；
- 不能让 Flutter 配置调用原生 SHA，也不能让原生配置调用 Flutter SHA。

### 8.3 多仓库、同一 Apple Team

每个 App 仓库仍创建自己的 Environment 和薄工作流。可以按团队安全策略复用 `.p12`/ASC Team API Key，但应分别写入每个受保护 Environment。

这会产生团队级共享凭据的影响范围：任何一个 Environment 泄露都可能影响同 Team 其他 App。高安全要求团队可以使用独立 distribution identity 或缩短 API Key 轮换周期，但 provisioning profile 仍必须逐 Bundle ID 创建。

## 9. 按 Apple 团队和账户场景接入

### 9.1 同 Apple Team、已有 CI 凭据

可以复用：

- Team ID；
- 未过期且私钥可用的 Apple Distribution `.p12`；
- 未撤销且权限合适的 ASC Team API Key；
- 已建立的人员角色和 2FA 账户。

仍必须新建/确认：

- 新 App 的 explicit Bundle ID；
- 每个 Extension 的 Bundle ID；
- ASC App 记录和数字 App ID；
- 每个 Bundle ID 的 App Store profile；
- 新 App GitHub Environment 与 Secrets；
- TestFlight 信息和 beta groups。

### 9.2 同 Apple Team，但旧凭据不可交付

如果只有 `.cer`、没有私钥，不能生成可用 `.p12`。处理方式：

1. 找到持有对应私钥的 Mac 并导出 `.p12`；或
2. 由 Account Holder/Admin 创建新的 Apple Distribution identity；
3. 使用新证书重新生成该 App 全部 distribution profiles；
4. 更新新 App Environment；
5. 先 dry-run。

不要共享 Apple Account 密码，也不要把私钥通过聊天或普通网盘传递。

### 9.3 不同 Apple Team/不同公司主体

以下信息全部视为新资源：

```text
Team ID
Apple Distribution certificate/private key
App IDs
Provisioning profiles
ASC App record
ASC Issuer ID
ASC Team API Key/Key ID/.p8
GitHub Environment Secrets
Agreements、Tax、Banking 和会员状态
```

旧团队的 `.p12`、profiles、Issuer ID 或 API Key 都不能用于新团队。

### 9.4 账户角色分工

| 操作 | 典型必要角色 |
| --- | --- |
| 首次申请 App Store Connect API access | Account Holder |
| 创建/管理 ASC Team API Key | Account Holder 或 Admin |
| 创建 App Store Connect App 记录 | Account Holder、Admin 或 App Manager |
| 创建 App Store provisioning profile | Account Holder 或 Admin |
| 上传 build | Account Holder、Admin、App Manager 或 Developer |
| 选择 build 提交审核 | Account Holder、Admin 或 App Manager |
| 管理 GitHub Environment Secrets | 仓库/组织中具备相应管理权限的人 |
| 批准生产 deployment | Environment Required reviewer |

ASC Team API Key 不能限制到单个 App。只上传和读取状态时优先验证 `Developer` 最小角色；如果中央流程还要自动管理 beta groups，应按实际 API endpoint 验证角色，`App Manager` 是比直接使用 `Admin` 更收敛的候选。不要为了省事默认使用 Admin Key。

当前中央配置只接受 `upload.asc_key_type: team`。如果组织要求使用受用户 App access 限制的 individual API Key，需要先正式扩展、测试并审核中央 Action，不能只把 `asc_key_type` 改成其他字符串。

## 10. Git 推送与凭据隔离

新增 `.github/workflows/*.yml` 时，GitHub 凭据必须具备修改 workflow 的权限。如果 SourceTree OAuth 报错：

```text
refusing to allow an OAuth App to create or update workflow
without workflow scope
```

处理原则：

- 保留 SourceTree 全局 OAuth；
- 使用只允许目标 App 仓库的短期 fine-grained PAT；
- 仅授予 Contents read/write 与 Workflows read/write；
- 使用 `credential.useHttpPath=true` 隔离单仓库凭据；
- 不把 PAT 放进 remote URL 或 `.git/config`；
- 推送完成后清除 Keychain 凭据并在 GitHub 撤销 Token。

完整安全命令参考 [Hearthio Flutter 云构建运行手册](hearthio-flutter-cloud-build-runbook.md#47-sourcetree-缺少-workflow-scope)。

## 11. 常见失败与分流

| 现象 | 优先判断 | 处理 |
| --- | --- | --- |
| 配置 Schema 不匹配 | 原生/Flutter 引用了错误中央分支 | 原生用 v1/main，Flutter 用 v2/Flutter SHA |
| workspace/project 不存在 | container type/path 写错 | 从仓库根目录核对真实相对路径 |
| scheme not found | scheme 未共享或名称错 | 在 Xcode 设为 Shared 并提交 xcshareddata |
| `Podfile.lock must be committed` | 锁文件缺失或被 ignore | `pod install` 后精确 `git add`，必要时仅对该文件 `-f` |
| `Package.resolved` required | SwiftPM 锁文件未提交 | 找到实际路径并提交 |
| Flutter project missing | `project_directory` 错误 | 根目录用 `.`，子目录用规范化仓库相对路径 |
| Flutter checksum mismatch | 版本/架构/checksum 不属于同一归档 | 从官方 manifest 重新取得对应 SHA-256 |
| dependencies modified tracked files | 锁定状态不可重复 | 本地生成并提交变化，不在发布 job 中临时接受 |
| wrong TeamIdentifier | 配置与 profile 不同团队 | 解码实际 profile，修正材料或配置 |
| No Apple Distribution identity | `.p12` 无私钥、密码错或证书无效 | 从持有私钥的 Mac 重导，并匹配 profile |
| Extension export 失败 | 缺少 Extension profile/mapping | 补齐 bundle_ids、profile alias 和 profile archive |
| Secret 为空 | Environment 名称错或未审批 | 核对 workflow Environment、Secret 名称和 deployment approval |
| workflow push 被拒 | GitHub 凭据缺 Workflows 权限 | 使用仓库隔离的短期 fine-grained PAT |
| dry-run 绿色但无法上传 | `github_run_number`/override 未使用 ASC Key，或 `asc_increment` 只验证了读取而非上传 | 单独验证权限，或在 dry-run 通过后受控执行正式上传 |
| upload 成功但 TestFlight 未就绪 | Apple 仍 processing 或 build 异常 | 查精确 build、`asc-status.json` 和 Apple 状态，不盲目重复上传 |

## 12. 新 App 接入验收清单

### 12.1 配置与仓库

- [ ] 已选择原生 v1 或 Flutter v2 的正确中央分支。
- [ ] workflow 固定完整 40 位中央 SHA。
- [ ] App name、Team ID、ASC App ID、Bundle IDs 已替换模板值。
- [ ] Target、Scheme、Configuration、container path 已核对。
- [ ] release refs 只允许批准的分支/Tags。
- [ ] 依赖模式与项目实际技术一致。
- [ ] 所有必要锁文件已提交。
- [ ] 依赖安装不会修改已跟踪文件。
- [ ] 仓库中没有 `.p12`、`.p8`、profiles、密码或 Token。

### 12.2 Apple 与签名

- [ ] Apple Developer membership 有效。
- [ ] Team ID 从实际 profile 核对。
- [ ] 主 App 和每个 Extension 都有 explicit App ID。
- [ ] Capabilities 与 entitlements 一致。
- [ ] `.p12` 含证书和对应私钥。
- [ ] 每个 Bundle ID 都有 App Store distribution profile。
- [ ] profiles 与 `.p12` 的 distribution certificate 匹配。
- [ ] ASC App 记录和数字 App ID 正确。
- [ ] ASC Team API Key 未撤销，角色满足预期操作。

### 12.3 GitHub Environment

- [ ] App 有独立 production Environment。
- [ ] 六个 Secrets 名称完全正确。
- [ ] Required reviewers 已配置。
- [ ] 允许部署的 branches/tags 已收紧。
- [ ] reviewer 能看到并核对精确 ref/SHA。
- [ ] 多 App 同仓时 config、workflow、Environment、concurrency 均独立。

### 12.4 首次 dry-run

- [ ] `upload_to_asc=false`。
- [ ] Release Archive 和 Export 成功。
- [ ] IPA Bundle ID、Team ID、版本、build number 正确。
- [ ] embedded profiles 与各 Bundle ID 对应。
- [ ] Artifact 包含 IPA、metadata、inspection、dSYMs 和日志。
- [ ] Artifact 不含禁止的敏感文件。
- [ ] 已记录 run URL、App SHA 和中央 Action SHA。

### 12.5 首次正式上传

- [ ] 相同配置的 dry-run 已通过。
- [ ] 使用新的唯一 build number。
- [ ] `upload_to_asc=true` 经 Environment 审批。
- [ ] Apple upload receipt 已保存。
- [ ] 精确 ASC build 已出现。
- [ ] processing 为 `VALID`。
- [ ] TestFlight internal state 已就绪。
- [ ] 如使用 beta group，已回读确认关联。

## 13. 新 App 接入记录模板

为每个 App 复制以下内容建立接入记录：

```text
App:
Repository:
App type: native / flutter
Dependency type: none / cocoapods / spm / flutter / custom
Repository layout: single app / multi app
Flutter project directory: N/A / . / path
Apple team name:
Team ID:
Primary Bundle ID:
Extension Bundle IDs:
ASC App ID:
Container type/path:
Scheme / Configuration:
Targets and profile aliases:
Flutter version/channel/architecture/checksum: N/A / values
Runner / Xcode:
Environment:
Central branch:
Central action SHA:
App integration branch:
App integration commit/PR:
Secrets configured by:
Environment protection reviewed by:
Dry-run URL:
Dry-run source SHA:
Dry-run result:
IPA SHA-256:
Formal upload URL:
Apple receipt:
ASC build ID:
Processing state:
TestFlight state:
Known gaps:
Final verdict: onboarding only / archive verified / TestFlight ready
```

## 14. 证据边界

| 证据 | 能证明什么 | 不能证明什么 |
| --- | --- | --- |
| 配置 Schema/脚本测试 | 配置和公共脚本契约 | 真实 App 能签名 Archive |
| 本地 `flutter pub get`/`pod install` | 本地依赖可解析 | GitHub runner 和 Release Archive 成功 |
| 本地 Xcode build | 当前 Mac 上可编译 | 云端签名、Export、Apple 接收 |
| GitHub dry-run Artifact | 精确远端 SHA 完成 Archive/IPA 检查；`asc_increment` 可附带证明 Key 的认证/读取 | IPA 上传权限、Apple processing、TestFlight |
| altool 上传退出成功 | Apple 接受了上传请求 | build processing 已完成 |
| `processing_state=VALID` | 精确 build 处理有效 | 已加入指定 beta group |
| TestFlight ready + group 回读 | 内部测试状态和分组完成 | App Store 审核通过 |

## 15. 官方与仓库参考

- [中央仓库 README](../README.md)
- [Flutter 分支字段与嵌套目录](flutter-support.md)
- [Hearthio Flutter 实际接入与账户配置](hearthio-flutter-cloud-build-runbook.md)
- [原生 App 配置模板](../examples/app-repository/.github/ios-build.yml)
- [原生 App 工作流模板](../examples/app-repository/.github/workflows/ios-release.yml)
- [Flutter App 配置模板](../examples/flutter-app-repository/.github/ios-build.yml)
- [Flutter App 工作流模板](../examples/flutter-app-repository/.github/workflows/ios-release.yml)
- [Apple：Team ID](https://developer.apple.com/help/glossary/team-id/)
- [Apple：导出和共享 signing certificates](https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates)
- [Apple：创建 App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
- [Apple：App Store Connect API 与 Team Keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
- [Apple：上传 builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple：App Store Connect 角色权限](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions)
- [GitHub：Environments 与 deployment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [GitHub：workflow/job concurrency 与 queue](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- [GitHub：手动运行 workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
- [GitHub：fine-grained PAT](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [Flutter：SDK archive](https://docs.flutter.dev/install/archive)
