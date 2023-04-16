// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import dateFormat from "dateformat";
import { readdir } from "fs/promises";
import { basename, join } from "path";
import { Writable } from "stream";
import { HlsvcClient } from "./hlsvc";
import { MarkdownRenderer } from "./markdown";
import { TemplateRenderer } from "./template";
import {
  changeExt,
  eatPrefix,
  groupBy,
  removeExt,
  writeIfChanged,
} from "./util";

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
// TODO: extend metadata
// TODO: GlobalManifest?
interface Entry extends Metadata {
  slug: string;
  // First paragraph of the post body.
  summary: string;
}

// External information stored in per-post JSON files.
// TODO: LocalManifest?
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
        return { slug, summary, ...meta };
      })
  );
  // Sort posts in reverse chronological order.
  posts.sort((a, b) => b.date.localeCompare(a.date));
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
  if (!destDir) throw Error(`$${destDirVar} is not set`);
  const relPath = eatPrefix(path, destDir + "/");
  if (!relPath) throw Error(`invalid html file path: ${path}`);
  const hlsvc = new HlsvcClient();
  const input = new Input();
  const template = new TemplateRenderer();
  const markdown = new MarkdownRenderer(hlsvc, srcPostDir);
  const html = await render(relPath, input, template, markdown);
  Bun.write(path, postprocess(html));
  hlsvc.close();
  const deps = [input, template, markdown].flatMap((x) => x.deps());
  Bun.write(
    join(buildDir, changeExt(relPath, ".d")),
    `$(${destDirVar})/${relPath}: ${deps.join(" ")}`
  );
}

async function render(
  relPath: string,
  input: Input,
  template: TemplateRenderer,
  markdown: MarkdownRenderer
): Promise<string> {
  const analytics = process.env["ANALYTICS"];
  template.define({
    root: relPath.replaceAll(/[^/]+/g, "..").replace(/\.\.$/, ""),
    analytics: analytics ? Bun.file(analytics).text() : false,
    home_url: process.env["HOME_URL"] ?? false,
    year: new Date().getFullYear().toString(),
  });
  switch (relPath) {
    case "index.html":
      return renderIndex(await input.posts(), template, markdown);
    case "post/index.html":
      return renderArchive(await input.posts(), template);
    case "categories/index.html":
      return renderCategories(await input.posts(), template);
    default: {
      const match = relPath.match(/^post\/(.*)\/index.html$/);
      if (!match) throw Error(`invalid post file path: ${relPath}`);
      const slug = match[1];
      const [post, info] = await Promise.all([
        input.post(slug),
        input.externalInfo(slug),
      ]);
      return renderPost(post, info, template, markdown);
    }
  }
}

// Renders the blog homepage.
function renderIndex(
  posts: Entry[],
  template: TemplateRenderer,
  markdown: MarkdownRenderer
): Promise<string> {
  const postsPromise = Promise.all(
    posts.slice(0, 10).map(async ({ slug, summary, title, date }) => ({
      date: dateFormat(date, "dddd, d mmmm yyyy"),
      href: `post/${slug}/index.html`,
      title,
      summary: await markdown.render(summary),
    }))
  );
  return template.render("templates/index.html", {
    title: "Mitchell Kember",
    math: postsPromise.then(() => markdown.encounteredMath),
    posts: postsPromise,
  });
}

// Renders the blog post archive.
function renderArchive(
  posts: Entry[],
  template: TemplateRenderer
): Promise<string> {
  return template.render("templates/listing.html", {
    title: "Post Archive",
    math: false,
    groups: groupBy(posts, (post) => dateFormat(post.date, "yyyy")).map(
      ([year, posts]) => ({
        name: year,
        pages: posts.map(({ slug, title, date }) => ({
          date: dateFormat(date, "d mmm yyyy"),
          href: `${slug}/index.html`,
          title,
        })),
      })
    ),
  });
}

// Renders the blog post categories page.
function renderCategories(
  posts: Entry[],
  template: TemplateRenderer
): Promise<string> {
  return template.render("templates/listing.html", {
    title: "Categories",
    math: false,
    groups: groupBy(posts, (post) => post.category).map(
      ([category, posts]) => ({
        name: category,
        pages: posts.map(({ slug, title, date }) => ({
          date: dateFormat(date, "d mmm yyyy"),
          href: `../post/${slug}/index.html`,
          title,
        })),
      })
    ),
  });
}

// Renders a blog post from its Markdown content.
function renderPost(
  post: Post,
  info: ExternalInfo,
  template: TemplateRenderer,
  markdown: MarkdownRenderer
): Promise<string> {
  const html = markdown.render(post.body);
  return template.render("templates/post.html", {
    title: markdown.renderInline(post.meta.title),
    math: html.then(() => markdown.encounteredMath),
    date: dateFormat(post.meta.date, "dddd, d mmmm yyyy"),
    description: markdown.renderInline(post.meta.description),
    article: html,
    older: info.older ? `../${info.older}/index.html` : "../index.html",
    newer: info.newer ? `../${info.newer}/index.html` : "../../index.html",
  });
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

await main();
