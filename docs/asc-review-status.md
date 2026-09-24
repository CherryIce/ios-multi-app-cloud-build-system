# ASC 审核进度通知与手动查询

这套能力覆盖两条互相独立的路径：

```text
App Store Connect 状态变化
  -> Apple Webhook
  -> asc-review Worker（HMAC-SHA256 验签）
  -> 团队自己的 HTTPS 通知端点

GitHub Actions workflow_dispatch
  -> review-status composite action
  -> App Store Connect API 精确查询 App + iOS 版本
  -> Job Summary + JSON Artifact + 可选通知端点
```

Webhook 是主要路径，Apple 在 App Store version 状态变化时主动投递；手动查询用于检查漏通知、通知服务故障或历史版本当前状态。两条路径不会把 CI 成功当成 Apple 审核成功。

## 主动通知

`webhooks/asc-review/src/index.mjs` 是基于 Web Standard API 的轻量接收器，附带 Cloudflare Workers 配置样例。它会：

1. 只接受 `POST`，并限制请求体为 1 MiB。
2. 使用原始请求体和 `ASC_WEBHOOK_SECRET` 校验 `x-apple-signature: hmacsha256=...`。
3. 接受 Apple 的 `webhookPings` 测试事件；Ping 会校验通知目标已配置，但不向业务通知端点转发测试消息。
4. 只转发 `appStoreVersionAppVersionStateUpdated` 审核状态事件，其他已验签事件返回 `202`。
5. 把事件规范化后 `POST` 到 `NOTIFICATION_WEBHOOK_URL`；目标未返回 2xx 时，本接收器返回 502，让 Apple 将本次投递记录为失败，便于在 App Store Connect 重发。
6. 配置 `ASC_EVENT_DEDUP_KV` 后，以 Apple event ID 做七天尽力去重；仅在通知端点成功接收后写入去重记录，KV 故障不会要求 Apple 重发已经转发成功的通知。

### 部署示例

Cloudflare 推荐新项目使用 `wrangler.jsonc`。复制样例并替换非敏感的 App 名称和 ASC App ID：

```bash
cd webhooks/asc-review
cp wrangler.jsonc.example wrangler.jsonc
npx wrangler secret put ASC_WEBHOOK_SECRET
npx wrangler secret put NOTIFICATION_WEBHOOK_URL
npx wrangler secret put NOTIFICATION_WEBHOOK_BEARER
npx wrangler deploy
```

`NOTIFICATION_WEBHOOK_BEARER` 可选；通知端点不需要 bearer token 时无需创建该 secret。`ASC_WEBHOOK_SECRET` 与 App Store Connect Webhook 配置中填写的 Secret 必须完全一致。Webhook URL、bearer token 和 Apple secret 都可能授权外部调用，必须保存在部署平台的 secret store，不要写入 `wrangler.jsonc` 或 Git。

如需去重，先创建 KV namespace，并按 `wrangler.jsonc.example` 中的注释绑定为 `ASC_EVENT_DEDUP_KV`。不配置 KV 时仍可正常使用，但通知消费方应按 `event_id` 幂等处理 Apple 重发。

部署后可检查：

```bash
curl --fail-with-body https://<worker-host>/health
```

### 在 App Store Connect 注册

在 App Store Connect 的 Users and Access -> Integrations -> Webhooks 中，为目标 App 创建 Webhook：

- Payload URL：部署后的 Worker HTTPS URL。
- Secret：与 `ASC_WEBHOOK_SECRET` 相同的高强度随机字符串。
- Event trigger：App Store version app version state updated，对应 API 枚举 `APP_STORE_VERSION_APP_VERSION_STATE_UPDATED`。

创建后使用 App Store Connect 的 Test 功能发送 Ping，并在 Recent Deliveries 确认返回成功。每个 Webhook 只绑定一个 App；多个 App 可以分别创建配置，但应使用隔离的 secret 和可识别的 `APP_DISPLAY_NAME`。

Apple 文档：

- [Manage webhooks](https://developer.apple.com/help/app-store-connect/manage-your-team/manage-webhooks)
- [Configuring and parsing App Store Connect API webhook notifications](https://developer.apple.com/documentation/appstoreconnectapi/configuring-webhook-notifications)
- [WebhookEventType](https://developer.apple.com/documentation/appstoreconnectapi/webhookeventtype)

### 转发 Payload

通知端点收到 JSON，关键字段如下：

```json
{
  "schema_version": 1,
  "source": "app_store_connect_webhook",
  "event_id": "event-uuid",
  "event_type": "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
  "app_id": "1234567890",
  "app_display_name": "ExampleApp",
  "app_store_version_id": "version-resource-id",
  "marketing_version": null,
  "old_state": "WAITING_FOR_REVIEW",
  "new_state": "IN_REVIEW",
  "status_group": "in_review",
  "attention_required": false,
  "terminal": false,
  "timestamp": "2026-09-24T00:59:00Z",
  "received_at": "2026-09-24T01:02:03.000Z",
  "text": "[ASC] ExampleApp review state: WAITING_FOR_REVIEW -> IN_REVIEW"
}
```

Apple 的状态变更事件给出 App Store version resource ID，而不是 marketing version，所以主动通知里的 `marketing_version` 为 `null`。需要显示版本号时，由通知服务按 `app_store_version_id` 关联，或运行下面的手动查询。

## 手动查询兜底

将 `examples/app-repository/.github/workflows/asc-review-status.yml` 复制到 App 仓库，并替换：

- `<PINNED_FULL_COMMIT_SHA>`：本仓库经过审核的完整 commit SHA。
- `environment`：App 仓库实际使用的受保护 GitHub Environment。
- `app_id`：目标 App 的数字 ASC App ID。

Environment 至少需要：

- `ASC_API_KEY_P8_BASE64`
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`

需要把手动查询结果也推送到通知服务时，再配置：

- `ASC_REVIEW_NOTIFICATION_WEBHOOK_URL`
- `ASC_REVIEW_NOTIFICATION_WEBHOOK_BEARER`（可选）

在 Actions 页面运行 `ASC Review Status`，输入精确 marketing version。Action 只接受两段或三段数字版本号，只查询 `platform=IOS` 且 `versionString` 精确匹配的记录；找不到或返回多条时会失败，不会回退到其他版本。

查询结果写入 GitHub Job Summary，同时生成 `asc-review-status.json` Artifact。手动查询成功后，即使可选通知端点不可用，Action 也会保留并展示 ASC 状态，把 `notification_sent` 设为 `false` 并在 JSON 中记录 `notification_error`；通知故障不会掩盖查询结果。主要输出包括：

- `app_store_version_state`：Apple 原始状态，例如 `WAITING_FOR_REVIEW`、`IN_REVIEW`、`REJECTED`、`READY_FOR_DISTRIBUTION`。
- `status_group`：本仓库的归类，例如 `review_queue`、`in_review`、`approved`、`released`、`attention_required`。
- `attention_required`：拒审、元数据拒绝、无效二进制或等待出口合规处理时为 `true`。
- `terminal`：版本已发布或已被新版本替代时为 `true`。拒审等需处理状态仍可能修复并重新提交，因此不会被标记为 terminal。

## 证据边界

- 本仓库自测可证明 JWT、精确版本选择、状态归类、HMAC 验签、转发和失败处理的静态/契约行为。
- 只有 App Store Connect Recent Deliveries 中的真实成功记录才能证明 Apple 已把 Webhook 投递到线上端点。
- 只有手动查询返回的实时 API 结果或 App Store Connect 页面才能证明某一时刻的审核状态。
- GitHub workflow 成功、IPA 上传成功或 TestFlight ready 都不等于 App Review 已通过。
