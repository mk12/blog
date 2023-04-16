// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import { marked } from "marked";
import dateFormat from "dateformat";
import { Socket } from "bun";
import katex, { KatexOptions } from "katex";
import { basename, join } from "path";
import { readdir } from "fs/promises";
import { mkdir } from "fs/promises";
import { dirname } from "path";
import { Writable } from "stream";

function usage(out: Writable) {
  const program = basename(process.argv[1]);
  out.write(
    `Usage: bun run ${program} OUT_FILE

Generate a file for the blog

- If OUT_FILE is build/stamp, also writes JSON files in build/
- If OUT_FILE is $DESTDIR/foo/bar.html, also writes build/foo/bar.d
`
  );
}

async function main() {
  const arg = process.argv[2];
  if (arg === undefined) {
    usage(process.stderr);
    process.exit(1);
  } else if (arg === "-h" || arg === "--help") {
    usage(process.stdout);
  } else if (arg === stampFile) {
    await genJsonFiles();
    Bun.write(arg, "");
  } else {
    await genHtmlFile(arg);
  }
}

const destDirVar = "DESTDIR";
const hlsvcSocket = "hlsvc.sock";
const srcPostDir = "posts";
const dstPostDir = "post";
const buildDir = "build";
const stampFile = `${buildDir}/stamp`;
const postsFile = `${buildDir}/posts.json`;

const srcFile = (slug: string) => `${srcPostDir}/${slug}.md`;
const extFile = (slug: string) =>
  `${buildDir}/${dstPostDir}/${slug}/index.json`;

// A Markdown blog post with the metadata parsed out.
interface Post {
  meta: Metadata;
  body: string;
}

// YAML metadata from the top of a blog post Markdown file.
interface Metadata {
  title: string;
  description: string;
  category: string;
  date: YmdDate;
}

// A date in YYYY-MM-DD format.
type YmdDate = string;

// An entry in posts.json, used for generating pages like the index.
interface Entry {
  slug: string;
  meta: Metadata;
  // First paragraph of the post body.
  summary: string;
}

// External information stored in per-post JSON files.
interface ExternalInfo {
  // Slug of the next older post, if one exists.
  older?: string;
  // Slug of the next newer post, if one exists.
  newer?: string;
}

// Parses the metadata from a blog post.
function parsePost(content: string): Post {
  const [before, body] = content.split("\n---\n", 2);
  const fields = before
    .replace(/^---\n/, "")
    .replace(/^(\w+):\s*(.*?)\s*$/gm, '"$1":"$2"')
    .replace(/\n/g, ",");
  const metadata = JSON.parse("{" + fields + "}");
  return { meta: metadata, body };
}

// Returns the first paragraph of a post body.
function getSummary(body: string): string {
  const match = body.match(/^\s*(.*)/);
  if (!match) throw Error("post has no summary paragraph");
  return match[1];
}

// Generates JSON files in the build directory.
async function genJsonFiles() {
  const filenames = await readdir(srcPostDir);
  const posts: Entry[] = await Promise.all(
    filenames
      .filter((n) => n.endsWith(".md"))
      .map(async (name) => {
        const slug = removeExt(name);
        const srcPath = join(srcPostDir, name);
        const { meta, body } = parsePost(await Bun.file(srcPath).text());
        const summary = getSummary(body);
        return { slug, summary, meta };
      })
  );
  // Sort posts in reverse chronological order.
  posts.sort((a, b) => b.meta.date.localeCompare(a.meta.date));
  writeIfChanged(postsFile, JSON.stringify(posts));
  // Write external info JSON files for each post.
  posts.forEach(({ slug }, i) => {
    const info: ExternalInfo = {
      newer: posts[i - 1]?.slug,
      older: posts[i + 1]?.slug,
    };
    writeIfChanged(
      `${buildDir}/${dstPostDir}/${slug}/index.json`,
      JSON.stringify(info)
    );
  });
}

// Generates an HTML file in $DESTDIR.
async function genHtmlFile(path: string) {
  const destDir = process.env[destDirVar];
  if (!destDir) throw Error(`\$${destDirVar} is not set`);
  const relPath = eatPrefix(path, destDir + "/");
  if (!relPath) throw Error(`invalid html file path: ${path}`);
  const hlsvc = new Hlsvc();
  const input = new Input();
  const template = new Template();
  const markdown = new Markdown(hlsvc);
  const html = await renderPage(relPath, input, template, markdown);
  Bun.write(path, postprocess(html));
  hlsvc.close();
  const deps = [input, template, markdown].flatMap((x) => x.deps());
  Bun.write(
    join(buildDir, changeExt(relPath, ".d")),
    `$(${destDirVar})/${relPath}: ${deps.join(" ")}`
  );
}

// Manages access to input sources.
class Input {
  private files = new Set<string>();

  private read(file: string): Promise<string> {
    this.files.add(file);
    return Bun.file(file).text();
  }

  async posts(): Promise<Entry[]> {
    return JSON.parse(await this.read(postsFile));
  }

  async post(slug: string): Promise<Post> {
    return parsePost(await this.read(srcFile(slug)));
  }

  async externalInfo(slug: string): Promise<ExternalInfo> {
    return JSON.parse(await this.read(extFile(slug)));
  }

  deps(): string[] {
    return Array.from(this.files);
  }
}

async function renderPage(
  relPath: string,
  input: Input,
  template: Template,
  markdown: Markdown
): Promise<string> {
  switch (relPath) {
    case "index.html":
      return genIndex(await input.posts(), template, markdown);
    case "post/index.html":
      return genArchive(await input.posts(), template);
    case "categories/index.html":
      return genCategories(await input.posts(), template);
    default:
      const match = relPath.match(/^post\/(.*)\/index.html$/);
      if (!match) throw Error(`invalid post file path: ${relPath}`);
      const slug = match[1];
      const [post, info] = await Promise.all([
        input.post(slug),
        input.externalInfo(slug),
      ]);
      return genPost(post, info, template, markdown);
  }
}

// Generates the blog homepage.
function genIndex(
  posts: Entry[],
  template: Template,
  markdown: Markdown
): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  const postsPromise = Promise.all(
    posts
      .slice(0, 10)
      .map(async ({ slug, summary, meta: { title, date } }) => ({
        date: dateFormat(date, "dddd, d mmmm yyyy"),
        href: `post/${slug}/index.html`,
        title,
        summary: await markdown.render(summary),
      }))
  );
  return template.render("templates/index.html", {
    root: "",
    title: "Mitchell Kember",
    analytics: analytics ? Bun.file(analytics).text() : false,
    math: postsPromise.then(() => markdown.encounteredMath),
    home_url: process.env["HOME_URL"] ?? false,
    posts: postsPromise,
    year: new Date().getFullYear().toString(),
  });
}

// Generates the blog post archive.
function genArchive(posts: Entry[], template: Template): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  return template.render("templates/listing.html", {
    root: "../",
    title: "Post Archive",
    analytics: analytics ? Bun.file(analytics).text() : false,
    math: false,
    groups: groupBy(posts, (post) => dateFormat(post.meta.date, "yyyy")).map(
      ([year, posts]) => ({
        name: year,
        pages: posts.map(({ slug, meta: { title, date } }) => ({
          date: dateFormat(date, "d mmm yyyy"),
          href: `${slug}/index.html`,
          title,
        })),
      })
    ),
    year: new Date().getFullYear().toString(),
  });
}

// Generates the blog post categories page.
function genCategories(posts: Entry[], template: Template): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  return template.render("templates/listing.html", {
    root: "../",
    title: "Categories",
    analytics: analytics ? Bun.file(analytics).text() : false,
    math: false,
    groups: groupBy(posts, (post) => post.meta.category).map(
      ([category, posts]) => ({
        name: category,
        pages: posts.map(({ slug, meta: { title, date } }) => ({
          date: dateFormat(date, "d mmm yyyy"),
          href: `../post/${slug}/index.html`,
          title,
        })),
      })
    ),
    year: new Date().getFullYear().toString(),
  });
}

// Generates a blog post from its Markdown content.
function genPost(
  post: Post,
  info: ExternalInfo,
  template: Template,
  markdown: Markdown
): Promise<string> {
  const bodyHtml = markdown.render(post.body);
  const analytics = process.env["ANALYTICS"];
  return template.render("templates/post.html", {
    root: "../../",
    title: markdown.renderInline(post.meta.title),
    math: bodyHtml.then(() => markdown.encounteredMath),
    analytics: analytics ? Bun.file(analytics).text() : false,
    date: dateFormat(post.meta.date, "dddd, d mmmm yyyy"),
    description: markdown.renderInline(post.meta.description),
    article: bodyHtml,
    home: process.env["HOME_URL"] ?? false,
    older: info.older ? `../${info.older}/index.html` : "../index.html",
    newer: info.newer ? `../${info.newer}/index.html` : "../../index.html",
  });
}

// Renders Markdown to HTML using the marked library with extensions.
class Markdown {
  encounteredMath = false;
  embeddedAssets = new Set<string>();

  constructor(hlsvc: Hlsvc) {
    marked.use({
      smartypants: true,
      extensions: [
        codeExt,
        imageExt,
        mathExt,
        displayMathExt,
        divExt,
        footnoteExt,
        footnoteDefBlockExt,
        footnoteDefItemExt,
      ],
      walkTokens: async (anyToken) => {
        const token = anyToken as Code | Image | Math | DisplayMath;
        switch (token.type) {
          case "code":
            token.highlighted = token.lang
              ? await hlsvc.highlight(token.lang, token.text)
              : token.text;
            break;
          case "image":
            if (token.src.endsWith(".svg")) {
              const path = join(srcPostDir, token.src);
              this.embeddedAssets.add(path);
              token.svg = await Bun.file(path).text();
            } else {
              const match = token.src.match(/^\.\.\/assets\/(.*)$/);
              if (!match) throw Error(`invalid image src: ${token.src}`);
              token.src = "../../" + match[1];
            }
            break;
          case "math":
          case "display_math":
            this.encounteredMath = true;
            break;
        }
      },
    });
  }

  render(src: string): Promise<string> {
    return marked.parse(src, { async: true });
  }

  renderInline(src: string): string {
    return marked.parseInline(src);
  }

  deps(): string[] {
    return Array.from(this.embeddedAssets);
  }
}

interface Code extends marked.Tokens.Code {
  highlighted: string;
}

const codeExt: marked.RendererExtension = {
  name: "code",
  renderer(token) {
    const { highlighted } = token as Code;
    return `<pre><code>${highlighted}</code></pre>`;
  },
};

interface Image {
  type: "image";
  raw: string;
  src: string;
  svg?: string;
  above: boolean;
  tokens: marked.Token[];
}

const imageExt: marked.TokenizerAndRendererExtension = {
  name: "image",
  level: "block",
  start: (src) => src.indexOf("\n\n!["),
  tokenizer(src): Image | undefined {
    const match = src.match(/^\n\n!\[(@above\s+)?([^[\]]+)\]\(([^\s()]+)\)/);
    if (match) {
      const tokens: marked.Token[] = [];
      this.lexer.inline(match[2], tokens);
      return {
        type: "image",
        raw: match[0],
        above: !!match[1],
        src: match[3],
        tokens,
      };
    }
  },
  renderer(token) {
    const { src, svg, above, tokens } = token as Image;
    const caption = this.parser.parseInline(tokens);
    const img = svg ?? `<img src=${src}>`;
    if (above) {
      return `<figure><figcaption class="above">${caption}</figcaption>${img}</figure>`;
    }
    return `<figure>${img}<figcaption>${caption}</figcaption></figure>`;
  },
};

const katexOptions: KatexOptions = {
  throwOnError: true,
  strict: true,
};

interface Math {
  type: "math";
  raw: string;
  tex: string;
}

const mathExt: marked.TokenizerAndRendererExtension = {
  name: "math",
  level: "inline",
  start: (src) => src.indexOf("$"),
  tokenizer(src): Math | undefined {
    const match = src.match(/^\B\$([^$]|[^$ ][^$]*[^$ ])\$\B/);
    if (match) {
      return { type: "math", raw: match[0], tex: match[1] };
    }
  },
  renderer(token) {
    const { tex } = token as Math;
    return katex.renderToString(tex, katexOptions);
  },
};

interface DisplayMath {
  type: "display_math";
  raw: string;
  tex: string;
}

const displayMathExt: marked.TokenizerAndRendererExtension = {
  name: "display_math",
  level: "block",
  start: (src) => src.indexOf("\n\n$$"),
  tokenizer(src): DisplayMath | undefined {
    const match = src.match(/^\n\n\$\$([^$]+)\$\$/);
    if (match) {
      return { type: "display_math", raw: match[0], tex: match[1] };
    }
  },
  renderer(token) {
    const { tex } = token as DisplayMath;
    return katex.renderToString(tex, { ...katexOptions, displayMode: true });
  },
};

interface Div {
  type: "div";
  raw: string;
  cssClass: string;
  tokens: marked.Token[];
}

const divExt: marked.TokenizerAndRendererExtension = {
  name: "div",
  level: "block",
  start: (src) => src.indexOf("\n\n:::"),
  tokenizer(src): Div | undefined {
    const match = src.match(/^\n\n:::\s*(\w+)(\n[\s\S]+?\n):::\n/);
    if (match) {
      return {
        type: "div",
        raw: match[0],
        cssClass: match[1],
        tokens: this.lexer.blockTokens(match[2], []),
      };
    }
  },
  renderer(token) {
    const { cssClass, tokens } = token as Div;
    return `<div class="${cssClass}">${this.parser.parse(tokens)}</div>`;
  },
};

interface Footnote {
  type: "footnote";
  raw: string;
  id: string;
}

const footnoteExt: marked.TokenizerAndRendererExtension = {
  name: "footnote",
  level: "inline",
  start: (src) => src.indexOf("[^"),
  tokenizer(src): Footnote | undefined {
    const match = src.match(/^\[\^(\w+)\]/);
    if (match) {
      return { type: "footnote", raw: match[0], id: match[1] };
    }
  },
  renderer(token) {
    const { id } = token as Footnote;
    return `\
<sup id="fnref:${id}">\
<a href="#fn:${id}" class="footnote-ref" role="doc-noteref">${id}</a>\
</sup>`;
  },
};

interface FootnoteDefBlock {
  type: "footnote_def_block";
  raw: string;
  tokens: marked.Token[];
}

interface FootnoteDefItem {
  type: "footnote_def_item";
  raw: string;
  id: string;
  tokens: marked.Token[];
}

const footnoteDefBlockExt: marked.TokenizerAndRendererExtension = {
  name: "footnote_def_block",
  level: "block",
  start: (src) => src.indexOf("\n\n[^"),
  tokenizer(src): FootnoteDefBlock | undefined {
    let raw = "";
    let match;
    const items: FootnoteDefItem[] = [];
    while ((match = /^\n+\[\^(\w+)\]: (.+)/.exec(src.slice(raw.length)))) {
      raw += match[0];
      const tokens: marked.Token[] = [];
      this.lexer.inline(match[2], tokens);
      items.push({
        type: "footnote_def_item",
        raw: match[0],
        id: match[1],
        tokens,
      });
    }
    if (items.length > 0) {
      return {
        type: "footnote_def_block",
        raw,
        tokens: items as unknown as marked.Token[],
      };
    }
  },
  renderer(token) {
    const { tokens } = token as FootnoteDefBlock;
    const items = this.parser.parse(tokens);
    return `\
<div class="footnotes" role="doc-endnotes"><hr><ol>${items}</ol></div>`;
  },
};

const footnoteDefItemExt: marked.RendererExtension = {
  name: "footnote_def_item",
  renderer(token) {
    const { id, tokens } = token as FootnoteDefItem;
    const content = this.parser.parseInline(tokens).trimEnd();
    return `\
<li id = "fn:${id}">\
<p>${content}&nbsp;\
<a href="#fnref:${id}" class="footnote-backref" role="doc-backlink">↩︎</a>\
</p>\
</li>`;
  },
};

// A context provides values for variables in a template.
type Context = Record<string, Value | Promise<Value>>;
type ResolvedContext = Record<string, Value>;
type Value = string | boolean | Value[] | NestedContext | undefined;
interface NestedContext extends Record<string, Value> {}

// Representation of a compiled template.
type Program = { defs: Definition[]; cmds: Command[] };
type Definition = { variable: string; program: Program };
type Command =
  | { kind: "text"; text: string }
  | { kind: "include"; program?: Program }
  | { kind: "var"; src: string; variable: string }
  | { kind: "if"; src: string; variable: string; body: Program; else?: Program }
  | { kind: "range"; src: string; variable: string; body: Program };

// Renders HTML templates using syntax similar to Go templates.
class Template {
  private cache: Map<string, Program> = new Map();

  async render(path: string, context: Context): Promise<string> {
    const [template, values] = await Promise.all([
      this.getTemplate(path),
      Promise.all(Object.values(context)),
    ]);
    const ctx = Object.fromEntries(
      Object.keys(context).map((key, i) => [key, values[i]])
    );
    const out = { str: "" };
    execTemplate(template, ctx, out);
    return out.str;
  }

  deps(): string[] {
    return Array.from(this.cache.keys());
  }

  private async getTemplate(path: string): Promise<Program> {
    let template = this.cache.get(path);
    if (template === undefined) {
      let deps;
      [template, deps] = compileTemplate(path, await Bun.file(path).text());
      this.cache.set(path, template);
      const dir = dirname(path);
      const programs = await Promise.all(
        Object.keys(deps).map((relPath) => this.getTemplate(join(dir, relPath)))
      );
      const lists = Object.values(deps);
      programs.forEach((program, i) => {
        for (const include of lists[i]) {
          include.program = program;
        }
      });
    }
    return template;
  }
}

// Mapping from template paths to "include" commands to fix up.
type Deps = Record<string, { program?: Program }[]>;

// Compiles a template to a program and dependences.
function compileTemplate(name: string, source: string): [Program, Deps] {
  let offset = 0;
  const matches = source.matchAll(/(\s*)\{\{(.*?)\}\}/g);
  type Ending = "end" | "else" | "eof";
  let hitElse = false;
  const deps: Deps = {};
  const go = (allow: { [k in Ending]?: boolean }): Program => {
    const prog: Program = { defs: [], cmds: [] };
    for (const match of matches) {
      const [all, whitespace, inBraces] = match;
      const idx = match.index;
      if (idx === undefined) throw Error("matchAll returned undefined index");
      const [line, col] = getLineAndColumn(source, idx + whitespace.length);
      const src = `${name}:${line}:${col}`;
      const err = (msg: string) => Error(`${src}: ${all.trim()}: ${msg}`);
      const text = source.slice(offset, idx);
      offset = idx + all.length;
      const textCmd: Command = { kind: "text", text };
      prog.cmds.push(textCmd);
      const words = inBraces.trim().split(/\s+/);
      if (words.length < 1) throw err("expected command");
      if (words.length > 2) throw err("too many words");
      const [kind, variable] = words;
      if (kind === "include") {
        const match = variable.match(/^"(.*)"$/);
        if (!match) throw err("invalid include path");
        const path = match[1];
        const cmd: Command = { kind };
        prog.cmds.push(cmd);
        (deps[path] ??= []).push(cmd);
      } else if (kind === "if" || kind == "range" || kind === "define") {
        if (variable === undefined) throw err("expected variable");
        const body = go({ end: true, else: kind === "if" });
        const elseBody = hitElse ? go({ end: true }) : undefined;
        if (kind === "define") {
          prog.defs.push({ variable, program: body });
        } else {
          prog.cmds.push({ kind, src, variable, body, else: elseBody });
        }
      } else if (kind === "else" || kind === "end") {
        if (!allow[kind]) throw err(`unexpected command`);
        hitElse = kind === "else";
        return prog;
      } else {
        if (variable !== undefined) throw err("too many words");
        textCmd.text += whitespace;
        prog.cmds.push({ kind: "var", src, variable: kind });
      }
    }
    if (!allow.eof) throw Error(`${name}: unexpected EOF`);
    prog.cmds.push({ kind: "text", text: source.slice(offset).trimEnd() });
    return prog;
  };
  return [go({ eof: true }), deps];
}

// Template output container.
type Output = { str: string };

// Executes a compiled template with a context.
function execTemplate(prog: Program, ctx: ResolvedContext, out: Output) {
  const enter = (value: Value) =>
    Object.assign(Object.create(ctx), value, { ".": value });
  for (const def of prog.defs) {
    const out = { str: "" };
    execTemplate(def.program, ctx, out);
    ctx[def.variable] = out.str;
  }
  for (const cmd of prog.cmds) {
    if (cmd.kind === "text") {
      out.str += cmd.text;
    } else if (cmd.kind === "include") {
      if (!cmd.program) throw Error("include did not get compiled properly");
      execTemplate(cmd.program, ctx, out);
    } else {
      const err = (msg: string) => Error(`${cmd.src}: ${msg}`);
      const value = ctx[cmd.variable];
      if (value === undefined) throw err(`"${cmd.variable}" is not defined`);
      if (cmd.kind === "var") {
        out.str += value;
      } else if (cmd.kind === "if") {
        if (value) {
          execTemplate(cmd.body, enter(value), out);
        } else if (cmd.else !== undefined) {
          execTemplate(cmd.else, enter(value), out);
        }
      } else if (cmd.kind === "range") {
        if (!Array.isArray(value)) {
          throw err(`range: "${cmd.variable}" is not an array`);
        }
        for (const item of value) {
          execTemplate(cmd.body, enter(item), out);
        }
      }
    }
  }
}

// Client for the hlsvc Unix socket server.
class Hlsvc {
  private state:
    | { mode: "init" }
    | { mode: "connecting"; promise: Promise<Socket> }
    | { mode: "connected"; socket: Socket };
  private interests: Deferred<string>[] = [];

  constructor() {
    this.state = { mode: "init" };
  }

  async highlight(lang: string, code: string): Promise<string> {
    const interest = new Deferred<string>();
    this.interests.push(interest);
    (await this.socket()).write(`${lang}:${code}\0`);
    return interest.promise;
  }

  close(): void {
    if (this.state.mode === "connecting")
      throw Error("cannot close socket in the middle of connecting");
    if (this.state.mode === "connected") this.state.socket.end();
  }

  private async socket(): Promise<Socket> {
    switch (this.state.mode) {
      case "init":
        const deferred = new Deferred<Socket>();
        this.state = { mode: "connecting", promise: deferred.promise };
        const onSuccess = (socket: Socket) => {
          this.state = { mode: "connected", socket };
          deferred.resolve(socket);
        };
        this.connect(hlsvcSocket, onSuccess, deferred.reject);
        return this.state.promise;
      case "connecting":
        return this.state.promise;
      case "connected":
        return this.state.socket;
    }
  }

  private connect(
    path: string,
    onSuccess: (s: Socket) => void,
    onFailure: (e: Error) => void
  ) {
    let buffer = "";
    Bun.connect({
      unix: path,
      socket: {
        binaryType: "uint8array",
        open: (socket) => onSuccess(socket),
        data: (_socket, data: Uint8Array) => {
          buffer += new TextDecoder().decode(data);
          let idx;
          while ((idx = buffer.indexOf("\0")) >= 0) {
            this.handleResponse(buffer.slice(0, idx));
            buffer = buffer.slice(idx + 1);
          }
        },
        error: (_socket, error) => {
          this.nextInterest().reject(error);
        },
      },
    }).catch(onFailure);
  }

  private handleResponse(raw: string) {
    const interest = this.nextInterest();
    const error = eatPrefix(raw, "error:");
    if (error) {
      interest.reject(new Error(`server responded with error: ${error}`));
    } else {
      interest.resolve(raw);
    }
  }

  private nextInterest(): Deferred<string> {
    const next = this.interests.shift();
    if (next === undefined) throw Error("no pending request");
    return next;
  }
}

// Postprocesses HTML output.
function postprocess(html: string): string {
  // Avoid unnecessary entities.
  const entityMap: Record<string, string> = {
    quot: '"',
    "#34": '"',
    apos: "'",
    "#39": "'",
    gt: ">",
    "#62": ">",
  };
  html = html.replace(
    /&(#\d+|[a-z]+);/g,
    (entity: string, code: string) => entityMap[code] ?? entity
  );
  // I prefer typing " -- ", but I want to render as close-set em dash.
  html = html.replace(/ – /g, "—");
  // Ensure it ends with a newline. We strip trailing newlines in templates to
  // avoid having blank lines within the file.
  html = html.trimEnd() + "\n";
  return html;
}

// If s starts with prefix, removes it and returns the result.
function eatPrefix(s: string, prefix: string): string | undefined {
  return s.startsWith(prefix) ? s.slice(prefix.length) : undefined;
}

// Changes the extension of a path.
function changeExt(path: string, ext: string): string {
  return removeExt(path) + ext;
}

// Removes the extension from a path.
function removeExt(path: string): string {
  return path.slice(0, path.lastIndexOf("."));
}

// Writes to a file if the new content is different.
async function writeIfChanged(path: string, content: string): Promise<void> {
  const same = await Bun.file(path)
    .text()
    .then((old) => old === content)
    .catch(() => false);
  if (!same) {
    await mkdir(dirname(path), { recursive: true });
    await Bun.write(path, content);
  }
}

// Groups an array into subarrays where each item has the same key.
function groupBy<T, U>(array: T[], key: (item: T) => U): [U, T[]][] {
  const map = new Map<U, T[]>();
  for (const item of array) {
    const k = key(item);
    const group = map.get(k);
    if (group !== undefined) {
      group.push(item);
    } else {
      map.set(k, [item]);
    }
  }
  return Array.from(map.entries());
}

// Converts a byte offset to 1-based line and column numbers.
function getLineAndColumn(source: string, offset: number): [number, number] {
  const matches = Array.from(source.slice(0, offset).matchAll(/\n/g));
  const line = matches.length + 1;
  const last = matches[matches.length - 1]?.index;
  const col = last !== undefined ? offset - last : offset + 1;
  return [line, col];
}

// A promise that can be resolved or rejected from the outside.
class Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = Deferred.unset;
  reject: (error: Error) => void = Deferred.unset;

  private static unset() {
    throw Error("unreachable since Promise ctor runs callback immediately");
  }

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

await main();
