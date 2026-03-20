#!/usr/local/bin/node

// OpenClaw exec SecretRef provider for Thales CipherTrust Secrets Manager (powered by Akeyless).
// Speaks the OpenClaw exec protocol: reads JSON from stdin, writes JSON to stdout.
//
// Modes:
//   (default)        — reads IDs from stdin, returns secret values (OpenClaw exec protocol)
//   --list           — lists provisioned secret IDs under the configured prefix, outputs JSON array
//   --health-check   — verifies auth and exits

"use strict";

const https = require("https");
const http = require("http");

// ---------------------------------------------------------------------------
// CLI args & env
// ---------------------------------------------------------------------------

function getArg(name) {
  const idx = process.argv.indexOf(name);
  return idx !== -1 && idx + 1 < process.argv.length ? process.argv[idx + 1] : null;
}

const GATEWAY_URL = (getArg("--gateway-url") || process.env.AKEYLESS_GATEWAY_URL || "").replace(/\/+$/, "");
const SECRET_PREFIX = (getArg("--secret-prefix") || process.env.AKEYLESS_SECRET_PREFIX || "").replace(/\/+$/, "");
const ACCESS_ID = process.env.AKEYLESS_ACCESS_ID;
const ACCESS_KEY = process.env.AKEYLESS_ACCESS_KEY;
const HEALTH_CHECK = process.argv.includes("--health-check");
const LIST_MODE = process.argv.includes("--list");

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

function post(url, body, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === "https:" ? https : http;
    const payload = JSON.stringify(body);

    const req = mod.request(
      {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(payload),
        },
        timeout: timeoutMs,
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              resolve(JSON.parse(data));
            } catch {
              reject(new Error(`Invalid JSON from Akeyless: ${data.slice(0, 200)}`));
            }
          } else {
            let detail = data.slice(0, 300);
            try { detail = JSON.parse(data).message || detail; } catch {}
            reject(new Error(`Akeyless ${parsed.pathname} HTTP ${res.statusCode}: ${detail}`));
          }
        });
      },
    );
    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error(`Akeyless ${parsed.pathname} timed out after ${timeoutMs}ms`));
    });
    req.write(payload);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Akeyless operations
// ---------------------------------------------------------------------------

async function authenticate() {
  if (!GATEWAY_URL) throw new Error("AKEYLESS_GATEWAY_URL is required (or pass --gateway-url)");
  if (!ACCESS_ID) throw new Error("AKEYLESS_ACCESS_ID env var is required");
  if (!ACCESS_KEY) throw new Error("AKEYLESS_ACCESS_KEY env var is required");

  const resp = await post(`${GATEWAY_URL}/v2/auth`, {
    "access-id": ACCESS_ID,
    "access-key": ACCESS_KEY,
    "access-type": "access_key",
  });

  if (!resp.token) throw new Error("Akeyless auth response missing token field");
  return resp.token;
}

async function getSecrets(token, fullPaths) {
  return await post(`${GATEWAY_URL}/v2/get-secret-value`, {
    names: fullPaths,
    token,
  });
}

async function listItems(token, path) {
  return await post(`${GATEWAY_URL}/v2/list-items`, { path, token });
}

function expandId(id) {
  if (id.startsWith("/")) return id;
  return SECRET_PREFIX ? `${SECRET_PREFIX}/${id}` : `/${id}`;
}

function shortenPath(fullPath) {
  if (SECRET_PREFIX && fullPath.startsWith(SECRET_PREFIX + "/")) {
    return fullPath.slice(SECRET_PREFIX.length + 1);
  }
  return fullPath;
}

function extractItems(resp) {
  const names = [];
  if (resp.items && Array.isArray(resp.items)) {
    for (const item of resp.items) {
      const name = typeof item === "string" ? item : item.item_name || item.name || "";
      if (name) names.push(name);
    }
  }
  const folders = [];
  if (resp.folders && Array.isArray(resp.folders)) {
    for (const f of resp.folders) {
      if (typeof f === "string" && f) folders.push(f.replace(/\/+$/, ""));
    }
  }
  return { names, folders };
}

// ---------------------------------------------------------------------------
// List mode: discover provisioned secrets (recursive into subfolders)
// ---------------------------------------------------------------------------

async function listSecrets() {
  try {
    const token = await authenticate();
    const startPath = SECRET_PREFIX || "/";
    const allNames = [];
    const queue = [startPath];

    while (queue.length > 0) {
      const path = queue.shift();
      try {
        const resp = await listItems(token, path);
        const { names, folders } = extractItems(resp);
        allNames.push(...names);
        queue.push(...folders);
      } catch {
        // folder might not exist or be empty — skip silently
      }
    }

    const shortIds = allNames.map((n) => shortenPath(n));
    process.stdout.write(JSON.stringify(shortIds));
    process.exit(0);
  } catch (err) {
    process.stderr.write(`List failed: ${err.message}\n`);
    process.stdout.write("[]");
    process.exit(0);
  }
}

// ---------------------------------------------------------------------------
// Health check mode
// ---------------------------------------------------------------------------

async function healthCheck() {
  try {
    const token = await authenticate();
    process.stdout.write(JSON.stringify({ status: "ok", token_prefix: token.substring(0, 10) + "..." }) + "\n");
    process.exit(0);
  } catch (err) {
    process.stderr.write(`Health check failed: ${err.message}\n`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// Main: OpenClaw exec protocol
// ---------------------------------------------------------------------------

async function main() {
  if (HEALTH_CHECK) return healthCheck();
  if (LIST_MODE) return listSecrets();

  let input = "";
  for await (const chunk of process.stdin) input += chunk;

  let request;
  try {
    request = JSON.parse(input);
  } catch {
    process.stderr.write(`Invalid JSON on stdin: ${input.slice(0, 200)}\n`);
    process.exit(1);
  }

  if (request.protocolVersion !== 1) {
    process.stderr.write(`Unsupported protocol version: ${request.protocolVersion}\n`);
    process.exit(1);
  }

  const ids = request.ids || [];
  if (ids.length === 0) {
    process.stdout.write(JSON.stringify({ protocolVersion: 1, values: {} }));
    return;
  }

  const values = {};
  const errors = {};

  let token;
  try {
    token = await authenticate();
  } catch (err) {
    for (const id of ids) errors[id] = { message: `auth failed: ${err.message}` };
    process.stdout.write(JSON.stringify({ protocolVersion: 1, values: {}, errors }));
    return;
  }

  const idToPath = {};
  for (const id of ids) idToPath[id] = expandId(id);

  // Batch fetch — all requested IDs must exist for batch to succeed.
  // When called after --list filtering, this should always succeed.
  const fullPaths = Object.values(idToPath);
  let secretMap = {};
  try {
    secretMap = await getSecrets(token, fullPaths);
  } catch {
    // Batch failed — fall back to individual fetches.
    const results = await Promise.allSettled(
      ids.map(async (id) => {
        const path = idToPath[id];
        const resp = await getSecrets(token, [path]);
        return { id, value: resp[path] };
      }),
    );
    for (const result of results) {
      if (result.status === "fulfilled" && result.value.value != null) {
        values[result.value.id] = String(result.value.value);
      } else {
        const id = result.status === "fulfilled" ? result.value.id : ids[results.indexOf(result)];
        errors[id] = { message: result.reason?.message || `secret not found: ${idToPath[id]}` };
      }
    }
    const response = { protocolVersion: 1, values };
    if (Object.keys(errors).length > 0) response.errors = errors;
    process.stdout.write(JSON.stringify(response));
    return;
  }

  for (const id of ids) {
    const path = idToPath[id];
    const val = secretMap[path];
    if (val != null) {
      values[id] = String(val);
    } else {
      errors[id] = { message: `secret not found: ${path}` };
    }
  }

  const response = { protocolVersion: 1, values };
  if (Object.keys(errors).length > 0) response.errors = errors;
  process.stdout.write(JSON.stringify(response));
}

main().catch((err) => {
  process.stderr.write(`Fatal: ${err.message}\n`);
  process.exit(1);
});
