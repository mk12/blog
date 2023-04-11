// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import getopts from "getopts";
import { marked } from "marked";
import dateFormat from "dateformat";
import { Socket, file } from "bun";
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

Generate files for the blog

If OUT_FILE is build/stamp, touches it after writing JSON files in build/.
If OUT_FILE looks like $DESTDIR/foo/bar.html, writes it and build/foo/bar.d.
`
  );
}

const destDirVar = "DESTDIR";
const hlsvcSocket = "hlsvc.sock";
const srcPostDir = "posts";
const dstPostDir = "post";
const buildDir = "build";
const manifestPath = join(buildDir, "posts.json");

async function main() {
  const args = getopts(process.argv.slice(2));
  const out = args._[0];
  if (args.h || args.help) {
    usage(process.stdout);
  } else if (args._.length !== 1) {
    usage(process.stderr);
    process.exit(1);
  } else if (out === join(buildDir, "stamp")) {
    await genJsonFiles();
    Bun.write(out, "");
  } else {
    await genHtmlFile(out);
  }
}

// Data stored in the posts manifest file.
type Manifest = (Metadata & { path: string })[];

// Data stored in the JSON file for each post.
interface Neighbors {
  older: string;
  newer: string;
}

// Generates JSON files in the build directory.
async function genJsonFiles() {
  const filenames = await readdir(srcPostDir);
  const posts: Manifest = reverseChronological(
    await Promise.all(
      filenames
        .filter((n) => n.endsWith(".md"))
        .map(async (name) => {
          const srcPath = join(srcPostDir, name);
          const dstPath = join(dstPostDir, removeExt(name), "index.html");
          const [meta, _rest] = splitMetadata(await Bun.file(srcPath).text());
          return { path: dstPath, ...meta };
        })
    )
  );
  writeIfChanged(manifestPath, JSON.stringify(posts));
  posts.forEach(({ path }, i) => {
    const out = join(buildDir, changeExt(path, ".json"));
    const neighbors = { newer: posts[i - 1]?.path, older: posts[i + 1]?.path };
    writeIfChanged(out, JSON.stringify(neighbors));
  });
}

// Generates an HTML file in $DESTDIR.
async function genHtmlFile(fullFile: string) {
  const destDir = must(process.env[destDirVar]);
  assert(fullFile.startsWith(destDir + "/"));
  const file = fullFile.slice(destDir.length + 1);
  const postsJson = new PostsJson();
  const postSrc = new PostSrc(file);
  const template = new Template();
  const highlight = new Highlight();
  const markdown = new Markdown(highlight);
  const html = await genHtml(
    file,
    postsJson,
    postSrc,
    template,
    markdown,
  );
  Bun.write(fullFile, postprocess(html));
  highlight.close();
  const deps = [];
  for (const d of [markdown, template, postsJson, postSrc]) {
    deps.push(...d.deps());
  }
  Bun.write(
    join(buildDir, changeExt(file, ".d")),
    `$(${destDirVar})/${file}: ${deps.join(" ")}`
  );
}

// TODO: fix, this is weird
class PostsJson {
  private used = false;

  async posts(): Promise<Manifest> {
    this.used = true;
    return JSON.parse(await Bun.file(manifestPath).text());
  }

  deps(): string[] {
    return this.used ? [manifestPath] : [];
  }
}

// TODO: fix, this is weird
class PostSrc {
  private used = false;
  private dst: string;

  constructor(dst: string) {
    this.dst = dst;
  }

  async get(): Promise<[string, Neighbors]> {
    this.used = true;
    return Promise.all([
      Bun.file(this.md()).text(),
      Bun.file(this.json()).text().then(JSON.parse),
    ]);
  }

  private md(): string {
    return join(srcPostDir, basename(dirname(this.dst))) + ".md";
  }

  private json(): string {
    return join(buildDir, changeExt(this.dst, ".json"));
  }

  deps(): string[] {
    return this.used ? [this.md(), this.json()] : [];
  }
}

async function genHtml(
  file: string,
  postsJson: PostsJson,
  postSrc: PostSrc,
  template: Template,
  markdown: Markdown,
): Promise<string> {
  switch (file) {
    case "index.html":
      return genIndex(await postsJson.posts(), template, markdown);
    case "post/index.html":
      return genArchive(await postsJson.posts(), template);
    case "categories/index.html":
      return genCategories(await postsJson.posts(), template);
    default:
      const [content, neighbors] = await postSrc.get();
      return genPost(content, neighbors, template, markdown);
  }
}

// Generates the blog homepage.
function genIndex(
  posts: Manifest,
  template: Template,
  markdown: Markdown
): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  const root = "";
  const title = "Mitchell Kember";
  const postsPromise = Promise.all(
    posts.slice(0, 10).map(async ({ path, title, date, summary }) => ({
      date: dateFormat(date, "dddd, d mmmm yyyy"),
      href: path,
      title,
      summary: await markdown.render(summary),
    }))
  );
  return template.render("templates/base.html", {
    root,
    title,
    analytics: analytics && Bun.file(analytics).text(),
    math: postsPromise.then(() => markdown.encounteredMath),
    body: template.render("templates/index.html", {
      title,
      home_url: process.env["HOME_URL"],
      posts: postsPromise,
      copyright: template.render("templates/copyright.html", {
        year: new Date().getFullYear().toString(),
      }),
    }),
  });
}

// Generates the blog post archive.
function genArchive(posts: Manifest, template: Template): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  const root = "../";
  const title = "Post Archive";
  return template.render("templates/base.html", {
    root,
    title,
    analytics: analytics && Bun.file(analytics).text(),
    body: template.render("templates/listing.html", {
      root,
      title,
      groups: groupBy(posts, (post) => dateFormat(post.date, "yyyy")).map(
        ([year, posts]) => ({
          name: year,
          pages: posts.map(({ path, title, date }) => ({
            date: dateFormat(date, "d mmm yyyy"),
            href: path.slice("post/".length),
            title,
          })),
        })
      ),
      copyright: template.render("templates/copyright.html", {
        year: new Date().getFullYear().toString(),
      }),
    }),
  });
}

// Generates the blog post categories page.
function genCategories(posts: Manifest, template: Template): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  const root = "../";
  const title = "Categories";
  return template.render("templates/base.html", {
    root,
    title,
    analytics: analytics && Bun.file(analytics).text(),
    body: template.render("templates/listing.html", {
      root,
      title,
      groups: groupBy(posts, (post) => post.category).map(
        ([category, posts]) => ({
          name: category,
          pages: posts.map(({ path, title, date }) => ({
            date: dateFormat(date, "d mmm yyyy"),
            href: join("..", path),
            title,
          })),
        })
      ),
      copyright: template.render("templates/copyright.html", {
        year: new Date().getFullYear().toString(),
      }),
    }),
  });
}

// Generates a blog post from its Markdown content.
function genPost(
  fileContent: string,
  navigation: Neighbors,
  template: Template,
  markdown: Markdown
): Promise<string> {
  const [meta, bodyMd] = splitMetadata(fileContent);
  const bodyHtml = markdown.render(bodyMd);
  const analytics = process.env["ANALYTICS"];
  const root = "../../";
  return template.render("templates/base.html", {
    root,
    title: meta.title,
    math: bodyHtml.then(() => markdown.encounteredMath),
    analytics: analytics && Bun.file(analytics).text(),
    body: template.render("templates/post.html", {
      title: markdown.renderInline(meta.title),
      date: dateFormat(meta.date, "dddd, d mmmm yyyy"),
      description: markdown.renderInline(meta.description),
      body: bodyHtml,
      pagenav: template.render("templates/pagenav.html", {
        home: process.env["HOME_URL"],
        root,
        older:
          navigation.older?.replace(/^posts\/(.+)\.md$/, "../$1/index.html") ??
          "../index.html",
        newer:
          navigation.newer?.replace(/^posts\/(.+)\.md$/, "../$1/index.html") ??
          "../../index.html",
      }),
    }),
  });
}

// Metadata for a blog post.
interface Metadata {
  title: string;
  description: string;
  category: string;
  // Format: YYYY-MM-DD.
  date: string;
  summary: string;
}

// Parses YAML-ish metadata at the top of a Markdown file between `---` lines.
// Returns the metadata and the rest of the file content.
function splitMetadata(content: string): [Metadata, string] {
  const [before, body] = content.split("\n---\n", 2);
  const fields = before
    .replace(/^---\n/, "")
    .replace(/^(\w+):\s*(.*?)\s*$/gm, '"$1":"$2"')
    .replace(/\n/g, ",");
  const meta = JSON.parse("{" + fields + "}");
  const match = body.match(/^\s*(.*)/);
  if (!match) throw Error("post has no summary paragraph");
  meta.summary = match[1];
  return [meta, body];
}

// Renders Markdown to HTML using the marked library with extensions.
class Markdown {
  encounteredMath = false;
  embeddedAssets = new Set<string>();

  constructor(server: Highlight) {
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
      walkTokens: async (token) => {
        switch (token.type as string) {
          case "code":
            const code = token as Code;
            code.highlighted = code.lang
              ? await server.highlight(code.lang, code.text)
              : code.text;
            break;
          case "image":
            const image = token as unknown as Image;
            if (image.href.endsWith(".svg")) {
              const path = join(srcPostDir, image.href);
              this.embeddedAssets.add(path);
              image.svg = await Bun.file(path).text();
            } else {
              const match = image.href.match(/^\.\.\/assets\/(.*)$/);
              image.href = "../../" + must(match)[1];
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
  href: string;
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
        href: match[3],
        tokens,
      };
    }
  },
  renderer(token) {
    const { href, svg, above, tokens } = token as Image;
    const caption = this.parser.parseInline(tokens);
    const img = svg ?? `<img src=${href}>`;
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
    const items = this.parser.parse(must(tokens));
    return `\
<div class="footnotes" role="doc-endnotes"><hr><ol>${items}</ol></div>`;
  },
};

const footnoteDefItemExt: marked.RendererExtension = {
  name: "footnote_def_item",
  renderer(token) {
    const { id, tokens } = token as FootnoteDefItem;
    const content = this.parser.parseInline(must(tokens)).trimEnd();
    return `\
<li id = "fn:${id}">\
<p>${content}&nbsp;\
<a href="#fnref:${id}" class="footnote-backref" role="doc-backlink">↩︎</a>\
</p>\
</li>`;
  },
};

// A context provides values for variables in a template. The values can be
// promises, e.g. the result of rendering another template.
type Context = Record<string, ContextValue | Promise<ContextValue>>;

// Like `Context` but all promises have been resolved.
type ConcreteContext = Record<string, ContextValue>;

// Types allowed for variable values in templates.
type ContextValue =
  | string
  | boolean
  | ContextValue[]
  | NestedContext
  | undefined;

// Helper for defining `ContextValue` recursively.
interface NestedContext extends Record<string, ContextValue> {}

// Commands used in a parsed template.
type TemplateCommand =
  | { kind: "text"; text: string }
  | { kind: "var"; variable: string }
  | { kind: "begin"; variable: string; negate: boolean }
  | { kind: "end" };

// Renders HTML templates using syntax similar to Go templates.
class Template {
  private cache: Map<string, TemplateCommand[]> = new Map();

  // Renders an HTML template.
  async render(path: string, context: Context): Promise<string> {
    let template = this.cache.get(path);
    if (template === undefined) {
      template = Template.parse(await Bun.file(path).text());
      this.cache.set(path, template);
    }
    const values = await Promise.all(Object.values(context));
    return Template.apply(
      template,
      Object.fromEntries(Object.keys(context).map((key, i) => [key, values[i]]))
    );
  }

  deps(): string[] {
    return Array.from(this.cache.keys());
  }

  private static parse(source: string): TemplateCommand[] {
    const commands: TemplateCommand[] = [];
    let offset = 0;
    const ifVarStack = [];
    for (const match of source.matchAll(
      /(\s*)\{\{\s*(?:(end|else)|(?:(if|range)\s*)?(\S+))\s*\}\}/g
    )) {
      const idx = must(match.index);
      let text = source.slice(offset, idx);
      const [wholeMatch, whitespace, endOrElse, ifOrRange, variable] = match;
      if (!ifOrRange && variable) text += whitespace;
      commands.push({ kind: "text", text });
      offset = idx + wholeMatch.length;
      if (endOrElse === "end") {
        commands.push({ kind: "end" });
        ifVarStack.pop();
      } else if (endOrElse === "else") {
        commands.push({ kind: "end" });
        const variable = must(ifVarStack[ifVarStack.length - 1]);
        commands.push({ kind: "begin", variable, negate: true });
      } else if (ifOrRange) {
        commands.push({ kind: "begin", variable, negate: false });
        ifVarStack.push(variable);
      } else {
        commands.push({ kind: "var", variable });
      }
    }
    commands.push({ kind: "text", text: source.slice(offset).trimEnd() });
    return commands;
  }

  private static apply(
    commands: TemplateCommand[],
    context: ConcreteContext
  ): string {
    let result = "";
    const go = (i: number, context: ConcreteContext) => {
      while (i < commands.length) {
        const cmd = commands[i++];
        switch (cmd.kind) {
          case "text": {
            result += cmd.text;
            break;
          }
          case "var": {
            let value = context[cmd.variable];
            result += must(
              value,
              `Missing template variable "${cmd.variable}"`
            );
            break;
          }
          case "begin": {
            const value = context[cmd.variable];
            if (!value === cmd.negate) {
              let values: ContextValue[] = Array.isArray(value)
                ? value
                : [value];
              for (const v of values) {
                let ctx = { ...context, ".": v };
                if (typeof v === "object" && !Array.isArray(v)) {
                  ctx = { ...ctx, ...(v as object) };
                }
                go(i, ctx);
              }
            }
            for (let depth = 1; depth > 0; i++) {
              if (commands[i].kind === "begin") depth++;
              else if (commands[i].kind === "end") depth--;
            }
            break;
          }
          case "end":
            return;
        }
      }
    };
    go(0, context);
    return result;
  }
}

// Client that communicates with hlsvc/main.go over a Unix socket.
class Highlight {
  private state:
    | { mode: "init" }
    | { mode: "connecting"; promise: Promise<Socket> }
    | { mode: "connected"; socket: Socket };
  private responses: Deferred<string>[] = [];

  constructor() {
    this.state = { mode: "init" };
  }

  async highlight(lang: string, code: string): Promise<string> {
    const response = defer<string>();
    this.responses.push(response);
    (await this.socket()).write(`${lang}:${code}\0`);
    return response.promise;
  }

  close(): void {
    assert(this.state.mode !== "connecting");
    if (this.state.mode === "connected") {
      this.state.socket.end();
    }
  }

  private async socket(): Promise<Socket> {
    switch (this.state.mode) {
      case "init":
        const deferred = defer<Socket>();
        this.state = { mode: "connecting", promise: deferred.promise };
        this.connect(
          hlsvcSocket,
          (socket: Socket) => {
            this.state = { mode: "connected", socket };
            deferred.resolve(socket);
          },
          deferred.reject
        );
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
    onFailure: () => void
  ) {
    let buffer = "";
    Bun.connect({
      unix: path,
      socket: {
        binaryType: "uint8array",
        open: (socket) => onSuccess(socket),
        data: (socket, data: Uint8Array) => {
          buffer += new TextDecoder().decode(data);
          let idx;
          while ((idx = buffer.indexOf("\0")) >= 0) {
            this.handleResponse(buffer.slice(0, idx));
            buffer = buffer.slice(idx + 1);
          }
        },
        error: (socket, error) => {
          this.nextWaiting().reject(error);
        },
      },
    }).catch(onFailure);
  }

  private handleResponse(raw: string) {
    const next = this.nextWaiting();
    const eat = (prefix: string) =>
      raw.startsWith(prefix) && raw.slice(prefix.length);
    let errMsg;
    if ((errMsg = eat("error:"))) {
      next.reject(new Error(`server responded with error: ${errMsg}`));
    } else {
      next.resolve(raw);
    }
  }

  private nextWaiting(): Deferred<string> {
    return must(this.responses.shift());
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

// Writes content to path if is different from its current content.
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

// Changes the extension of a path.
function changeExt(path: string, ext: string): string {
  return removeExt(path) + ext;
}

// Removes the extension from a path.
function removeExt(path: string): string {
  return path.slice(0, path.lastIndexOf("."));
}

// Sorts an array with YYYY-MM-DD dates in reverse chronological order.
function reverseChronological<T extends { date: string }[]>(array: T): T {
  return array.sort((a, b) => b.date.localeCompare(a.date));
}

// Groups an array into subarrays where each item has the same key.
function groupBy<T, U>(array: T[], key: (item: T) => U): [U, T[]][] {
  const map = new Map<U, T[]>();
  for (const item of array) {
    const k = key(item);
    if (map.has(k)) {
      map.get(k)?.push(item);
    } else {
      map.set(k, [item]);
    }
  }
  return Array.from(map.entries());
}

// Asserts that `condition` is true.
function assert(condition: boolean, msg?: string): asserts condition {
  if (!condition) {
    throw Error(msg);
  }
}

// Asserts that a value is not undefined.
function must<T>(value: T | undefined | null, msg?: string): T {
  assert(value != undefined, msg);
  return value;
}

interface Deferred<T> {
  promise: Promise<T>;
  value: T | undefined;
  resolve: (value: T) => void;
  reject: (reason?: any) => void;
}

// Returns a promise that can be manually resolved or rejected from the outside.
function defer<T>(): Deferred<T> {
  const obj = {} as Deferred<T>;
  obj.promise = new Promise<T>((resolve, reject) => {
    obj.resolve = (value) => {
      obj.value = value;
      resolve(value);
    };
    obj.reject = reject;
  });
  return obj;
}

await main();
