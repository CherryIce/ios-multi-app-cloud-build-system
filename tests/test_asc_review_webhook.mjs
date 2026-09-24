import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { handleAscReviewWebhook } from "../webhooks/asc-review/src/index.mjs";

const SECRET = "apple-webhook-secret";
const NOW = new Date("2026-09-24T01:02:03Z");

function signature(body, secret = SECRET) {
  return `hmacsha256=${createHmac("sha256", secret).update(body).digest("hex")}`;
}

function reviewEvent() {
  return {
    data: {
      type: "appStoreVersionAppVersionStateUpdated",
      id: "event-123",
      version: 1,
      attributes: {
        oldValue: "WAITING_FOR_REVIEW",
        newValue: "IN_REVIEW",
        timestamp: "2026-09-24T00:59:00Z",
      },
      relationships: {
        instance: {
          data: { type: "appStoreVersions", id: "version-123" },
        },
      },
    },
  };
}

function signedRequest(payload, secret = SECRET) {
  const body = JSON.stringify(payload);
  return new Request("https://asc-review.example.test/", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-apple-signature": signature(body, secret),
    },
    body,
  });
}

function environment(overrides = {}) {
  return {
    ASC_WEBHOOK_SECRET: SECRET,
    NOTIFICATION_WEBHOOK_URL: "https://notify.example.test/asc",
    NOTIFICATION_WEBHOOK_BEARER: "notification-token",
    APP_DISPLAY_NAME: "ExampleApp",
    ASC_APP_ID: "1234567890",
    ...overrides,
  };
}

test("verifies Apple signature and forwards a normalized review transition", async () => {
  let forwarded;
  const response = await handleAscReviewWebhook(signedRequest(reviewEvent()), environment(), {
    now: () => NOW,
    fetch: async (url, options) => {
      forwarded = { url, options };
      return new Response(null, { status: 204 });
    },
  });

  assert.equal(response.status, 200);
  assert.equal(forwarded.url, "https://notify.example.test/asc");
  assert.equal(forwarded.options.headers.authorization, "Bearer notification-token");
  const notification = JSON.parse(forwarded.options.body);
  assert.equal(notification.event_id, "event-123");
  assert.equal(notification.app_store_version_id, "version-123");
  assert.equal(notification.old_state, "WAITING_FOR_REVIEW");
  assert.equal(notification.new_state, "IN_REVIEW");
  assert.equal(notification.status_group, "in_review");
  assert.equal(notification.attention_required, false);
  assert.equal(notification.terminal, false);
  assert.equal(notification.text, "[ASC] ExampleApp review state: WAITING_FOR_REVIEW -> IN_REVIEW");
  assert.equal(notification.received_at, "2026-09-24T01:02:03.000Z");
  assert.equal(forwarded.options.body.includes("notification-token"), false);
});

test("rejects an invalid signature without calling the notification endpoint", async () => {
  let calls = 0;
  const response = await handleAscReviewWebhook(signedRequest(reviewEvent(), "wrong-secret"), environment(), {
    fetch: async () => {
      calls += 1;
      return new Response(null, { status: 204 });
    },
  });

  assert.equal(response.status, 401);
  assert.equal(calls, 0);
});

test("accepts Apple's signed ping without forwarding a user notification", async () => {
  let calls = 0;
  const ping = {
    data: {
      type: "webhookPings",
      relationships: { webhook: { data: { type: "webhooks", id: "webhook-1" } } },
    },
  };
  const response = await handleAscReviewWebhook(signedRequest(ping), environment(), {
    fetch: async () => {
      calls += 1;
      return new Response(null, { status: 204 });
    },
  });

  assert.equal(response.status, 200);
  assert.equal(calls, 0);
  assert.deepEqual(await response.json(), { ok: true, ping: true });
});

test("fails Apple's ping when the notification destination is not configured", async () => {
  const ping = {
    data: {
      type: "webhookPings",
      relationships: { webhook: { data: { type: "webhooks", id: "webhook-1" } } },
    },
  };
  const response = await handleAscReviewWebhook(
    signedRequest(ping),
    environment({ NOTIFICATION_WEBHOOK_URL: "" }),
  );

  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: "server_not_configured" });
});

test("suppresses an event already recorded in the optional KV namespace", async () => {
  let calls = 0;
  const kv = {
    get: async (key) => (key === "event-123" ? "1" : null),
    put: async () => assert.fail("duplicate event must not be written again"),
  };
  const response = await handleAscReviewWebhook(
    signedRequest(reviewEvent()),
    environment({ ASC_EVENT_DEDUP_KV: kv }),
    {
      fetch: async () => {
        calls += 1;
        return new Response(null, { status: 204 });
      },
    },
  );

  assert.equal(response.status, 200);
  assert.equal(calls, 0);
  assert.deepEqual(await response.json(), { ok: true, duplicate: true });
});

test("returns a retryable failure and does not mark delivery when notification forwarding fails", async () => {
  let writes = 0;
  const kv = {
    get: async () => null,
    put: async () => {
      writes += 1;
    },
  };
  const response = await handleAscReviewWebhook(
    signedRequest(reviewEvent()),
    environment({ ASC_EVENT_DEDUP_KV: kv }),
    {
      fetch: async () => new Response(null, { status: 503 }),
    },
  );

  assert.equal(response.status, 502);
  assert.equal(writes, 0);
});

test("does not request a duplicate Apple delivery when optional KV recording fails after forwarding", async () => {
  const kv = {
    get: async () => null,
    put: async () => {
      throw new Error("KV unavailable");
    },
  };
  const response = await handleAscReviewWebhook(
    signedRequest(reviewEvent()),
    environment({ ASC_EVENT_DEDUP_KV: kv }),
    {
      fetch: async () => new Response(null, { status: 204 }),
    },
  );

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    event_id: "event-123",
    dedup_recorded: false,
  });
});
