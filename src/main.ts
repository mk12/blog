// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import dateFormat from "dateformat";
import { mkdirSync, symlinkSync } from "fs";
import { basename, dirname, join, relative, resolve } from "path";
import { Writable } from "stream";
import { HlsvcClient } from "./hlsvc";
import { MarkdownRenderer } from "./markdown";
import { TemplateRenderer } from "./template";
import { Writer, groupBy, removeExt } from "./util";

function usage(out: Writable) {
  const program = basename(process.argv[1]);
  out.write(
    `Usage: bun run ${program} DIR FILE

Generate DIR/FILE and its depfile DIR/FILE.d
`
  );
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("-h") || args.includes("--help")) {
    usage(process.stdout);
    return;
  }
  if (args.length !== 2) {
    usage(process.stderr);
    process.exit(1);
  }
  const [dir, file] = process.argv.slice(2);
  const writer = new Writer();
  await generate(dir, file, writer);
  await writer.wait();
}

const srcPostDir = "posts";
const dstPostDir = "post";
const srcAssetDir = "assets";
const postsFile = join(process.env["DESTDIR"]!, ".posts.json");
const slug = (path: string) => basename(dirname(path));
const srcFile = (path: string) => join(srcPostDir, slug(path) + ".md");

// YAML metadata from the top of a Markdown file.
interface Metadata {
  title: string;
  description: string;
  category: string;
  date: Rfc3339Date | "DRAFT";
}

// A timestamp that remembers the local date for its timezone.
type Rfc3339Date = string;

// Information about a post stored in posts.json.
interface Post extends Metadata {
  // Path relative to the blog root.
  path: string;
  // First paragraph of the post body.
  summary: string;
}

// A full post with metadata parsed out.
interface PostWithBody extends Metadata {
  // Markdown post body.
  body: string;
}

// Contextual information stored in per-post JSON files.
interface Context {
  // Path of the next older post, if one exists.
  older?: string;
  // Path of the next newer post, if one exists.
  newer?: string;
}

// A full post with metadata parsed out.
interface PostWithBody extends Metadata {
  // Markdown post body.
  body: string;
}

// All the information needed to render a post page.
interface PostWithContext extends PostWithBody, Context {}

// Generates an HTML file in $DESTDIR.
async function generate(destDir: string, path: string, writer: Writer) {
  const fullPath = join(destDir, path);
  const input = new InputReader();
  const template = new TemplateRenderer();
  const hlsvc = new HlsvcClient();
  const link = new LinkMaker(path);
  const markdown = new MarkdownRenderer(hlsvc, (srcPath: string) => {
    const parts = srcPath.split("/");
    if (parts.length === 2 && parts[0] === srcPostDir) {
      if (!parts[1].endsWith(".md")) {
        throw Error(`expected .md path: ${srcPath}`);
      }
      return link.to(`${dstPostDir}/${removeExt(parts[1])}/index.html`);
    }
    if (parts.length > 1 && parts[0] === srcAssetDir) {
      const path = join(...parts.slice(1));
      const dest = join(destDir, path);
      mkdirSync(dirname(dest), { recursive: true });
      try {
        symlinkSync(resolve(srcPath), dest);
      } catch {
        // Ignore.
      }
      return link.to(path);
    }
  });
  const html = await renderHtml(path, input, { template, markdown, link });
  hlsvc.close();
  writer.write(fullPath, postprocess(html));
  const deps = [input, template, markdown].flatMap((x) => x.deps()).join(" ");
  writer.write(fullPath + ".d", `${fullPath}: ${deps}`);
}

// Tools used to render HTML pages.
interface Tools {
  template: TemplateRenderer;
  markdown: MarkdownRenderer;
  link: LinkMaker;
}

// Renders a page, returning a string of HTML.
async function renderHtml(path: string, input: InputReader, tools: Tools) {
  const { template, link } = tools;
  const analytics = process.env["ANALYTICS"];
  template.define({
    author: "Mitchell Kember",
    homeUrl: process.env["HOME_URL"] ?? false,
    blogUrl: link.to("index.html"),
    styleUrl: link.to("style.css"),
    analytics: analytics
      ? Bun.file(analytics)
          .text()
          .then((s) => s.trim())
      : false,
    year: new Date().getFullYear().toString(),
  });
  switch (path) {
    case "index.html":
      return renderIndex(await input.posts(), tools);
    case "index.xml":
      return renderRssFeed(await input.posts(), tools);
    case "post/index.html":
      return renderArchive(await input.posts(), tools);
    case "categories/index.html":
      return renderCategories(await input.posts(), tools);
    default:
      return renderPost(await input.post(path), tools);
  }
}

// Renders the blog homepage.
function renderIndex(posts: Post[], { template, markdown, link }: Tools) {
  const recentPosts = Promise.all(
    posts.slice(0, 10).map(async ({ path, summary, title, date }) => ({
      date: fmtDate(date, "dddd, d mmmm yyyy"),
      href: link.to(path),
      title: markdown.renderInline(title),
      summary: await markdown.render(summary, srcPostDir),
    }))
  );
  return template.render("templates/index.html", {
    title: "Mitchell Kember",
    math: recentPosts.then(() => markdown.encounteredMath),
    posts: recentPosts,
    archiveUrl: link.to("post/index.html"),
    categoriesUrl: link.to("categories/index.html"),
  });
}

// Renders the RSS feed XML file.
function renderRssFeed(posts: Post[], { template, markdown, link }: Tools) {
  const allPosts = Promise.all(
    posts.map(async ({ path, title, date, summary }) => ({
      title: markdown.renderInline(title),
      url: link.to(path),
      date: date === "DRAFT" ? false : new Date(date).toUTCString(),
      description: await markdown.render(summary, srcPostDir),
    }))
  );
  return template.render("templates/feed.xml", {
    title: "Mitchell Kember",
    feedUrl: link.to("index.xml"),
    lastBuildDate: new Date().toUTCString(),
    posts: allPosts,
  });
}

// Renders the blog post archive.
function renderArchive(posts: Post[], { template, markdown, link }: Tools) {
  return template.render("templates/listing.html", {
    title: "Post Archive",
    math: false,
    groups: groupBy(posts, (post) => fmtDate(post.date, "yyyy")).map(
      ([year, posts]) => ({
        name: year,
        pages: posts.map(({ path, title, date }) => ({
          // TODO: Remove period after month.
          date: fmtDate(date, "d mmm. yyyy"),
          href: link.to(path),
          title: markdown.renderInline(title),
        })),
      })
    ),
  });
}

// Renders the blog post categories page.
function renderCategories(posts: Post[], { template, markdown, link }: Tools) {
  return template.render("templates/listing.html", {
    title: "Categories",
    math: false,
    groups: groupBy(posts, (post) => post.category)
      .sort(([c1], [c2]) => c1.localeCompare(c2))
      .map(([category, posts]) => ({
        name: category,
        pages: posts.map(({ path, title, date }) => ({
          // TODO: Remove period after month.
          date: fmtDate(date, "d mmm. yyyy"),
          href: link.to(path),
          title: markdown.renderInline(title),
        })),
      })),
  });
}

// Renders a blog post from its Markdown content.
function renderPost(
  post: PostWithContext,
  { template, markdown, link }: Tools
) {
  const html = markdown.render(post.body, srcPostDir);
  return template.render("templates/post.html", {
    title: markdown.renderInline(post.title),
    math: html.then(() => markdown.encounteredMath),
    date: fmtDate(post.date, "dddd, d mmmm yyyy"),
    description: markdown.renderInline(post.description),
    article: html,
    older: link.to(post.older ?? "post/index.html"),
    newer: link.to(post.newer ?? "index.html"),
  });
}

// Manages access to input sources.
class InputReader {
  private files = new Set<string>();

  private read(file: string): Promise<string> {
    this.files.add(file);
    return Bun.file(file).text();
  }

  async posts(): Promise<Post[]> {
    return JSON.parse(await this.read(postsFile));
  }

  async post(path: string): Promise<PostWithContext> {
    const [markdown, postsJson] = await Promise.all([
      this.read(srcFile(path)),
      this.read(postsFile),
    ]);
    const post = parsePost(markdown);
    const posts: Post[] = JSON.parse(postsJson);
    const i = posts.findIndex((p) => p.path === path);
    if (i < 0) throw Error(`${path}: not found in ${postsFile}`);
    const ctx = {
      newer: posts[i - 1]?.path,
      older: posts[i + 1]?.path,
    };
    return { ...post, ...ctx };
  }

  deps(): string[] {
    return Array.from(this.files);
  }
}

// Helper for making relative links.
class LinkMaker {
  private dir: string;

  constructor(from: string) {
    this.dir = dirname(from);
  }

  to(path: string) {
    const base = process.env["BASE_URL"];
    if (base) {
      if (basename(path) === "index.html")
        return join(base, dirname(path)) + "/";
      return join(base, path);
    }
    return relative(this.dir, path);
  }
}

// Parses the metadata from a blog post.
function parsePost(content: string): PostWithBody {
  const [before, body] = content.split("\n---\n", 2);
  const fields = before
    .replace(/^---\n/, "")
    .replace(/^(\w+):\s*(.*?)\s*$/gm, '"$1":"$2"')
    .replace(/\n/g, ",");
  return { ...JSON.parse("{" + fields + "}"), body };
}

// Formats a date using dateFormat.
function fmtDate(date: Rfc3339Date | "DRAFT", format: string): string {
  if (date === "DRAFT") {
    return "DRAFT";
  }
  return dateFormat(date.slice(0, "YYYY-MM-DD".length), format, /*utc=*/ true);
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
