# Hearthio Flutter iOS 云构建接入、账户配置与发布运行手册

> 文档日期：2026-08-25
>
> 适用项目：[CherryIce/Donesome](https://github.com/CherryIce/Donesome) 中的 `Hearthio/` Flutter App
>
> 中央构建仓库：[CherryIce/ios-multi-app-cloud-build-system](https://github.com/CherryIce/ios-multi-app-cloud-build-system)
>
> 当前状态：中央 Flutter 分支和 Donesome `main` 已接入；首次 `upload_to_asc=false` 云构建尚未执行。

## 1. 文档目标与安全原则

本文记录以下内容：

1. 2026-08-25 完成的 Flutter 云构建支持、Hearthio 配置、签名材料准备、GitHub Environment 和仓库接入全过程。
2. 后续 Apple Developer、App Store Connect、GitHub 账户和权限的配置、交接与轮换流程。
3. 首次不上传构建、正式 ASC/TestFlight 上传、证据验收和常见故障处理。

本文只记录非敏感标识、Secret 名称和生成方式，绝不记录以下值：

- `.p12` 内容及密码；
- `.p8` 私钥内容；
- GitHub Environment Secret 的真实值；
- GitHub PAT；
- 任何可直接用于签名或上传的完整凭据。

任何私钥、Token 或密码都不得提交到 Git、粘贴到聊天、写入 remote URL、写入 `.git/config`，也不得出现在截图或构建日志中。

## 2. 当前已确认状态

### 2.1 远端提交与文件

| 项目 | 当前证据 |
| --- | --- |
| 中央 Flutter 支持分支 | `feature/flutter-support` |
| 中央 Action 固定 SHA | `838cd4f0009b94381ed186da0366323a25d34988` |
| Donesome 接入提交 | `25940b7e6a1ace5939d037628f775fb070876d8e` |
| Donesome 合并 PR | `#1` |
| Donesome `main` 合并提交 | `5cbb455a8fb684a58db77aa1d13112a711936675` |
| App 配置 | `.github/ios-build.yml` |
| App 工作流 | `.github/workflows/ios-release.yml` |
| CocoaPods 锁文件 | `Hearthio/ios/Podfile.lock` |
| GitHub Environment | `hearthio-production` |

Donesome 工作流固定引用中央完整 SHA，而不是分支名或可移动 Tag：

```yaml
uses: CherryIce/ios-multi-app-cloud-build-system/.github/actions/build-upload@838cd4f0009b94381ed186da0366323a25d34988
```

以后中央 Action 发生任何修改，都必须生成新提交，再通过 Donesome PR 更新这里的完整 SHA，并重新执行不上传构建。

### 2.2 Hearthio 非敏感配置

| 字段 | 当前值 | 说明 |
| --- | --- | --- |
| App 名称 | `Hearthio` | 展示名称 |
| Apple Team ID | `Z353FCBY9T` | 已从 distribution profile 解码确认 |
| ASC App ID | `6804913721` | App Store Connect 数字 App ID |
| Bundle ID | `com.Hearthio.lite` | 与 profile 的 App Identifier 一致 |
| Xcode Target | `Runner` | `target` 不是 scheme |
| Profile Alias | `app` | 用于把 Bundle ID 映射到 distribution profile |
| Xcode Scheme | `Run-Release` | 正式 Archive scheme |
| Configuration | `Release` | 不上传测试仍使用 Release Archive |
| Flutter 工程目录 | `Hearthio` | 相对 Donesome 仓库根目录 |
| Workspace | `Hearthio/ios/Runner.xcworkspace` | CocoaPods 构建入口 |
| Flutter | `3.35.7 stable` | 已固定版本 |
| Runner 架构 | `arm64` | 与 `macos-26` Apple Silicon runner 一致 |
| Flutter SDK SHA-256 | `4d7aaadc4893f9216d4e2ecbe0e8fb4213e9bd49d29fd5f441f34fcc05758e2b` | 下载后必须匹配 |
| GitHub runner | `macos-26` | GitHub-hosted Apple Silicon runner |
| Xcode 路径 | `/Applications/Xcode_26.4.app` | runner 镜像中的 Xcode 26.4.1 别名 |
| Marketing Version | 手动输入 | 当前首次输入为 `1.0.0` |
| Build Number | `github_run_number` | 留空时自动生成 |
| 默认上传 | `false` | 首次接入不会上传 Apple |
| Artifact 保留 | 30 天 | `keep_xcarchive=false` |

这里必须区分三个概念：配置中的 `target` 是 Xcode target `Runner`，Archive 使用的 scheme 是 `Run-Release`，构建配置是 `Release`。不要把 `Run-Release` 或 `Runner-Profile` 写进 `target` 字段。

### 2.3 已确认的签名与 ASC 标识

从 `Heal_pro_file.mobileprovision` 解码得到：

```text
TeamIdentifier: Z353FCBY9T
application-identifier: Z353FCBY9T.com.Hearthio.lite
ExpirationDate: 2027-08-25 11:03:13 CST
```

ASC API Key 文件名显示当前 Key ID：

```text
AuthKey_SH4VT69BJJ.p8
ASC_KEY_ID=SH4VT69BJJ
```

Issuer ID 是另一个 UUID，只保存在 GitHub Secret `ASC_ISSUER_ID`，不得把 Team ID、Key ID 和 Issuer ID 混用。

### 2.4 证据边界

截至本文档日期：

- 已完成：中央实现、静态配置、中央测试、macOS 合约检查、签名材料准备、Environment Secrets、Donesome PR 合并。
- 未完成：GitHub-hosted runner 的真实签名 Archive、IPA 导出、Artifact 下载检查。
- 未完成：Apple 接收、ASC processing、TestFlight 内测可用性。

本地测试或配置校验通过不能替代真实云端 Archive；绿色 Actions 也不能自动等同于 TestFlight 可测试。

## 3. 架构与凭据边界

```text
Donesome 精确 main SHA
  ├─ .github/ios-build.yml（非敏感 App 配置）
  ├─ .github/workflows/ios-release.yml
  └─ hearthio-production（App 仓库 Environment Secrets）
           │
           └─ 固定完整 SHA 调用中央 composite action
                 ├─ 校验精确 ref/SHA 与工具链
                 ├─ 下载并校验 Flutter SDK
                 ├─ 安装锁定依赖
                 ├─ 临时导入 .p12/profile
                 ├─ Archive / Export / IPA 检查
                 ├─ 先留存 Artifact
                 └─ upload_to_asc=true 时才准备 .p8 并上传 Apple
```

凭据必须放在 Donesome 的 `hearthio-production` Environment。中央仓库不保存任何 App 私钥。Environment Secret 不能依赖 reusable workflow 自动透传，因此 App 工作流直接绑定 Environment，再调用固定 SHA 的中央 composite action。

云构建的 Archive、Export 和上传都发生在 GitHub-hosted `macos-26` runner 上，不使用触发者本机安装的 Flutter、Xcode、CocoaPods 或钥匙串。本机只承担准备工作：生成并提交锁文件/配置、把签名材料转换为 Secret，以及发起或审批 workflow。因此构建执行环境与本机独立，但远端仍严格依赖本机准备后提交到 GitHub 的代码、锁文件、配置和 Environment Secrets。

## 4. 2026-08-25 实施记录

### 4.1 中央 Flutter 分支

原生 iOS 继续由中央仓库 `main` 维护，Flutter 使用独立分支：

```text
feature/flutter-support
```

Flutter 分支使用 `schema_version: 2`，增加：

- `flutter.project_directory`，支持 `Hearthio/` 嵌套工程；
- Flutter `version`、`channel`、`architecture` 和官方 SDK `sdk_sha256`；
- `dependency_mode: flutter`；
- `pubspec.lock` 与 `Podfile.lock` 强制提交；
- Flutter SDK 下载校验、Release Archive、IPA 签名检查、Artifact 和 ASC 轮询。

中央分支经测试后推送，最终供 Donesome 固定引用的提交是：

```text
838cd4f0009b94381ed186da0366323a25d34988
```

### 4.2 Team ID 与 profile 核对

不能仅根据 App Store Connect 页面上的十位字符串或 Xcode 工程旧值推断 Team ID。应直接解码将用于 CI 的 distribution profile：

```bash
cd ~/Desktop/DoneSome_Cer

security cms -D -i Heal_pro_file.mobileprovision \
  > /tmp/hearthio-profile.plist

/usr/libexec/PlistBuddy \
  -c 'Print :TeamIdentifier:0' \
  /tmp/hearthio-profile.plist

/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:application-identifier' \
  /tmp/hearthio-profile.plist

/usr/libexec/PlistBuddy \
  -c 'Print :ExpirationDate' \
  /tmp/hearthio-profile.plist
```

验收条件：

```text
TeamIdentifier = Z353FCBY9T
application-identifier = Z353FCBY9T.com.Hearthio.lite
ExpirationDate 晚于当前时间
```

中央 Archive 会显式传入：

```text
DEVELOPMENT_TEAM=Z353FCBY9T
CODE_SIGN_IDENTITY=Apple Distribution
```

因此云构建会覆盖 Xcode 工程里遗留的旧 Development Team；最终 IPA 检查仍会再次验证实际签名 Team ID 和 embedded profile。

### 4.3 准备签名材料

所需原始材料：

```text
Hearthio_Distribution.p12
Heal_pro_file.mobileprovision
AuthKey_SH4VT69BJJ.p8
Issuer ID
```

`ios_distribution.cer` 只有证书，不含私钥，不能单独用于 CI 代码签名。必须由持有对应私钥的人从 Xcode 或 Keychain 导出带密码保护的 `.p12`。

在保存文件的 Mac 上生成 GitHub Secret 值：

```bash
cd ~/Desktop/DoneSome_Cer

# 1. Distribution .p12
openssl base64 -A -in Hearthio_Distribution.p12 | pbcopy

# 2. App Store profiles archive；归档里只能放 .mobileprovision
tar -czf hearthio-profiles.tar.gz Heal_pro_file.mobileprovision
openssl base64 -A -in hearthio-profiles.tar.gz | pbcopy

# 3. App Store Connect API private key
openssl base64 -A -in AuthKey_SH4VT69BJJ.p8 | pbcopy
```

每次执行后立即把剪贴板内容保存到对应 Secret。下一次 `pbcopy` 会覆盖上一次内容。

只检查剪贴板长度，不打印真实内容：

```bash
pbpaste | wc -c
```

三个 Secret 均保存完成后，清理临时 profile 归档并清空剪贴板：

```bash
rm -f -- hearthio-profiles.tar.gz
pbcopy </dev/null
```

### 4.4 创建 GitHub Environment Secrets

GitHub 路径：

```text
CherryIce/Donesome
→ Settings
→ Environments
→ hearthio-production
→ Environment secrets
```

已经创建以下六个 Secret：

| Secret | 内容来源 | 是否用于首次不上传构建 |
| --- | --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | `.p12` Base64 | 是 |
| `IOS_DISTRIBUTION_P12_PASSWORD` | `.p12` 导出密码 | 是 |
| `IOS_PROFILES_ARCHIVE_BASE64` | profiles `tar.gz` Base64 | 是 |
| `ASC_API_KEY_P8_BASE64` | `.p8` Base64 | 当前策略下否 |
| `ASC_KEY_ID` | `SH4VT69BJJ` | 当前策略下否 |
| `ASC_ISSUER_ID` | ASC Integrations 页面 UUID | 当前策略下否 |

当前 build number 策略是 `github_run_number`。当 `upload_to_asc=false` 时，ASC `.p8` 不会被使用，所以首次不上传构建不能证明 API Key 有效。

正式发布前建议设置 Environment 防护：

- 至少一个 Required reviewer；
- 条件允许时禁止发起人自审；
- Deployment branches and tags 从 `No restriction` 改为 Selected branches and tags；
- 先只允许 `main`；如以后使用，再加入 `release/*` 和 `ios-v*` Tag；
- 生产环境尽量关闭管理员绕过保护规则。

### 4.5 锁定 Flutter 与 CocoaPods 依赖

Donesome 创建接入分支：

```bash
cd /Users/starburst/Donesome
git switch -c chore/hearthio-cloud-build
```

生成依赖：

```bash
cd Hearthio
flutter pub get
cd ios
pod install
cd ../..
```

`flutter pub get` 出现“有更新版本但不兼容当前约束”只是提示；只要出现 `Got dependencies!` 即成功。本次接入不应顺手升级依赖。

`pod install` 完成后生成：

```text
Hearthio/ios/Podfile.lock
```

本机全局 Git Ignore 忽略 `Podfile.lock`，因此必须显式强制暂存：

```bash
git add -f Hearthio/ios/Podfile.lock
```

Flutter 的以下文件已确认正确包含 Pods xcconfig，所以 CocoaPods 关于自定义 base configuration 的黄色提示不构成本次阻塞：

```text
Hearthio/ios/Flutter/Debug.xcconfig
Hearthio/ios/Flutter/Release.xcconfig
```

云端会使用：

```text
flutter pub get
pod install --project-directory=ios --deployment
```

如果依赖安装修改任何已跟踪文件，Action 会失败，要求先提交锁定后的状态。

### 4.6 将配置和工作流接入 Donesome

在 Donesome 根目录复制中央模板：

```bash
cd /Users/starburst/Donesome

mkdir -p .github/workflows

cp /Users/starburst/Desktop/test/ios-multi-app-cloud-build-system/examples/flutter-app-repository/.github/ios-build.yml \
  .github/ios-build.yml

cp /Users/starburst/Desktop/test/ios-multi-app-cloud-build-system/examples/flutter-app-repository/.github/workflows/ios-release.yml \
  .github/workflows/ios-release.yml
```

固定中央 Action SHA：

```bash
sed -i '' \
  's/<PINNED_FULL_COMMIT_SHA>/838cd4f0009b94381ed186da0366323a25d34988/' \
  .github/workflows/ios-release.yml
```

没有 `rg` 时使用系统自带 `grep` 检查：

```bash
grep -nE 'team_id|asc_app_id|scheme:|uses: CherryIce' \
  .github/ios-build.yml \
  .github/workflows/ios-release.yml
```

预期关键值：

```text
team_id: Z353FCBY9T
asc_app_id: "6804913721"
scheme: Run-Release
uses: CherryIce/...@838cd4f0009b94381ed186da0366323a25d34988
```

精确暂存，避免 `git add .` 带入无关文件：

```bash
git add .github/ios-build.yml
git add .github/workflows/ios-release.yml
git add -f Hearthio/ios/Podfile.lock
git diff --cached --name-status
```

验收必须只有：

```text
A .github/ios-build.yml
A .github/workflows/ios-release.yml
A Hearthio/ios/Podfile.lock
```

本次提交和合并：

```text
App 接入提交：25940b7e6a1ace5939d037628f775fb070876d8e
PR：#1
main 合并提交：5cbb455a8fb684a58db77aa1d13112a711936675
```

### 4.7 SourceTree 缺少 workflow scope

首次推送出现：

```text
refusing to allow an OAuth App to create or update workflow
`.github/workflows/ios-release.yml` without `workflow` scope
```

原因是 SourceTree 当前 GitHub OAuth 能推普通代码，但没有新增或修改 Actions workflow 所需的权限。

处理原则：

- 不删除本地提交；
- 不把 PAT 写进 remote URL；
- 不用 PAT 替换 SourceTree 全局 OAuth；
- 使用只允许访问 Donesome 的短期 fine-grained PAT；
- 通过 `credential.useHttpPath=true` 把凭据隔离到单仓库路径；
- 推送成功后删除临时凭据。

PAT 最小配置：

```text
Resource owner: CherryIce
Repository access: Only select repositories → Donesome
Contents: Read and write
Workflows: Read and write
Expiration: 短期，例如 7 天
```

安全地写入单仓库 Keychain 凭据：

```bash
cd /Users/starburst/Donesome
git config --local credential.useHttpPath true

read -s "repo_pat?粘贴 Donesome PAT（输入不会显示）: "
printf '\n'

printf 'protocol=https\nhost=github.com\npath=CherryIce/Donesome.git\nusername=CherryIce\npassword=%s\n\n' "$repo_pat" \
  | git credential approve

unset repo_pat
git push -u origin chore/hearthio-cloud-build
```

推送后清理：

```bash
printf 'protocol=https\nhost=github.com\npath=CherryIce/Donesome.git\nusername=CherryIce\n\n' \
  | git credential reject

git config --local --unset credential.useHttpPath
```

最后在 GitHub 的 Personal access tokens 页面撤销或删除这个短期 PAT；只从 Keychain 清除凭据并不等于 Token 已失效。

## 5. Apple Developer 账户配置与交接

Apple Developer Program 和 App Store Connect 是相关但不同的权限域。只加入 App Store Connect 不一定拥有 Certificates, Identifiers & Profiles 权限。

### 5.1 需要谁操作

| 事项 | 建议/必要角色 |
| --- | --- |
| 查看 Membership Details、确认 Team ID | Developer Program 团队成员 |
| 管理 App ID、Capabilities、证书、profiles | 组织团队的 Account Holder 或 Admin |
| 新建 App Store Connect distribution profile | Account Holder 或 Admin |
| 导出已有签名身份 `.p12` | 持有对应证书私钥的 Mac 用户 |

如果当前操作者无法登录 Apple Developer 团队，需要让 Account Holder/Admin 执行以下检查并安全交付材料，而不是共享 Apple Account 密码。

### 5.2 Apple Developer 检查清单

1. **Membership**
   - 团队名称与公司主体正确；
   - Team ID 为 `Z353FCBY9T`；
   - 会员未过期，续费责任人明确。
2. **Identifiers**
   - 存在 explicit App ID `com.Hearthio.lite`；
   - App ID Capabilities 与 Hearthio 实际 entitlements 一致；
   - 新增 Push、Sign in with Apple、Associated Domains 等能力后，必须重新生成 profile。
3. **Certificates**
   - 使用有效的 Apple Distribution 身份；
   - `.p12` 内必须同时包含证书和对应私钥；
   - 记录证书到期时间，但不要在文档记录密码；
   - 不要随意撤销正在被 CI profile 使用的 distribution certificate。
4. **Profiles**
   - 类型必须是 App Store Connect distribution；
   - Team ID 为 `Z353FCBY9T`；
   - App Identifier 为 `Z353FCBY9T.com.Hearthio.lite`；
   - profile 必须包含 `.p12` 中同一 distribution certificate；
   - 当前 profile 到期时间为 2027-08-25，建议至少提前 30 天轮换。

中央 Action 会自动拒绝以下 profile：

- 已过期；
- TeamIdentifier 不一致；
- Bundle ID 不匹配；
- 不支持 iOS；
- 不包含导入的 distribution certificate；
- 含设备列表、`ProvisionsAllDevices=true` 或 `get-task-allow=true`，即不是 App Store distribution。

### 5.3 证书/profile 轮换

1. Account Holder/Admin 创建或确认新的 Apple Distribution identity。
2. 由持有私钥的 Mac 导出带强密码的 `.p12`。
3. 选择同一 distribution certificate 重新生成 App Store profile。
4. 本地解码 profile，核对 Team ID、App Identifier、到期时间。
5. 重新生成 `.p12` 和 profiles archive 的 Base64。
6. 在 `hearthio-production` 中更新前三个签名 Secrets。
7. 先运行 `upload_to_asc=false`；只有签名、Export、IPA 检查全部通过后，才恢复正式上传。

## 6. App Store Connect 账户与 API 配置

### 6.1 App 记录

确认 App Store Connect 中存在：

```text
App Name: Hearthio
Platform: iOS
Bundle ID: com.Hearthio.lite
Apple ID / ASC App ID: 6804913721
```

Apple 会通过 IPA 内的 Bundle ID、Marketing Version 和 Build Number，把上传内容关联到对应 App 与版本。

### 6.2 人员角色

| 工作 | Apple 官方允许角色 |
| --- | --- |
| 上传 build | Account Holder、Admin、App Manager、Developer |
| 选择 build 提交 App Review | Account Holder、Admin、App Manager |
| 创建/管理 Team API Key | Account Holder 或 Admin |
| 首次申请 ASC API access | Account Holder |

建议至少安排：

- 一名 Account Holder：负责协议、会员、首次 API access；
- 一名 Admin：负责证书、profiles、Team API Key 和人员交接；
- 日常发布人员：App Manager 或 Developer，按实际职责授予最小权限。

所有 ASC 登录账户应开启双重认证。不应共享个人 Apple Account 密码。

### 6.3 Team API Key

当前中央 Action 使用 Team API Key，并要求：

```text
ASC_API_KEY_P8_BASE64
ASC_KEY_ID=SH4VT69BJJ
ASC_ISSUER_ID=<UUID，仅存 Secret>
```

创建路径：

```text
App Store Connect
→ Users and Access
→ Integrations
→ App Store Connect API
→ Team Keys
```

权限选择：

- 只上传、读取 processing/TestFlight 状态：优先使用 `Developer` 角色做最小权限验证；
- 若设置 `upload.internal_beta_group_ids` 并要求自动把 build 加入 tester group，建议使用 `App Manager`，因为 build 与 tester group 的管理权限更高；
- `Admin` 权限过宽，不应只为上传方便而默认使用。

注意：Team API Key 作用于团队中的所有 App，不能限制为单个 App。若组织安全策略要求 App 级隔离，需要扩展中央 Action 支持个人 API Key 或其他隔离方式，不能仅修改 `asc_key_type` 字符串冒充支持。

`.p8` 只能下载一次。生成后应：

1. 安全保存原文件；
2. 写入 GitHub Environment Secret；
3. 不提交 Git；
4. 丢失或怀疑泄露时立即撤销并生成新 Key。

### 6.4 API Key 轮换

1. Account Holder/Admin 新建 Team API Key，并确定适当角色。
2. 下载新 `.p8`，记录与其匹配的新 Key ID。
3. 确认同一 Integrations 页面上的 Issuer ID。
4. 同一次维护窗口更新：
   - `ASC_API_KEY_P8_BASE64`
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
5. 撤销旧 Key 前先验证新 Key。

当前 `github_run_number + upload_to_asc=false` 不会调用 ASC，因此普通不上传构建不能验证新 `.p8`。应另做授权的只读 ASC API 验证，或在签名 dry-run 已通过后安排一次受控上传验证。确认新 Key 正常后再撤销旧 Key。

### 6.5 TestFlight 后续配置

在第一次正式上传前检查：

- TestFlight Beta App Description；
- Feedback Email；
- Export Compliance/加密问题；
- Internal Testing group；
- 需要内测的 App Store Connect 用户；
- 是否启用自动分发。

当前配置：

```yaml
internal_beta_group_ids: []
```

这表示中央 Action 不会自动把 build 分配给具体 group，只会等待 build 达到内部测试可用状态。以后如需自动分组，应填写 ASC beta group resource ID，并确保 API Key 具备相应权限。

## 7. GitHub 账户与 Environment 配置

### 7.1 仓库权限

维护人员至少需要：

- 能向工作分支推送代码；
- 能创建 PR；
- 能手动运行 Actions；
- Environment 管理员可以配置 Secrets 和 protection rules；
- Required reviewer 能批准 `hearthio-production` deployment。

### 7.2 推荐保护规则

`hearthio-production` 建议配置：

```text
Required reviewers: 至少 1 人
Prevent self-review: 条件允许时启用
Deployment branches/tags: Selected branches and tags
Allowed branch: main
可选：release/*
可选 Tag：ios-v*
Admin bypass: 正式生产环境建议关闭
```

Environment 审批通过前，job 不应读取 Environment Secrets。

### 7.3 SourceTree 与 PAT

SourceTree 全局 GitHub OAuth 继续用于普通仓库操作。只有遇到 workflow scope 缺失时，才临时使用 Donesome 单仓库 fine-grained PAT。

禁止：

- 把 PAT 写成 `https://TOKEN@github.com/...`；
- 把 PAT 写入 `.git/config`；
- 用 PAT 替换 SourceTree 全局 OAuth，导致其他仓库凭据污染；
- 使用不设过期时间、覆盖所有仓库的 classic PAT。

## 8. 首次不上传云构建

### 8.1 启动

打开：

[Donesome → Actions → Flutter iOS Release](https://github.com/CherryIce/Donesome/actions/workflows/ios-release.yml)

点击 `Run workflow`：

```text
Branch: main
marketing_version: 1.0.0
build_number: 留空
upload_to_asc: false / 不勾选
```

如果显示 Waiting：

```text
Review deployments
→ 选择 hearthio-production
→ Approve and deploy
```

### 8.2 预期步骤

1. Checkout Donesome 的精确 `github.sha`；
2. 校验事件、ref、配置、Flutter 工程目录、Xcode 路径；
3. 下载 Flutter 3.35.7 arm64 SDK，并核对 SHA-256；
4. 生成 build number；
5. 执行锁定的 Flutter/CocoaPods 依赖安装；
6. 把 `.p12` 导入临时 Keychain，并映射 profile；
7. 使用 `Run-Release + Release` Archive；
8. 导出唯一 IPA；
9. 校验 IPA Bundle ID、版本号、build number、代码签名、Team ID 和 embedded profile；
10. 上传 `ios-build-<run_id>-<attempt>` Artifact；
11. 清理临时 Keychain、profiles 和敏感目录。

`upload_to_asc=false` 时不会执行：

- Prepare ASC key for upload；
- altool validate/upload；
- ASC processing/TestFlight 状态轮询；
- beta group assignment。

### 8.3 成功验收

Actions 绿色还不够，必须下载并检查 Artifact：

```text
build-metadata.json
ipa-inspection.json
archive.xcresult
export/*.ipa
dSYMs.zip
logs/
```

记录：

- workflow run URL；
- 实际 Donesome `source_sha`；
- 中央 Action 固定 SHA；
- Marketing Version；
- resolved Build Number；
- IPA SHA-256；
- `ipa-inspection.json` 中的 Bundle ID、Team ID、profile UUID；
- Artifact 名称与保留截止时间。

Artifact 目录不得含 `.p12`、`.p8`、`.mobileprovision` 或临时 Keychain。

首次 dry-run 的成功定义是“签名 Archive、Export、IPA 检查和 Artifact 已完成”，不代表 Apple 已接收或 TestFlight 可用。

## 9. 正式 ASC/TestFlight 上传

只有第 8 节全部通过后才执行。

### 9.1 发布前检查

- 确认 Environment Secrets 未过期、未撤销；
- 确认 App Store Connect Agreements 没有阻塞；
- 确认版本号符合发布计划；
- 确认此次 main SHA 已审核；
- 确认没有新的中央 Action SHA 尚未做 dry-run；
- 确认 ASC App ID、Bundle ID、Team ID 未变化；
- 确认新的 build number 不会与 ASC 中已有 build 重复；
- 确认 API Key 角色满足上传和后续 group 操作。

### 9.2 启动

再次运行同一 workflow：

```text
Branch: main
marketing_version: 目标版本，例如 1.0.0
build_number: 通常留空，使用 github_run_number
upload_to_asc: true / 勾选
```

中央 Action 会先留存 IPA Artifact，再准备 `.p8`，执行：

1. `altool --validate-app`；
2. `altool --upload-app`；
3. 查询精确 ASC App、Marketing Version 和 Build Number；
4. 等待 build upload、processing 和 TestFlight internal 状态；
5. 如配置 group IDs，再分配并回读验证；
6. 留存 `asc-status.json`、`build-metadata.json` 和 upload log。

### 9.3 正式成功证据链

必须逐级记录：

```text
精确 github.ref / github.sha
→ Archive 成功
→ IPA 检查与 Artifact
→ Apple upload receipt
→ 精确 ASC build 出现
→ processing_state=VALID
→ testflight_internal_state=READY_FOR_BETA_TESTING 或 IN_BETA_TESTING
→ 如启用 group：group relationship 回读确认
```

仅有上传命令退出码、绿色 Actions、App Store Connect 邮件或模糊截图，都不足以单独证明最终 TestFlight 状态。

## 10. Flutter、Xcode 与中央 Action 升级

### 10.1 Flutter 升级

1. 从 Flutter 官方 macOS releases manifest 选择 stable、arm64 对应版本。
2. 取得官方归档 SHA-256。
3. 更新 Donesome `.github/ios-build.yml`：
   - `flutter.version`
   - `flutter.channel`
   - `flutter.architecture`
   - `flutter.sdk_sha256`
4. 使用新 Flutter 运行 `flutter pub get`。
5. 运行 `pod install`，提交变更后的 `pubspec.lock` 和 `Podfile.lock`。
6. 通过 PR 合并。
7. 先执行 `upload_to_asc=false`。

不要只改版本号而沿用旧 SDK checksum，也不要在云端临时升级依赖后继续发布。

### 10.2 Xcode/runner 升级

GitHub runner 镜像会变化。升级前检查官方 runner image 软件清单，确认：

- `runs-on` 对应的 CPU 架构；
- 配置的 Xcode 路径实际存在；
- Xcode/SDK 满足 Flutter、Pods 和 App Store Connect 上传要求。

改变 runner 或 Xcode 路径后必须先做 dry-run。

### 10.3 中央 Action 升级

1. 在中央 Flutter 分支修改并运行：

```bash
bash tests/run.sh
bash tests/macos-contract.sh
git diff --check
```

2. 推送新中央提交。
3. 在 Donesome PR 中把 `uses: ...@<SHA>` 更新到新的完整 SHA。
4. 合并后运行 `upload_to_asc=false`。
5. 通过后才允许正式上传。

## 11. 常见故障与处理

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `rg: command not found` | 机器未安装 ripgrep | 使用 `grep -nE`；与构建无关 |
| `Got dependencies!` 后提示多个包可更新 | 版本约束内解析成功，只是提示 | 不在接入过程中升级依赖 |
| `Podfile.lock must be committed` | 文件不存在或被全局 ignore | 本地 `pod install`，再 `git add -f Hearthio/ios/Podfile.lock` |
| CocoaPods 自动选择 iOS 13.0 | Podfile 未显式写 platform | 当前与 Xcode deployment target 13.0 一致；后续可单独 PR 显式配置 |
| CocoaPods 提示 custom xcconfig | 项目已有 Flutter xcconfig | 确认 Debug/Release.xcconfig 已 include Pods 配置 |
| `wrong TeamIdentifier` | config 与 profile 不同团队 | 重新解码实际 profile，统一 `team_id` |
| profile 不包含 distribution certificate | `.p12` 与 profile 证书不匹配 | 使用同一证书重导 `.p12` 或重生 profile |
| `No Apple Distribution identity` | `.cer` 没有私钥或 `.p12` 错误 | 从持有私钥的 Mac 重导 `.p12` |
| `Configured Flutter architecture ... does not match runner` | SDK 架构与 runner 不一致 | `macos-26` 配 `arm64`，或成对调整 |
| `configured Xcode does not exist` | runner 镜像已移除路径 | 查官方 runner 清单，更新配置并 dry-run |
| `without workflow scope` | SourceTree OAuth 无 workflow 权限 | 使用 Donesome 单仓库短期 PAT，不污染全局 OAuth |
| Secret 读取为空 | Secret 名称错、Environment 不匹配或未审批 | 核对 `hearthio-production` 与六个名称，完成 deployment approval |
| `ASC_KEY_ID` 格式错误 | 不是 10 位大写字母/数字 | 使用与 `.p8` 文件名匹配的 Key ID |
| `ASC_ISSUER_ID` 格式错误 | 把 Team ID/Key ID 当 Issuer | 使用 Integrations 页面 UUID |
| upload 成功但 ASC 没 build | Apple processing 延迟或版本筛选不匹配 | 查 `asc-status.json` 与 upload log，不重复盲目上传 |
| 等待 TestFlight 超时 | Apple 未完成 processing 或状态异常 | 查精确 build、processing 状态和 ASC 邮件；保留诊断 Artifact |

## 12. 日常发布与轮换检查表

### 每次 dry-run

- [ ] 工作流来自已审核的 Donesome `main` SHA。
- [ ] 中央 Action 使用完整固定 SHA。
- [ ] `marketing_version` 是三段数字。
- [ ] `upload_to_asc=false`。
- [ ] Environment 审批人核对本次 ref/SHA。
- [ ] Artifact 中存在 IPA、metadata、inspection 和日志。
- [ ] IPA Bundle ID、Team ID、profile UUID 正确。
- [ ] Artifact 中没有私钥/profile 原文件。

### 每次正式上传

- [ ] 最近一次相同配置 dry-run 已通过。
- [ ] App Store Connect Agreements 无阻塞。
- [ ] API Key 仍 Active，角色满足操作。
- [ ] build number 唯一。
- [ ] `upload_to_asc=true` 已经过审批。
- [ ] 记录 Apple receipt 和 `asc-status.json`。
- [ ] processing 为 `VALID`。
- [ ] TestFlight 为 `READY_FOR_BETA_TESTING` 或 `IN_BETA_TESTING`。
- [ ] 若配置 group，已回读确认关联。

### 每月/发布前维护

- [ ] Apple Developer Program 会员状态正常。
- [ ] Distribution certificate 未过期、未撤销。
- [ ] profile 距到期不少于 30 天。
- [ ] ASC Team API Key 未撤销。
- [ ] GitHub Environment reviewers 与人员在岗状态正确。
- [ ] 清理已完成用途的短期 PAT。
- [ ] 检查 `macos-26` runner 与 Xcode 路径是否仍受支持。
- [ ] 复核中央 Action 固定 SHA 是否为团队当前批准版本。

## 13. 发布证据记录模板

每次运行复制以下模板到发布记录：

```text
App: Hearthio
Run type: dry-run / ASC upload
Triggered by:
Approved by:
GitHub run URL:
Donesome ref:
Donesome source SHA:
Central action SHA:
Marketing Version:
Build Number:
Flutter Version:
Runner / Xcode:
IPA SHA-256:
Bundle ID:
Team ID:
Profile UUID:
Artifact name:
Artifact retention deadline:
Apple upload receipt: N/A / value
ASC build ID: N/A / value
Build upload state: N/A / value
Processing state: N/A / value
TestFlight internal state: N/A / value
Beta group verification: N/A / value
Known warnings:
Final verdict: archive-only passed / TestFlight ready / failed
```

## 14. 官方参考

- [Apple：Team ID](https://developer.apple.com/help/glossary/team-id/)
- [Apple：导出并共享签名身份 `.p12`](https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates)
- [Apple：创建 App Store Connect provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
- [Apple：App Store Connect API 与 Team Keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
- [Apple：ASC API Key ID、Issuer ID 与 JWT](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [Apple：上传 builds 与所需角色](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple：App Store Connect 角色权限](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions)
- [Apple：添加 TestFlight testers/groups](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-testers-to-builds)
- [GitHub：Deployment Environments 与 Environment Secrets](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [GitHub：手动运行 workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
- [GitHub：fine-grained PAT](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [GitHub：macOS runner 规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub：macOS 26 arm64 镜像软件清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
