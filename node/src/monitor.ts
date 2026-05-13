// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary

import { createServer, type Server } from "node:http";

import type { NodeContext } from "./nodeContext";

const DEFAULT_MONITOR_HOST = "0.0.0.0";
const DEFAULT_MONITOR_PORT = 9080;

export type MonitorRuntimeState = {
  booting: boolean;
  listenersStarted: boolean;
  shutdownRequested: boolean;
  autoRegister: boolean;
  autoUnregister: boolean;
  registration: {
    attempted: boolean;
    succeeded: boolean;
    txDigest: string | null;
    lastError: string | null;
  };
};

function resolveMonitorHost(): string {
  return String(process.env.MONITOR_HOST ?? DEFAULT_MONITOR_HOST).trim() || DEFAULT_MONITOR_HOST;
}

function resolveMonitorPort(ctx: NodeContext): number {
  const raw = String(process.env.MONITOR_PORT ?? "").trim();
  if (raw) {
    const n = Number(raw);
    if (Number.isFinite(n) && n > 0) return Math.floor(n);
  }
  const nodeIndex = Number(ctx.nodeId);
  const offset = Number.isFinite(nodeIndex) && nodeIndex > 0 ? Math.floor(nodeIndex) - 1 : 0;
  return DEFAULT_MONITOR_PORT + offset;
}

export function startMonitorServer(ctx: NodeContext, state: MonitorRuntimeState): Server {
  const monitorHost = resolveMonitorHost();
  const monitorPort = resolveMonitorPort(ctx);
  const server = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", `http://${req.headers.host ?? `${monitorHost}:${monitorPort}`}`);

      if (req.method !== "GET") {
        res.writeHead(405, { "content-type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ error: "method_not_allowed" }));
        return;
      }

      if (url.pathname !== "/health" && url.pathname !== "/status") {
        res.writeHead(404, { "content-type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ error: "not_found" }));
        return;
      }

      const uptimeMs = Date.now() - ctx.startupMs;
      const taskStats = ctx.stats.getTaskStats();
      const balance = await ctx.stats.getBalanceSnapshot(ctx.client, ctx.identity.address);
      const body = {
        status: state.booting ? "booting" : "ok",
        nodeId: ctx.nodeId,
        address: ctx.identity.address,
        acceptedTemplateIds: ctx.acceptedTemplateIds,
        acceptedTemplateIdsSource: "on-chain",
        persistedAcceptedTemplateIdsFallback: ctx.acceptedTemplateIds,
        pollMs: ctx.pollMs,
        startupMs: ctx.startupMs,
        uptimeMs,
        runtime: state,
        tasks: taskStats,
        balance: {
          ...balance.data,
          error: balance.error,
        },
        monitor: {
          host: monitorHost,
          port: monitorPort,
          path: url.pathname,
        },
      };

      const code = state.booting ? 503 : 200;
      res.writeHead(code, { "content-type": "application/json; charset=utf-8" });
      res.end(JSON.stringify(body, null, 2));
    })().catch((e: any) => {
      res.writeHead(500, { "content-type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ error: "monitor_failed", message: String(e?.message ?? e) }, null, 2));
    });
  });

  server.listen(monitorPort, monitorHost, () => {
    console.log(`[node ${ctx.nodeId}] monitor listening on http://${monitorHost}:${monitorPort}`);
  });

  return server;
}
