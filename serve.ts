// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import { extname, join } from "path";

async function main() {
  const server = startServer();
  console.log(`listening on ${server.rootUrl}`);
  const watcher = startWatcher();
  try {
    // Pretend main.zig changed so that we run zig build first.
    await handleChange("src/main.zig");
    await Bun.spawn(["open", server.rootUrl]).exited;
    for await (const path of watcher.changes()) {
      console.log(`changed: ${path}`);
      await handleChange(path);
      await Bun.spawn(["open", "-g", server.lastVisitedUrl()]).exited;
    }
  } finally {
    watcher.kill();
  }
}

const outDir = "./public";

function startServer() {
  let lastHtmlPath = "";
  const server = Bun.serve({
    fetch(request) {
      let path = new URL(request.url).pathname;
      console.log(`handling: ${request.method} ${path}`);
      let target = path;
      if (extname(path) === "") target += "/index.html";
      else if (path.endsWith("/")) target += "index.html";
      const root = path.startsWith("/fonts/") ? "." : outDir;
      if (target.endsWith(".html")) {
        lastHtmlPath = path;
        if (htmlStatus !== null) return new Response(htmlStatus, {
          headers: { "Content-Type": "text/html" },
        });
      }
      return new Response(Bun.file(join(root, target)));
    },
    error(error: any) {
      if (error.code === "ENOENT") return new Response("", { status: 404 });
    }
  });
  const rootUrl = `http://${server.hostname}:${server.port}`;
  return {
    rootUrl,
    lastVisitedUrl: () => rootUrl + lastHtmlPath,
  }
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
async function run(...args: [string, ...string[]]) {
  const cmdline = args.join(" ");
  htmlStatus = `Command in progress: <code>${cmdline}</code>`;
  console.log(`running: ${cmdline}`);
  const cmd = Bun.spawn(args, { stdout: "inherit", stderr: "pipe" });
  if (await cmd.exited === 0) {
    htmlStatus = null;
    return true;
  }
  const stderr = await Bun.readableStreamToText(cmd.stderr as ReadableStream);
  console.error(`Command failed: ${cmdline}\n${stderr}`);
  htmlStatus = `
    <h1>Command failed</h1>
    <p>Command: <code>${cmdline}</code></p>
    <pre>${stderr}</pre>
`;
  return false;
}

const die = (msg: string): never => { throw Error(msg); }

await main();
