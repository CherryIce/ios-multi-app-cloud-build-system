const MAX_BODY_BYTES = 1024 * 1024;
const SIGNATURE_PREFIX = "hmacsha256=";
const REVIEW_EVENT_TYPE = "appStoreVersionAppVersionStateUpdated";
const DEDUP_TTL_SECONDS = 7 * 24 * 60 * 60;
const STATE_GROUPS = Object.freeze({
  PREPARE_FOR_SUBMISSION: "draft",
  READY_FOR_REVIEW: "review_queue",
  WAITING_FOR_REVIEW: "review_queue",
  IN_REVIEW: "in_review",
  ACCEPTED: "approved",
  PENDING_APPLE_RELEASE: "approved",
  PENDING_DEVELOPER_RELEASE: "approved",
  PROCESSING_FOR_DISTRIBUTION: "processing",
  PROCESSING_FOR_APP_STORE: "processing",
  READY_FOR_DISTRIBUTION: "released",
  READY_FOR_SALE: "released",
  WAITING_FOR_EXPORT_COMPLIANCE: "attention_required",
  INVALID_BINARY: "attention_required",
  METADATA_REJECTED: "attention_required",
  REJECTED: "attention_required",
  DEVELOPER_REJECTED: "attention_required",
  REPLACED_WITH_NEW_VERSION: "superseded",
});

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function bytesFromHex(value) {
  if (!/^[0-9a-f]{64}$/i.test(value)) return null;
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < value.length; index += 2) {
    bytes[index / 2] = Number.parseInt(value.slice(index, index + 2), 16);
  }
  return bytes;
}

function constantTimeEqual(left, right) {
  if (!left || !right || left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

async function validAppleSignature(body, signatureHeader, secret) {
  if (!signatureHeader?.toLowerCase().startsWith(SIGNATURE_PREFIX)) return false;
  const provided = bytesFromHex(signatureHeader.slice(SIGNATURE_PREFIX.length));
  if (!provided) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  return constantTimeEqual(expected, provided);
}

function notificationPayload(payload, env, receivedAt) {
  const data = payload.data;
  const attributes = data.attributes ?? {};
  const versionId = data.relationships?.instance?.data?.id ?? null;
  const oldState = attributes.oldValue ?? null;
  const newState = attributes.newValue ?? null;
  const statusGroup = STATE_GROUPS[newState] ?? "unknown";
  const appLabel = env.APP_DISPLAY_NAME || env.ASC_APP_ID || "iOS app";
  const transition = oldState ? `${oldState} -> ${newState}` : String(newState);

  return {
    schema_version: 1,
    source: "app_store_connect_webhook",
    event_id: data.id,
    event_type: "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
    app_id: env.ASC_APP_ID || null,
    app_display_name: env.APP_DISPLAY_NAME || null,
    app_store_version_id: versionId,
    marketing_version: null,
    old_state: oldState,
    new_state: newState,
    status_group: statusGroup,
    attention_required: statusGroup === "attention_required",
    terminal: ["released", "superseded"].includes(statusGroup),
    timestamp: attributes.timestamp ?? receivedAt,
    received_at: receivedAt,
    text: `[ASC] ${appLabel} review state: ${transition}`,
  };
}

function validateReviewEvent(payload) {
  const data = payload?.data;
  if (!data || data.type !== REVIEW_EVENT_TYPE) return false;
  return Boolean(
    typeof data.id === "string" &&
      typeof data.attributes?.newValue === "string" &&
      typeof data.relationships?.instance?.data?.id === "string",
  );
}

function notificationTarget(env) {
  if (!env.NOTIFICATION_WEBHOOK_URL) {
    throw new Error("NOTIFICATION_WEBHOOK_URL is not configured");
  }
  let target;
  try {
    target = new URL(env.NOTIFICATION_WEBHOOK_URL);
  } catch {
    throw new Error("NOTIFICATION_WEBHOOK_URL is invalid");
  }
  if (target.protocol !== "https:" || target.username || target.password || target.hash) {
    throw new Error("NOTIFICATION_WEBHOOK_URL must be HTTPS without credentials or a fragment");
  }
  return target;
}

async function forwardNotification(payload, env, fetcher) {
  const target = notificationTarget(env);

  const headers = { "content-type": "application/json" };
  if (env.NOTIFICATION_WEBHOOK_BEARER) {
    headers.authorization = `Bearer ${env.NOTIFICATION_WEBHOOK_BEARER}`;
  }
  const response = await fetcher(target.toString(), {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`notification webhook returned HTTP ${response.status}`);
  }
}

export async function handleAscReviewWebhook(request, env, dependencies = {}) {
  const fetcher = dependencies.fetch ?? fetch;
  const receivedAt = (dependencies.now?.() ?? new Date()).toISOString();
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/health") {
    return jsonResponse({ ok: true, service: "asc-review-webhook" });
  }
  if (request.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }
  if (!env.ASC_WEBHOOK_SECRET) {
    return jsonResponse({ error: "server_not_configured" }, 500);
  }

  const contentLength = Number.parseInt(request.headers.get("content-length") || "0", 10);
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }

  const authenticated = await validAppleSignature(
    body,
    request.headers.get("x-apple-signature"),
    env.ASC_WEBHOOK_SECRET,
  );
  if (!authenticated) {
    return jsonResponse({ error: "invalid_signature" }, 401);
  }

  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  try {
    notificationTarget(env);
  } catch {
    return jsonResponse({ error: "server_not_configured" }, 500);
  }

  if (payload?.data?.type === "webhookPings") {
    return jsonResponse({ ok: true, ping: true });
  }
  if (payload?.data?.type !== REVIEW_EVENT_TYPE) {
    return jsonResponse({ ok: true, ignored: true }, 202);
  }
  if (!validateReviewEvent(payload)) {
    return jsonResponse({ error: "invalid_review_event" }, 422);
  }

  const eventId = payload.data.id;
  if (env.ASC_EVENT_DEDUP_KV && (await env.ASC_EVENT_DEDUP_KV.get(eventId))) {
    return jsonResponse({ ok: true, duplicate: true });
  }

  const notification = notificationPayload(payload, env, receivedAt);
  try {
    await forwardNotification(notification, env, fetcher);
  } catch (error) {
    return jsonResponse({ error: "notification_delivery_failed", detail: error.message }, 502);
  }

  let dedupRecorded = null;
  if (env.ASC_EVENT_DEDUP_KV) {
    try {
      await env.ASC_EVENT_DEDUP_KV.put(eventId, "1", { expirationTtl: DEDUP_TTL_SECONDS });
      dedupRecorded = true;
    } catch {
      // The notification has already been accepted. Avoid asking Apple to resend it
      // solely because the optional best-effort deduplication store is unavailable.
      dedupRecorded = false;
    }
  }
  return jsonResponse({ ok: true, event_id: eventId, dedup_recorded: dedupRecorded });
}

export default {
  fetch(request, env) {
    return handleAscReviewWebhook(request, env);
  },
};
