// HTTPS API for the phone (REST, the human channel) and MCP (the model channel).
//
// - TLS with the companion's own key; the phone pins the public key.
// - Only loopback and private-network peers may connect.
// - Requests carrying an Origin header (browsers) are refused, which also
//   blocks DNS-rebinding and cross-site requests.
// - Every route except hello and pair needs a paired device's bearer token.
//   Failed logins are counted per address and block it for a while.

import https from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { AddressInfo, Socket } from "node:net";
import type { CompanionCore } from "./core.ts";
import { VERSION } from "./core.ts";
import type { PublicDevice } from "./devices.ts";
import { handleMcp } from "./mcp.ts";
import { isPrivateAddress, normalizeAddress } from "./network.ts";
import { RateLimiter } from "./ratelimit.ts";
import { isFinished, toPublicTask } from "./tasks.ts";
import type { TaskRecord, TaskState } from "./tasks.ts";
import { effectivePolicy } from "./tools/registry.ts";
import { CompanionError } from "./util.ts";

const MAX_BODY = 1_400_000;
const TASK_STATES: readonly TaskState[] = ["pending", "awaiting_approval", "running", "completed", "failed", "cancelled"];

interface RequestContext {
  req: IncomingMessage;
  res: ServerResponse;
  address: string;
  url: URL;
  device?: PublicDevice;
}

function send(res: ServerResponse, status: number, body?: unknown, headers: Record<string, string> = {}): void {
  const payload = body === undefined ? "" : JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...(body === undefined ? {} : { "Content-Length": String(Buffer.byteLength(payload)) }),
    ...headers,
  });
  res.end(payload);
}

function sendError(res: ServerResponse, error: CompanionError): void {
  send(res, error.status, { error: { code: error.code, message: error.message } });
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const type = String(req.headers["content-type"] ?? "");
  if (!/^application\/json\b/i.test(type)) throw new CompanionError("unsupported_media_type", "İstek gövdesi application/json olmalı.", { status: 415 });
  const declared = Number(req.headers["content-length"] ?? "0");
  if (declared > MAX_BODY) throw new CompanionError("too_large", "İstek çok büyük.", { status: 413 });
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) throw new CompanionError("too_large", "İstek çok büyük.", { status: 413 });
    chunks.push(chunk as Buffer);
  }
  if (size === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new CompanionError("invalid_json", "Geçersiz JSON.", { status: 400 });
  }
}

export interface ServerOptions {
  host: string;
  port: number;
}

export interface RunningServer {
  server: https.Server;
  host: string;
  port: number;
  close(): Promise<void>;
}

export async function startServer(core: CompanionCore, options: ServerOptions): Promise<RunningServer> {
  const failedLogins = new RateLimiter(10, 10 * 60_000, 15 * 60_000);
  const deviceRequests = new RateLimiter(240, 60_000);
  const sseClients = new Set<ServerResponse>();

  const server = https.createServer(
    {
      key: core.identity.keyPem,
      cert: core.identity.certPem,
      minVersion: "TLSv1.2",
      requestTimeout: 60_000,
      headersTimeout: 15_000,
      keepAliveTimeout: 5_000,
    },
    (req, res) => {
      void handle(req, res).catch((error: unknown) => {
        if (error instanceof CompanionError) return sendError(res, error);
        console.error(`[jarvis-pc] iç hata: ${error instanceof Error ? error.message : String(error)}`);
        if (!res.headersSent) send(res, 500, { error: { code: "internal", message: "PC companion'da beklenmeyen bir hata oldu." } });
        else res.end();
      });
    },
  );

  server.on("connection", (socket: Socket) => {
    if (!isPrivateAddress(socket.remoteAddress ?? "")) socket.destroy();
  });
  server.on("tlsClientError", () => {
    // A scanner or a phone with the wrong pin: nothing to log beyond the audit of real requests.
  });

  const onTask = (task: TaskRecord): void => {
    if (sseClients.size === 0) return;
    const data = `event: task\ndata: ${JSON.stringify(toPublicTask(task))}\n\n`;
    for (const client of sseClients) client.write(data);
  };
  core.tasks.on("task", onTask);
  const heartbeat = setInterval(() => {
    for (const client of sseClients) client.write(": ping\n\n");
  }, 25_000);
  heartbeat.unref();

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const address = normalizeAddress(req.socket.remoteAddress);
    if (!isPrivateAddress(address)) {
      req.socket.destroy();
      return;
    }
    if (req.headers.origin !== undefined) {
      throw new CompanionError("browser_blocked", "Tarayıcıdan gelen istekler kabul edilmiyor.", { status: 403 });
    }
    const url = new URL(req.url ?? "/", "https://companion.local");
    const ctx: RequestContext = { req, res, address, url };
    const method = req.method ?? "GET";
    const path = url.pathname;

    // ---- unauthenticated -----------------------------------------------------
    if (method === "GET" && path === "/v1/hello") {
      return send(res, 200, { service: "jarvis-pc", protocol: 1, version: VERSION, name: core.config.serverName, pairingOpen: core.pairing.isOpen() });
    }
    if (method === "POST" && path === "/v1/pair") {
      if (failedLogins.isBlocked(address)) throw new CompanionError("rate_limited", "Çok fazla hatalı deneme. Biraz sonra tekrar dene.", { status: 429 });
      const body = (await readJson(req)) as { code?: unknown; deviceName?: unknown };
      try {
        const { device, token } = await core.pairing.pair(body.code, body.deviceName, address);
        return send(res, 200, {
          device: { id: device.id, name: device.name, scopes: device.scopes },
          token,
          server: { name: core.config.serverName, version: VERSION },
        });
      } catch (error) {
        if (error instanceof CompanionError && error.code === "pairing_code_invalid") failedLogins.hit(address);
        throw error;
      }
    }

    // ---- authenticated ------------------------------------------------------------
    await authenticate(ctx);
    const device = ctx.device as PublicDevice;
    const by = `phone:${device.id}`;

    if (method === "GET" && path === "/v1/status") {
      return send(res, 200, { ...core.status(), device: { id: device.id, name: device.name, scopes: device.scopes } });
    }
    if (method === "POST" && path === "/v1/unpair") {
      await core.devices.revoke(device.id);
      await core.audit.record("device.unpaired", { deviceId: device.id });
      return send(res, 200, { ok: true });
    }
    if (method === "GET" && path === "/v1/tools") {
      const tools = [...core.tools.values()].map((tool) => ({
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema: tool.inputSchema,
        risk: tool.risk,
        policy: effectivePolicy(tool, core.config),
      }));
      return send(res, 200, { tools });
    }
    if (method === "POST" && path === "/v1/tools/call") {
      const body = (await readJson(req)) as { tool?: unknown; arguments?: unknown; idempotencyKey?: unknown; approve?: unknown; waitMs?: unknown };
      if (typeof body.tool !== "string") throw new CompanionError("invalid_request", "tool gerekli.");
      const idempotencyKey = typeof body.idempotencyKey === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(body.idempotencyKey) ? body.idempotencyKey : undefined;
      const task = await core.tasks.submit({
        deviceId: device.id,
        source: "phone",
        tool: body.tool,
        args: body.arguments ?? {},
        idempotencyKey,
        scopes: device.scopes,
        preApprovedBy: body.approve === true ? (device.scopes.includes("tasks:approve") ? by : undefined) : undefined,
      });
      const waitMs = typeof body.waitMs === "number" ? Math.max(0, Math.min(25_000, body.waitMs)) : 0;
      const settled = waitMs > 0 ? await core.tasks.waitForSettle(task.id, waitMs) : task;
      return send(res, 200, { task: toPublicTask(settled) });
    }
    if (method === "GET" && path === "/v1/tasks") {
      const limit = Math.max(1, Math.min(200, Number(url.searchParams.get("limit") ?? "50") || 50));
      const stateParam = url.searchParams.get("state");
      const states =
        stateParam === "active"
          ? (["pending", "awaiting_approval", "running"] as TaskState[])
          : stateParam && TASK_STATES.includes(stateParam as TaskState)
            ? [stateParam as TaskState]
            : undefined;
      return send(res, 200, { tasks: core.tasks.list({ limit, states }).map(toPublicTask) });
    }
    const taskMatch = /^\/v1\/tasks\/(t_[A-Z0-9]{12})(?:\/(approve|deny|cancel|undo))?$/.exec(path);
    if (taskMatch) {
      const [, id, action] = taskMatch;
      if (method === "GET" && !action) {
        const task = core.tasks.get(id);
        if (!task) throw new CompanionError("task_not_found", "Görev bulunamadı.", { status: 404 });
        return send(res, 200, { task: toPublicTask(task) });
      }
      if (method === "POST" && action === "approve") {
        const body = (await readJson(req)) as { argsDigest?: unknown };
        const task = await core.tasks.approve(id, by, body.argsDigest, device.scopes);
        return send(res, 200, { task: toPublicTask(task) });
      }
      if (method === "POST" && action === "deny") {
        return send(res, 200, { task: toPublicTask(await core.tasks.deny(id, by)) });
      }
      if (method === "POST" && action === "cancel") {
        const task = await core.tasks.cancel(id, by);
        const latest = isFinished(task.state) ? task : await core.tasks.waitForSettle(id, 5000);
        return send(res, 200, { task: toPublicTask(latest) });
      }
      if (method === "POST" && action === "undo") {
        if (!device.scopes.includes("tasks:approve")) throw new CompanionError("forbidden", "Bu cihaz geri alma onayı veremez.", { status: 403 });
        const undo = await core.tasks.submit({ deviceId: device.id, source: "phone", tool: "undo_task", args: { taskId: id }, scopes: device.scopes, preApprovedBy: by });
        const settled = await core.tasks.waitForSettle(undo.id, 15_000);
        return send(res, 200, { task: toPublicTask(settled) });
      }
    }
    if (method === "GET" && path === "/v1/activity") {
      const limit = Math.max(1, Math.min(200, Number(url.searchParams.get("limit") ?? "50") || 50));
      return send(res, 200, { entries: (await core.audit.recent(limit)).reverse() });
    }
    if (method === "GET" && path === "/v1/events") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      res.write(": connected\n\n");
      sseClients.add(res);
      req.on("close", () => sseClients.delete(res));
      return;
    }
    if (path === "/mcp") {
      if (method !== "POST") return send(res, 405, { error: { code: "method_not_allowed", message: "Yalnızca POST." } }, { Allow: "POST" });
      const message = await readJson(req);
      const response = await handleMcp(core, device, message);
      if (response.status === 202) {
        res.writeHead(202, { "Cache-Control": "no-store" });
        res.end();
        return;
      }
      return send(res, response.status, response.body, response.headers);
    }
    throw new CompanionError("not_found", "Böyle bir adres yok.", { status: 404 });
  }

  async function authenticate(ctx: RequestContext): Promise<void> {
    if (failedLogins.isBlocked(ctx.address)) {
      throw new CompanionError("rate_limited", "Çok fazla hatalı deneme. Biraz sonra tekrar dene.", { status: 429 });
    }
    const header = String(ctx.req.headers.authorization ?? "");
    const token = /^Bearer\s+(\S+)$/i.exec(header)?.[1];
    const device = core.devices.authenticate(token);
    if (!device) {
      failedLogins.hit(ctx.address);
      void core.audit.record("auth.failed", { address: ctx.address, path: ctx.url.pathname });
      throw new CompanionError("unauthorized", "Bu cihaz eşleştirilmemiş veya eşleşmesi kaldırılmış.", { status: 401 });
    }
    if (!deviceRequests.hit(device.id)) throw new CompanionError("rate_limited", "Çok fazla istek. Biraz yavaşla.", { status: 429 });
    ctx.device = device;
    await core.devices.touch(device.id, ctx.address);
  }

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, () => {
      server.off("error", reject);
      resolve();
    });
  });
  const address = server.address() as AddressInfo;
  await core.audit.record("server.started", { host: options.host, port: address.port, version: VERSION });

  return {
    server,
    host: options.host,
    port: address.port,
    async close(): Promise<void> {
      clearInterval(heartbeat);
      core.tasks.off("task", onTask);
      for (const client of sseClients) client.end();
      sseClients.clear();
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await core.audit.record("server.stopped", {});
    },
  };
}
