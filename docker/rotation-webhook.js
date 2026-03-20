#!/usr/bin/env node

// Lightweight webhook listener for CipherTrust secret rotation events.
// Receives POST from CipherTrust (Akeyless) event notifications and triggers
// `openclaw secrets reload` to pick up rotated values.
//
// Disabled by default. Enable via env var:
//   ROTATION_WEBHOOK_ENABLED=true
//   ROTATION_WEBHOOK_PORT=9090        (default: 9090)
//   ROTATION_WEBHOOK_TOKEN=<shared>   (optional: require Bearer token)

"use strict";

const http = require("http");
const { execSync } = require("child_process");

const ENABLED = (process.env.ROTATION_WEBHOOK_ENABLED || "").toLowerCase() === "true";
const PORT = parseInt(process.env.ROTATION_WEBHOOK_PORT || "9090", 10);
const TOKEN = process.env.ROTATION_WEBHOOK_TOKEN || "";
const RELOAD_CMD = "openclaw secrets reload";
const COOLDOWN_MS = parseInt(process.env.ROTATION_WEBHOOK_COOLDOWN_MS || "10000", 10);

if (!ENABLED) {
  console.log("[rotation-webhook] Disabled (set ROTATION_WEBHOOK_ENABLED=true to enable)");
  process.exit(0);
}

let lastReload = 0;

function respond(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  // Health endpoint — always available
  if (req.method === "GET" && req.url === "/health") {
    return respond(res, 200, { status: "ok", enabled: true, lastReload });
  }

  // Reload endpoint — POST only
  if (req.method === "POST" && (req.url === "/reload" || req.url === "/v1/reload")) {
    // Token auth (if configured)
    if (TOKEN) {
      const auth = req.headers["authorization"] || "";
      if (auth !== "Bearer " + TOKEN) {
        console.log("[rotation-webhook] Rejected: invalid token");
        return respond(res, 401, { error: "unauthorized" });
      }
    }

    // Cooldown — prevent rapid-fire reloads if multiple secrets rotate at once
    const now = Date.now();
    if (now - lastReload < COOLDOWN_MS) {
      const waitMs = COOLDOWN_MS - (now - lastReload);
      console.log("[rotation-webhook] Cooldown active, skipping (" + waitMs + "ms remaining)");
      return respond(res, 429, { status: "cooldown", retryAfterMs: waitMs });
    }

    // Drain request body (CipherTrust may send event payload)
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      console.log("[rotation-webhook] Rotation event received" + (body ? " (payload: " + body.length + " bytes)" : ""));

      try {
        execSync(RELOAD_CMD, { timeout: 30000, stdio: "pipe" });
        lastReload = Date.now();
        console.log("[rotation-webhook] Secrets reloaded successfully");
        respond(res, 200, { status: "reloaded", timestamp: lastReload });
      } catch (err) {
        console.error("[rotation-webhook] Reload failed: " + (err.stderr ? err.stderr.toString().trim() : err.message));
        respond(res, 500, { error: "reload failed", message: err.message });
      }
    });
    return;
  }

  respond(res, 404, { error: "not found" });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log("[rotation-webhook] Listening on port " + PORT);
  console.log("[rotation-webhook] Token auth: " + (TOKEN ? "enabled" : "disabled"));
  console.log("[rotation-webhook] Cooldown: " + COOLDOWN_MS + "ms");
});
