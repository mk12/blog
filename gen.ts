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

// const depFile = (p: Path) => join(buildDir, changeExt(p, ".d"));
// const srcFile = (p: Path) => join(srcPostDir, basename(dirname(p))) + ".md";
// const navFile = (p: Path) => join(buildDir, changeExt(p, ".json"));

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

// Parses the metadata from a block post.
function parsePost(content: string): Post {
  const [before, body] = content.split("\n---\n", 2);
  const fields = before
    .replace(/^---\n/, "")
    .replace(/^(\w+):\s*(.*?)\s*$/gm, '"$1":"$2"')
    .replace(/\n/g, ",");
  const metadata = JSON.parse("{" + fields + "}");
  return { meta: metadata, body };
}

// Returns the first paragraph of the post body.
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
    writeIfChanged(`build/post/${slug}/index.json`, JSON.stringify(info));
  });
}

// Generates an HTML file in $DESTDIR.
async function genHtmlFile(path: string) {
  const destDir = process.env[destDirVar];
  if (!destDir) throw Error(`\$${destDirVar} is not set`);
  const relPath = eatPrefix(path, destDir + "/");
  if (!relPath) throw Error(`${path}: invalid target path`);
  const hlsvc = new Hlsvc();
  const input = new Input();
  const template = new Template();
  const markdown = new Markdown(hlsvc);
  const html = await render(relPath, input, template, markdown);
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
    return parsePost(await this.read(join(srcPostDir, slug + ".md")));
  }

  async externalInfo(slug: string): Promise<ExternalInfo> {
    return JSON.parse(await this.read(`${buildDir}/post/${slug}/index.json`));
  }

  deps(): string[] {
    return Array.from(this.files);
  }
}

async function render(
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
      if (!match) throw Error(`${relPath}: invalid post path`);
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
  const root = "";
  const title = "Mitchell Kember";
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
function genArchive(posts: Entry[], template: Template): Promise<string> {
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
      copyright: template.render("templates/copyright.html", {
        year: new Date().getFullYear().toString(),
      }),
    }),
  });
}

// Generates the blog post categories page.
function genCategories(posts: Entry[], template: Template): Promise<string> {
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
      copyright: template.render("templates/copyright.html", {
        year: new Date().getFullYear().toString(),
      }),
    }),
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
  const root = "../../";
  return template.render("templates/base.html", {
    root,
    title: post.meta.title,
    math: bodyHtml.then(() => markdown.encounteredMath),
    analytics: analytics && Bun.file(analytics).text(),
    body: template.render("templates/post.html", {
      title: markdown.renderInline(post.meta.title),
      date: dateFormat(post.meta.date, "dddd, d mmmm yyyy"),
      description: markdown.renderInline(post.meta.description),
      body: bodyHtml,
      pagenav: template.render("templates/pagenav.html", {
        home: process.env["HOME_URL"],
        root,
        older: info.older ? `../${info.older}/index.html` : "../index.html",
        newer: info.newer ? `../${info.newer}/index.html` : "../../index.html",
      }),
    }),
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
      const idx = match.index;
      if (idx === undefined)
        throw Error(`invalid template command: ${match[0]}`);
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
        const variable = ifVarStack[ifVarStack.length - 1];
        if (!variable) throw Error("else without corresponding if");
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
            if (value === undefined)
              throw Error(`missing template variable "${cmd.variable}"`);
            result += value;
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

// Sorts an array by date in reverse chronological order.
function reverseChronological<T extends { date: YmdDate }[]>(array: T): T {
  return array.sort((a, b) => b.date.localeCompare(a.date));
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
