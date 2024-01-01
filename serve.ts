// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import type { ServerWebSocket } from "bun";
import { extname, join } from "path";

async function main() {
  const server = startServer();
  console.log(`listening on ${server.baseUrl}`);
  const onChange = changeHandler(server.baseUrl);
  // Pretend main.zig changed so that we run zig build first.
  await onChange("src/main.zig");
  server.reloadClients()
  const watcher = startWatcher();
  try {
    for await (const path of watcher.changes()) {
      console.log(`changed: ${path}`);
      await onChange(path);
      server.reloadClients();
    }
  } finally {
    watcher.kill();
  }
}

const outDir = "./public";

function startServer() {
  const sockets: Set<ServerWebSocket> = new Set();
  const pending: Set<number> = new Set();
  let nextClientId = 0;
  const server = Bun.serve<undefined>({
    async fetch(request, server) {
      const url = new URL(request.url);
      if (request.headers.get("upgrade") === "websocket") {
        const id = parseInt(url.searchParams.get("id") ?? "");
        if (!server.upgrade(request, { data: { id } }))
          return new Response("Upgrade failed", { status: 400 });
        return new Response();
      }
      const path = url.pathname;
      console.log(`handling: ${request.method} ${path}`);
      let target = path;
      if (extname(path) === "") target += "/index.html";
      else if (path.endsWith("/")) target += "index.html";
      const root = path.startsWith("/fonts/") ? "." : outDir;
      const file = Bun.file(join(root, target));
      if (target.endsWith(".html")) {
        const id = nextClientId++;
        pending.add(id);
        let html = await file.text();
        html = injectRunStatus(html);
        html = injectLiveReloadScript(html, id);
        return new Response(html, { headers: { "Content-Type": "text/html" } });
      }
      return new Response(file);
    },
    error(error: any) {
      if (error.code === "ENOENT") return new Response("", { status: 404 });
    },
    websocket: {
      open(ws) {
        console.log("websocket: opened");
        const id = (ws.data as any).id;
        // If this ID is known to be pending, we're good. Otherwise, something
        // is off, e.g. another change happened in the meantime; force a reload.
        if (pending.delete(id)) sockets.add(ws); else ws.close();
      },
      message() { },
      close(ws) {
        console.log("websocket: closed");
        sockets.delete(ws);
      },
    }
  });
  return {
    baseUrl: `http://${server.hostname}:${server.port}`,
    reloadClients: () => {
      pending.clear();
      for (const ws of sockets) ws.close();
      sockets.clear();
    },
  };
}

function injectLiveReloadScript(html: string, id: number): string {
  return injectBeforeCloseBody(html, `
<script>
const socket = new WebSocket("ws://" + location.host + "?id=${id}");
const reload = () => location.reload();
socket.addEventListener("close", reload);
addEventListener("beforeunload", () => socket.removeEventListener("close", reload));
</script>
`);
}

function startWatcher() {
  const subprocess = Bun.spawn([
    "watchexec",
    "--postpone",
    "--no-meta",
    "--on-busy-update=do-nothing",
    "--emit-events-to=stdin",
    "--shell=none",
    "/bin/cat",
  ]);
  return {
    kill: () => subprocess.kill(),
    changes: async function* () {
      const stdout = subprocess.stdout ?? die("watchexec has no stdout");
      const decoder = new TextDecoder();
      const cwdPrefix = process.cwd() + "/";
      for await (const chunk of stdout) {
        for (const line of decoder.decode(chunk).trimEnd().split("\n")) {
          let path = line.split(":", 2)[1];
          if (!path.startsWith(cwdPrefix)) die("unexpected path: " + path);
          yield path.slice(cwdPrefix.length);
        }
      }
    }
  }
}

function changeHandler(baseUrl: string) {
  return async function (path: string) {
    if (path.endsWith(".zig")) {
      const ok = await run(["zig", "build"]);
      if (!ok) return;
    }
    await run(["./zig-out/bin/genblog", "-d", outDir], { BASE_URL: baseUrl });
  };
}

let runStatus: string | null = null;
async function run(args: [string, ...string[]], env?: Record<string, string>) {
  const cmdline = args.join(" ");
  runStatus = `<b>Command in progress:<b>\n\n${cmdline}`;
  console.log(`running: ${cmdline}`);
  const cmd = Bun.spawn(args, { stdout: "inherit", stderr: "pipe", env });
  if (await cmd.exited === 0) {
    runStatus = null;
    return true;
  }
  const stderr = await Bun.readableStreamToText(cmd.stderr as ReadableStream);
  console.error(`Command failed: ${cmdline}\n${stderr}`);
  runStatus = `<b>Command failed:</b>\n\n${cmdline}\n\n<b>stderr:</b>\n\n${stderr}`;
  return false;
}

const modalDivStyle = `
  position: fixed;
  left: 0;
  top: 0;
  width: 100%;
  height: 100%;
  background: inherit;
  opacity: 0.7;
  pointer-events: none;
`;

const modalPreStyle = `
  position: fixed;
  left: 0;
  top: 0;
  font: 18px monospace;
  margin: 50px;
  border: 2px solid currentColor;
  box-sizing: border-box;
  padding: 10px;
  background: inherit;
  max-width: calc(100vw - 100px);
  max-height: calc(100vh - 100px);
  overflow: auto;
`;

function injectRunStatus(html: string): string {
  if (runStatus === null) return html;
  return injectBeforeCloseBody(html, `
<div style="${modalDivStyle}"></div>
<pre style="${modalPreStyle}">${runStatus}</pre>`);
}

function injectBeforeCloseBody(html: string, inject: string) {
  const index = html.indexOf("</body>");
  if (index === -1) return `<html><body>${inject}</body></html>`;
  return html.slice(0, index) + inject + html.slice(index);
}

function die(msg: string): never { throw Error(msg); }

await main();
