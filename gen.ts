// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import getopts from "getopts";
import { marked } from "marked";
import dateFormat from "dateformat";
import { Socket } from "bun";
import katex, { KatexOptions } from "katex";
import { dirname, join } from "path";

function usage() {
  console.log(
    `Usage: bun run ${process.argv[1]} [-h] [-o OUTFILE] [-i INFILE] [-d DEPFILE] [-s SOCKET]

Generates an HTML page for the blog

Options:
    -h, --help  Show this help message
    -o OUTFILE  Output HTML file
    -i INFILE   Input Markdown file
    -d DEPFILE  Output depfile for Make
    -s SOCKET   Highlight server socket`
  );
}

async function main() {
  const args = getopts(process.argv.slice(2));
  if (args.h || args.help) {
    usage();
    return;
  }
  let html;
  if (args.i) {
    const [content, highlightServer] = await Promise.all([
      Bun.file(args.i).text(),
      HighlightServer.connect(args.s),
    ]);
    const template = new TemplateRenderer();
    const markdown = new MarkdownRenderer(dirname(args.i), highlightServer);
    html = await genPost(content, template, markdown);
    highlightServer.close();
  } else {
    console.error("TODO");
    return;
  }
  Bun.write(args.o, postprocess(html));
}

// Generates a blog post from its Markdown content.
async function genPost(
  fileContent: string,
  template: TemplateRenderer,
  markdown: MarkdownRenderer
): Promise<string> {
  const [meta, bodyMd] = extractMetadata(fileContent);
  const bodyHtml = markdown.render(bodyMd);
  const analytics = process.env["ANALYTICS"];
  const root = "../../";
  return template.render("base", {
    root,
    title: meta.title,
    math: bodyHtml.then(() => encounteredMath),
    analytics: analytics && Bun.file(analytics).text(),
    body: template.render("post", {
      title: markdown.renderInline(meta.title),
      date: dateFormat(meta.date, "dddd, d mmmm yyyy"),
      description: markdown.renderInline(meta.description),
      body: bodyHtml,
      pagenav: template.render("pagenav", {
        home: process.env["HOME_URL"],
        blog: root + "index.html",
      }),
    }),
  });
}

// Metadata for a blog post.
interface Metadata {
  title: string;
  description: string;
  categories: string[];
  date: Date;
}

// Parses YAML-ish metadata at the top of a Markdown file between `---` lines.
// Returns the metadata and the rest of the file content.
function extractMetadata(content: string): [Metadata, string] {
  const [before, body] = content.split("\n---\n", 2);
  const fields = before
    .replace(/^---\n/, "")
    .replace(/^(\w+):/gm, '"$1":')
    .replace(/\n/g, ",");
  const obj = JSON.parse("{" + fields + "}");
  const meta = { ...obj, date: Date.parse(obj.date) };
  return [meta, body];
}

// Renders Markdown to HTML using the marked library with extensions.
class MarkdownRenderer {
  constructor(workingDir: string, server: HighlightServer) {
    marked.use({
      smartypants: true,
      extensions: [
        codeExt,
        imageExt,
        mathExt,
        displayMathExt,
        footnoteExt,
        footnoteDefBlockExt,
        footnoteDefItemExt,
      ],
      async walkTokens(token) {
        switch (token.type) {
          case "code":
            const code = token as Code;
            code.highlighted = code.lang
              ? await server.highlight(code.lang, code.text)
              : code.text;
            break;
          case "image":
            const image = token as unknown as Image;
            if (image.href.endsWith(".svg")) {
              image.svg = await Bun.file(join(workingDir, image.href)).text();
            }
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

let encounteredMath = false;

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
      encounteredMath = true;
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
      encounteredMath = true;
      return { type: "display_math", raw: match[0], tex: match[1] };
    }
  },
  renderer(token) {
    const { tex } = token as DisplayMath;
    return katex.renderToString(tex, { ...katexOptions, displayMode: true });
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
    let raw = "",
      match;
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
type Context = {
  [variable: string]: ContextValue | Promise<ContextValue> | undefined;
};

// Types allowed for variable values in templates.
type ContextValue = string | boolean;

// Renders HTML templates using syntax similar to Go templates.
class TemplateRenderer {
  cache: Map<string, string> = new Map();

  // Renders an HTML template from the "templates/" folder.
  async render(name: string, context: Context): Promise<string> {
    let template = this.cache.get(name);
    if (template === undefined) {
      template = await Bun.file(`templates/${name}.html`).text();
      this.cache.set(name, template);
    }
    const values = await Promise.all(Object.values(context));
    const newContext = Object.fromEntries(
      Object.keys(context).map((key, i) => [key, values[i]])
    );
    return template
      .replace(
        /(\s*)\{\{\s*if\s+(\w+)\s*\}\}([\s\S]*?)\{\{\s*end\s*\}\}/g,
        (str: string, space: string, name: string, inner: string) => {
          const val = newContext[name];
          return val ? space + inner : "";
        }
      )
      .replace(
        /(\s*)\{\{\s*(\w+)\s*\}\}/g,
        (str: string, space: string, name: string) => {
          const val = newContext[name];
          return val ? space + val : "";
        }
      );
  }
}

// Client that communicates with highlight/main.go over a Unix socket.
class HighlightServer {
  private socket: Socket;
  private responses: Deferred<string>[];

  constructor(socket: Socket) {
    this.socket = socket;
    this.responses = [];
  }

  static connect(socketPath: string): Promise<HighlightServer> {
    const server = deferred<HighlightServer>();
    let buffer = "";
    Bun.connect({
      unix: socketPath,
      socket: {
        binaryType: "uint8array",
        open(socket) {
          server.resolve(new HighlightServer(socket));
        },
        data(socket, data: Uint8Array) {
          buffer += new TextDecoder().decode(data);
          let idx;
          while ((idx = buffer.indexOf("\0")) >= 0) {
            must(server.value).handleResponse(buffer.slice(0, idx));
            buffer = buffer.slice(idx + 1);
          }
        },
        error(socket, error) {
          must(server.value).nextWaiting().reject(error);
        },
      },
    }).catch(server.reject);
    return server.promise;
  }

  highlight(lang: string, code: string): Promise<string> {
    const response = deferred<string>();
    this.responses.push(response);
    this.socket.write(`${lang}:${code}\0`);
    return response.promise;
  }

  close(): void {
    this.socket.end();
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
  const map: Record<string, string> = {
    quot: '"',
    "#34": '"',
    apos: "'",
    "#39": "'",
    gt: ">",
    "#62": ">",
  };
  return html.replace(
    /&(#\d+|[a-z]+);/g,
    (entity: string, code: string) => map[code] ?? entity
  );
}

// Asserts that `condition` is true.
export function assert(condition: boolean, msg?: string): asserts condition {
  if (!condition) {
    throw new Error(msg);
  }
}

// Asserts that a value is not undefined.
export function must<T>(value: T | undefined): T {
  assert(value !== undefined);
  return value;
}

interface Deferred<T> {
  promise: Promise<T>;
  value: T | undefined;
  resolve: (value: T) => void;
  reject: (reason?: any) => void;
}

// Returns a promise that can be manually resolved or rejected from the outside.
function deferred<T>(): Deferred<T> {
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
