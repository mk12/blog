// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import dateFormat from "dateformat";
import { readdir } from "fs/promises";
import { basename, dirname, join, relative } from "path";
import { Writable } from "stream";
import { HlsvcClient } from "./hlsvc";
import { MarkdownRenderer } from "./markdown";
import { TemplateRenderer } from "./template";
import { changeExt, eat, groupBy, removeExt, writeIfChanged } from "./util";

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
const stampFile = join(buildDir, "stamp");
const postsFile = join(buildDir, "posts.json");
const slug = (path: string) => basename(dirname(path));
const srcFile = (path: string) => join(srcPostDir, slug(path) + ".md");
const depFile = (path: string) => join(buildDir, changeExt(path, ".d"));
const ctxFile = (path: string) => join(buildDir, changeExt(path, ".json"));

// YAML metadata from the top of a Markdown file.
interface Metadata {
  title: string;
  description: string;
  category: string;
  date: YmdDate;
  draft: boolean;
}

// A date in YYYY-MM-DD format.
type YmdDate = string;

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

// Generates JSON files in the build directory.
async function genJsonFiles() {
  const filenames = await readdir(srcPostDir);
  const posts: Post[] = await Promise.all(
    filenames
      .filter((n) => n.endsWith(".md"))
      .map(async (name) => {
        const srcPath = join(srcPostDir, name);
        const dstPath = join(dstPostDir, removeExt(name), "index.html");
        const { body, ...meta } = parsePost(await Bun.file(srcPath).text());
        return { path: dstPath, summary: getSummary(body), ...meta };
      })
  );
  // Sort posts in reverse chronological order.
  posts.sort((a, b) => b.date.localeCompare(a.date));
  writeIfChanged(postsFile, JSON.stringify(posts));
  // Write context files for each post.
  posts.forEach(({ path }, i) => {
    const ctx: Context = {
      newer: posts[i - 1]?.path,
      older: posts[i + 1]?.path,
    };
    writeIfChanged(ctxFile(path), JSON.stringify(ctx));
  });
}

// Generates an HTML file in $DESTDIR.
async function genHtmlFile(fullPath: string) {
  const destDir = process.env[destDirVar];
  if (!destDir) throw Error(`$${destDirVar} is not set`);
  const path = eat(fullPath, destDir + "/");
  if (!path) throw Error(`invalid html file path: ${fullPath}`);
  const hlsvc = new HlsvcClient();
  const input = new InputReader();
  const template = new TemplateRenderer();
  const markdown = new MarkdownRenderer(hlsvc, srcPostDir);
  const link = new LinkMaker(path);
  const html = await renderHtml(path, input, { template, markdown, link });
  Bun.write(fullPath, postprocess(html));
  hlsvc.close();
  const deps = [input, template, markdown].flatMap((x) => x.deps());
  Bun.write(depFile(path), `$(${destDirVar})/${path}: ${deps.join(" ")}`);
}

// Tools used to render HTML pages.
interface Tools {
  template: TemplateRenderer;
  markdown: MarkdownRenderer;
  link: LinkMaker;
}

// Renders a page, returning a string of HTML.
async function renderHtml(path: string, input: InputReader, tools: Tools) {
  const analytics = process.env["ANALYTICS"];
  tools.template.define({
    root: path.replaceAll(/[^/]+/g, "..").replace(/\.\.$/, ""),
    analytics: analytics ? Bun.file(analytics).text() : false,
    home_url: process.env["HOME_URL"] ?? false,
    year: new Date().getFullYear().toString(),
  });
  switch (path) {
    case "index.html":
      return renderIndex(await input.posts(), tools);
    case "post/index.html":
      return renderArchive(await input.posts(), tools);
    case "categories/index.html":
      return renderCategories(await input.posts(), tools);
    default:
      return renderPost(await input.post(path), tools);
  }
}

// Renders the blog homepage.
function renderIndex(posts: Post[], { template, markdown }: Tools) {
  const recentPosts = Promise.all(
    posts.slice(0, 10).map(async ({ path, summary, title, date }) => ({
      date: dateFormat(date, "dddd, d mmmm yyyy"),
      href: path,
      title,
      summary: await markdown.render(summary),
    }))
  );
  return template.render("templates/index.html", {
    title: "Mitchell Kember",
    math: recentPosts.then(() => markdown.encounteredMath),
    posts: recentPosts,
  });
}

// Renders the blog post archive.
function renderArchive(posts: Post[], { template, link }: Tools) {
  return template.render("templates/listing.html", {
    title: "Post Archive",
    math: false,
    groups: groupBy(posts, (post) => dateFormat(post.date, "yyyy")).map(
      ([year, posts]) => ({
        name: year,
        pages: posts.map(({ path, title, date }) => ({
          date: dateFormat(date, "d mmm yyyy"),
          href: link.to(path),
          title,
        })),
      })
    ),
  });
}

// Renders the blog post categories page.
function renderCategories(posts: Post[], { template, link }: Tools) {
  return template.render("templates/listing.html", {
    title: "Categories",
    math: false,
    groups: groupBy(posts, (post) => post.category).map(
      ([category, posts]) => ({
        name: category,
        pages: posts.map(({ path, title, date }) => ({
          date: dateFormat(date, "d mmm yyyy"),
          href: link.to(path),
          title,
        })),
      })
    ),
  });
}

// Renders a blog post from its Markdown content.
function renderPost(
  post: PostWithContext,
  { template, markdown, link }: Tools
) {
  const html = markdown.render(post.body);
  return template.render("templates/post.html", {
    title: markdown.renderInline(post.title),
    math: html.then(() => markdown.encounteredMath),
    date: dateFormat(post.date, "dddd, d mmmm yyyy"),
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
    const [markdown, json] = await Promise.all([
      this.read(srcFile(path)),
      this.read(ctxFile(path)),
    ]);
    const post = parsePost(markdown);
    const ctx: Context = JSON.parse(json);
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

// Returns the first paragraph of a post body.
function getSummary(body: string): string {
  const match = body.match(/^\s*(.*)/);
  if (!match) throw Error("post has no summary paragraph");
  return match[1];
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
