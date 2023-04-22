// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import { stat } from "fs/promises";
import katex, { KatexOptions } from "katex";
import { marked } from "marked";
import { join } from "path";
import { HlsvcClient } from "./hlsvc";

// A Markdown-to-HTML renderer using the marked library.
export class MarkdownRenderer {
  encounteredMath = false;
  embeddedAssets = new Set<string>();
  private toUrl: (srcPath: string) => string | undefined;
  private commonWalk: (token: marked.Token) => Promise<void>;

  constructor(
    hlsvc: HlsvcClient,
    // Converts a source filesystem path to a URL.
    toUrl: (srcPath: string) => string | undefined
  ) {
    this.toUrl = toUrl;
    this.commonWalk = async (anyToken) => {
      const token = anyToken as Code | Math | DisplayMath;
      switch (token.type) {
        case "code":
          token.highlighted = token.lang
            ? await hlsvc.highlight(token.lang, token.text)
            : token.text;
          break;
        case "math":
        case "display_math":
          this.encounteredMath = true;
          break;
      }
    };
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
    });
  }

  // Renders inline Markdown to HTML.
  renderInline(src: string): string {
    return marked.parseInline(src, {
      walkTokens: (token) => {
        this.commonWalk(token);
        if (token.type === "link") {
          if (isLocalLink(token.href)) {
            throw Error(
              `local link not allowed in renderInline: ${token.href}`
            );
          }
        } else if (token.type === "image") {
          const image = token as unknown as Image;
          throw Error(`image not allowed in renderInline: ${image.src}`);
        }
      },
    });
  }

  // Renders block Markdown to HTML.
  render(src: string, sourceDir?: string): Promise<string> {
    return marked.parse(src, {
      async: true,
      walkTokens: async (token) => {
        await this.commonWalk(token);
        if (token.type === "link") {
          if (isLocalLink(token.href)) {
            let path = token.href;
            let fragment = "";
            const idx = path.indexOf("#");
            if (idx >= 0) {
              path = path.slice(0, idx);
              fragment = path.slice(idx);
            }
            if (sourceDir === undefined) {
              throw Error(`local link not allowed without sourceDir: ${token.href}`);
            }
            const url = this.toUrl(join(sourceDir, path));
            if (url === undefined)
              throw Error(`invalid local link: ${token.href}`);
            token.href = url + fragment;
          }
        } else if (token.type === "image") {
          const image = token as unknown as Image;
          if (sourceDir === undefined) {
            throw Error(`image not allowed without sourceDir: ${image.src}`);
          }
          const srcPath = join(sourceDir, image.src);
          if (image.src.endsWith(".svg")) {
            this.embeddedAssets.add(srcPath);
            image.svg = await Bun.file(srcPath).text();
          } else {
            // Make sure the file exists, even though we aren't reading it.
            await stat(srcPath);
            const url = this.toUrl(srcPath);
            if (url === undefined)
              throw Error(`invalid image src: ${image.src}`);
            image.src = url;
          }
        }
      },
    });
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

// Returns true if the link is a path in the local filesystem.
function isLocalLink(href: string): boolean {
  if (href.match(/^https?:\/\//)) return false;
  if (href.includes("://")) throw Error(`unexpected protocol: ${href}`);
  return true;
}

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
