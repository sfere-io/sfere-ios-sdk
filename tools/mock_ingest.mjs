// Zero-dependency Node mock of the Sfere ingestion endpoint, for the sample apps and UI flows.
// A trimmed copy of packages/browser/test/e2e/mock-ingest.mjs in fanfinity/sfere-sdk (ingest only,
// no site server), plus fault injection and gzip bodies. Never names the ingestion vendor.
//
//   POST /v1/batch/b  records the batch, answers {ok, receivedEvents, okEvents}
//   GET  /__events    every request handled since the last reset, oldest first
//   POST /__reset     clears the recorded requests and any pending faults
//   POST /__fail      {"status": 503, "count": 2, "retryAfter": 1}: the next `count` batch requests
//                     get `status` (and a Retry-After header when given). They are still recorded.
//
// Port: SFERE_MOCK_PORT (default 4320). Binds 127.0.0.1 only: the iOS Simulator shares the Mac's
// network, and the Android emulator reaches it as 10.0.2.2.
// Start and stop it with tools/mock_ingest_ctl.sh, which is safe to run twice.

import process from "node:process";
import console from "node:console";
import { Buffer } from "node:buffer";
import { createServer } from "node:http";
import { gunzipSync } from "node:zlib";

const HOST = "127.0.0.1";
const PORT = Number(process.env.SFERE_MOCK_PORT || 4320);
const MAX_BODY_BYTES = 5_000_000;
const BATCH_PATHS = new Set(["/v1/batch", "/v1/b", "/v1/batch/b"]);

/** Every request handled since the last /__reset. */
const recordedRequests = [];
/** Pending injected failures for batch requests: {status, remaining, retryAfter}. */
let pendingFault = null;

function readBody(req) {
  return new Promise((settle, fail) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        req.destroy();
        fail(Object.assign(new Error("payload too large"), { code: "TOO_LARGE" }));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => settle(Buffer.concat(chunks)));
    req.on("error", fail);
  });
}

/** `Authorization: Basic base64(writeKey:)` -> the write key, with the trailing ":" stripped. */
function keyFromAuth(headerValue) {
  if (typeof headerValue !== "string" || !headerValue.startsWith("Basic ")) return undefined;
  const decoded = Buffer.from(headerValue.slice("Basic ".length), "base64").toString("utf8");
  return decoded.endsWith(":") ? decoded.slice(0, -1) : decoded;
}

function sendJson(res, status, payload, extraHeaders) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function parseJson(text) {
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return { __unparsed: text };
  }
}

async function handleRequest(req, res) {
  const url = new URL(req.url ?? "/", `http://${HOST}:${PORT}`);

  if (req.method === "GET" && url.pathname === "/__events") {
    sendJson(res, 200, recordedRequests);
    return;
  }
  if (req.method === "POST" && url.pathname === "/__reset") {
    recordedRequests.length = 0;
    pendingFault = null;
    sendJson(res, 200, { ok: true });
    return;
  }

  let rawBody;
  try {
    rawBody = await readBody(req);
  } catch (error) {
    sendJson(res, error?.code === "TOO_LARGE" ? 413 : 400, { ok: false, error: "bad request" });
    return;
  }

  if (req.method === "POST" && url.pathname === "/__fail") {
    const request = parseJson(rawBody.toString("utf8"));
    const status = Number(request.status);
    const count = Number(request.count ?? 1);
    if (!Number.isInteger(status) || status < 400 || status > 599 || !Number.isInteger(count) || count < 1) {
      sendJson(res, 400, { ok: false, error: "expected {status: 400-599, count: >= 1}" });
      return;
    }
    pendingFault = { status, remaining: count, retryAfter: request.retryAfter };
    sendJson(res, 200, { ok: true, status, count });
    return;
  }

  const gzipped = /gzip/i.test(String(req.headers["content-encoding"] ?? ""));
  let text;
  try {
    text = (gzipped ? gunzipSync(rawBody) : rawBody).toString("utf8");
  } catch {
    sendJson(res, 400, { ok: false, error: "body is not valid gzip" });
    return;
  }
  const body = parseJson(text);
  const record = {
    method: req.method ?? "",
    path: url.pathname,
    headers: { ...req.headers },
    gzipped,
    body,
    timestamp: Date.now(),
  };

  if (req.method !== "POST" || !BATCH_PATHS.has(url.pathname)) {
    recordedRequests.push({ ...record, unexpected: true });
    sendJson(res, 404, { ok: false, error: "not found" });
    return;
  }

  const batch = Array.isArray(body.batch) ? body.batch : [];
  const writeKey = keyFromAuth(req.headers.authorization) ?? (typeof body.writeKey === "string" ? body.writeKey : undefined);
  if (pendingFault) {
    const { status, retryAfter } = pendingFault;
    pendingFault.remaining -= 1;
    if (pendingFault.remaining <= 0) pendingFault = null;
    recordedRequests.push({ ...record, writeKey: writeKey ?? null, batchSize: batch.length, injectedStatus: status });
    sendJson(res, status, { ok: false, error: "injected failure" }, retryAfter != null ? { "Retry-After": String(retryAfter) } : undefined);
    return;
  }

  recordedRequests.push({ ...record, writeKey: writeKey ?? null, batchSize: batch.length });
  if (!writeKey) {
    sendJson(res, 200, { ok: false, error: "stream not found" });
    return;
  }
  sendJson(res, 200, { ok: true, receivedEvents: batch.length, okEvents: batch.length });
}

const server = createServer((req, res) => {
  handleRequest(req, res).catch(() => sendJson(res, 500, { ok: false, error: "mock error" }));
});

server.listen(PORT, HOST, () => {
  console.log(`mock-ingest: listening on http://${HOST}:${PORT}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close();
    process.exit(0);
  });
}
