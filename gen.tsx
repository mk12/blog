// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import getopts from "getopts";
import { marked, Slugger } from "marked";
import { renderToStaticMarkup } from "react-dom/server";
import dateFormat from "dateformat";

async function main() {
  const args = getopts(process.argv.slice(2));
  let html;
  if (args._.length === 1) {
    html = await genPost(args._[0]);
  } else {
    console.error("TODO");
    return;
  }
  Bun.write(args.o, postprocess(html));
}

// Postprocesses HTML before it will be emitted.
function postprocess(html: string): string {
  // Avoid unnecessary entities.
  const map: Record<string, string> =
    { quot: '"', "#34": '"', apos: "'", "#39": "'", gt: ">", "#62": ">" };
  return html.replace(
    /&(#\d+|[a-z]+);/g,
    (entity: string, code: string) => map[code] ?? entity
  );
}

// Generates a blog post. Reads Markdown from `src` and writes HTML to `dst`.
// Also writes Makefile dependency rules to `dep`.
async function genPost(srcPath: string) {
  const content = await Bun.file(srcPath).text();
  const [meta, body] = extractMetadata(content);
  const footnote: marked.TokenizerAndRendererExtension = {
    name: "footnote",
    level: "inline",
    start(src) {
      return src.indexOf("[^");
    },
    tokenizer(src) {
      const match = src.match(/^\[\^(\w+)\]/);
      if (match) {
        const id = match[1];
        return { type: "footnote", raw: match[0], id };
      }
    },
    renderer({ id }) {
      return `<sup id="fnref:${id}"><a href="#fn:${id}" class="footnote-ref" role="doc-noteref">${id}</a></sup>`;
    },
  };
  const footnoteDefBlock: marked.TokenizerAndRendererExtension = {
    name: "footnote_def_block",
    level: "block",
    start(src) {
      return src.indexOf("[^");
    },
    tokenizer(src) {
      const match = src.match(/^(\[\^(\w+)\]:(?:[^:\n]*(?:\n|$))+(?:\n|$))+/);
      if (match) {
        console.error("BLOCK");
        const token = { type: "footnote_def_block", raw: match[0], tokens: [] };
        this.lexer.inline(match[0], token.tokens);
        return token;
      }
    },
    renderer({ tokens }) {
      return `<div class="footnotes" role="doc-endnotes"><hr><ol>${this.parser.parse(
        tokens
      )}</ol></div>`;
    },
  };
  const footnoteDefItem: marked.TokenizerAndRendererExtension = {
    name: "footnote_def_item",
    level: "inline",
    start(src) {
      return src.indexOf("[^");
    },
    tokenizer(src) {
      const match = src.match(/^\[\^(\w+)\]:((?:[^:\n]*(?:\n|$))+)/);
      if (match) {
        console.error("DEF");
        const token = {
          type: "footnote_def_item",
          raw: match[0],
          id: match[1],
          tokens: [],
        };
        this.lexer.inline(match[2], token.tokens);
        return token;
      }
    },
    renderer({ id, tokens }) {
      return `
        <li id = "fn:${id}">
          <p>${this.parser
          .parseInline(tokens)
          .trimEnd()}&nbsp;<a href="#fnref:${id}" class="footnote-backref" role="doc-backlink">↩︎</a></p>
        </li> `;
    },
  };
  marked.use({
    smartypants: true,
    extensions: [footnote, footnoteDefBlock, footnoteDefItem],
  });
  const analytics = process.env["ANALYTICS"];
  const render = await template("templates/base.html");
  return render({
    title: meta.title,
    root: "../../",
    analytics: analytics && (await Bun.file(analytics).text()),
    main: renderToStaticMarkup(<Post meta={meta} main={marked(body)} />),
  });
}

// Metadata for a blog post.
interface Metadata {
  title: string;
  description: string;
  categories: string[];
  date: Date;
}

// Parses metadata surrounded by `---` lines at the top of a Markdown file.
// Assumes a restricted subset of YAML, which it massages into JSON for parsing.
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

// Parses a template that contains directives like `{{ foo }}`. Returns a
// function that renders the template given variable mappings.
async function template(path: string) {
  const text = await Bun.file(path).text();
  return (variables: Record<string, string | undefined>) =>
    text.replace(/(\s*)\{\{\s*(\w+)\s*\}\}/g, (str, space, name: string) => {
      const val = variables[name];
      return val ? space + val : "";
    });
}

function Post(props: { meta: Metadata; main: string }) {
  const nav = <PageNav older="1" newer="2" />;
  const date = dateFormat(props.meta.date, "dddd, d mmmm yyyy");
  return (
    <>
      <header>{nav}</header>
      <article>
        <span className="post-meta">{date}</span>
        <h2 className="post-title">{props.meta.title}</h2>
        <h3 className="post-description">{props.meta.description}</h3>
        <div dangerouslySetInnerHTML={{ __html: props.main }} />
      </article>
      <footer>{nav}</footer>
    </>
  );
}

function PageNav(props: { newer: string; older: string }) {
  const homeUrl = process.env["HOME_URL"];
  const home = homeUrl && (
    <li className="nav-home">
      <a href={homeUrl}>Home</a>
    </li>
  );
  return (
    <nav className="page-nav">
      <ul>
        <li className="nav-newer">
          <a href={props.newer}>
            «&nbsp;New<span>er</span>
          </a>
        </li>
        {home}
        <li className="nav-toc">
          <a href="../../index.html">Blog</a>
        </li>
        <li className="nav-older">
          <a href={props.older}>
            Old<span>er</span>&nbsp;»
          </a>
        </li>
      </ul>
    </nav>
  );
}

await main();
