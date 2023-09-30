// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import type { ServerWebSocket } from "bun";
import { extname, join } from "path";

async function main() {
  const server = startServer();
  console.log(`listening on ${server.rootUrl}`);
  // Pretend main.zig changed so that we run zig build first.
  await handleChange("src/main.zig");
  server.reloadClients()
  const watcher = startWatcher();
  try {
    for await (const path of watcher.changes()) {
      console.log(`changed: ${path}`);
      await handleChange(path);
      server.reloadClients();
    }
  } finally {
    watcher.kill();
  }
}

const outDir = "./public";

function startServer() {
  const sockets: Set<ServerWebSocket> = new Set();
  const server = Bun.serve<undefined>({
    async fetch(request, server) {
      if (request.headers.get("upgrade") === "websocket") {
        if (!server.upgrade(request)) return new Response("Upgrade failed", { status: 400 });
        return new Response();
      }
      let path = new URL(request.url).pathname;
      console.log(`handling: ${request.method} ${path}`);
      let target = path;
      if (extname(path) === "") target += "/index.html";
      else if (path.endsWith("/")) target += "index.html";
      const root = path.startsWith("/fonts/") ? "." : outDir;
      const file = Bun.file(join(root, target));
      if (target.endsWith(".html")) return new Response(
        injectLiveReloadScript(htmlStatus ?? await file.text()),
        { headers: { "Content-Type": "text/html" } }
      );
      return new Response(file);
    },
    error(error: any) {
      if (error.code === "ENOENT") return new Response("", { status: 404 });
    },
    websocket: {
      open(ws) {
        console.log("websocket: opened");
        sockets.add(ws);
      },
      message() { },
      close(ws) {
        console.log("websocket: closed");
        sockets.delete(ws);
      },
    }
  });
  return {
    rootUrl: `http://${server.hostname}:${server.port}`,
    reloadClients: () => {
      for (const ws of sockets) ws.close();
      sockets.clear();
    },
  };
}

function injectLiveReloadScript(html: string): string {
  return html.replace("</body>", `
<script>
const socket = new WebSocket("ws://" + location.host);
socket.addEventListener("close", () => location.reload());
</script>
</body>
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

async function handleChange(path: string) {
  if (path.endsWith(".zig")) {
    const ok = await run("zig", "build");
    if (!ok) return;
  }
  await run("./zig-out/bin/genblog", "-d", outDir);
}

let htmlStatus: string | null = null;
function clearStatus() { htmlStatus = null; }
function setStatus(html: string) { htmlStatus = `<body>${html}</body>`; }

async function run(...args: [string, ...string[]]) {
  const cmdline = args.join(" ");
  setStatus(`Command in progress: <code>${cmdline}</code>`);
  console.log(`running: ${cmdline}`);
  const cmd = Bun.spawn(args, { stdout: "inherit", stderr: "pipe" });
  if (await cmd.exited === 0) {
    clearStatus();
    return true;
  }
  const stderr = await Bun.readableStreamToText(cmd.stderr as ReadableStream);
  console.error(`Command failed: ${cmdline}\n${stderr}`);
  setStatus(`
<h1>Command failed</h1>
<p>Command: <code>${cmdline}</code></p>
<pre>${stderr}</pre>`
  );
  return false;
}

const die = (msg: string): never => { throw Error(msg); }

await main();
