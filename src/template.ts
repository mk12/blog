// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import { dirname, join } from "path";

// A context provides values for variables in a template.
type Context = Record<string, Value | Promise<Value>>;
type ResolvedContext = Record<string, Value>;
type Value = string | boolean | Value[] | NestedContext;

// eslint-disable-next-line @typescript-eslint/no-empty-interface
interface NestedContext extends Record<string, Value> {}

// A compiled template.
type Template = { defs: Definition[]; cmds: Command[] };
type Definition = { variable: string; body: Template };
type Command =
  | { kind: "text"; text: string }
  | { kind: "include"; template?: Template }
  | { kind: "var"; src: string; variable: string }
  | {
      kind: "if";
      src: string;
      variable: string;
      body: Template;
      else?: Template;
    }
  | { kind: "range"; src: string; variable: string; body: Template };

// Renders templates using syntax similar to Go templates.
export class TemplateRenderer {
  private cache: Map<string, Template> = new Map();
  private defaults: Context = {};

  // Defines variables to use by default when rendering templates.
  define(context: Context): void {
    Object.assign(this.defaults, context);
  }

  // Renders a template with the given context variables.
  async render(path: string, context: Context): Promise<string> {
    context = { ...this.defaults, ...context };
    const [template, values] = await Promise.all([
      this.get(path),
      Promise.all(Object.values(context)),
    ]);
    const ctx = Object.fromEntries(
      Object.keys(context).map((key, i) => [key, values[i]])
    );
    const out = { str: "" };
    execute(template, ctx, out);
    return out.str;
  }

  deps(): string[] {
    return Array.from(this.cache.keys());
  }

  private async get(path: string): Promise<Template> {
    let template = this.cache.get(path);
    if (template === undefined) {
      let deps;
      [template, deps] = compile(path, await Bun.file(path).text());
      this.cache.set(path, template);
      const dir = dirname(path);
      const programs = await Promise.all(
        Object.keys(deps).map((relPath) => this.get(join(dir, relPath)))
      );
      const lists = Object.values(deps);
      programs.forEach((program, i) => {
        for (const include of lists[i]) {
          include.template = program;
        }
      });
    }
    return template;
  }
}

// Mapping from template paths to "include" commands to fix up.
type Deps = Record<string, { template?: Template }[]>;

// Compiles a template to a program and dependences.
function compile(name: string, source: string): [Template, Deps] {
  let offset = 0;
  const matches = source.matchAll(/(\s*)\{\{(.*?)\}\}/g);
  const deps: Deps = {};
  type Ending = "end" | "else" | "eof";
  let endedWithElse = false;
  const go = (allow: { [k in Ending]?: boolean }): Template => {
    const template: Template = { defs: [], cmds: [] };
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
      template.cmds.push(textCmd);
      const words = inBraces.trim().split(/\s+/);
      if (words.length < 1) throw err("expected command");
      if (words.length > 2) throw err("too many words");
      const [kind, variable] = words;
      if (kind === "include") {
        const match = variable.match(/^"(.*)"$/);
        if (!match) throw err("invalid include path");
        const path = match[1];
        const cmd: Command = { kind };
        template.cmds.push(cmd);
        (deps[path] ??= []).push(cmd);
      } else if (kind === "if" || kind === "range" || kind === "define") {
        if (variable === undefined) throw err("expected variable");
        const body = go({ end: true, else: kind === "if" });
        const elseBody = endedWithElse ? go({ end: true }) : undefined;
        if (kind === "define") {
          template.defs.push({ variable, body: body });
        } else {
          template.cmds.push({ kind, src, variable, body, else: elseBody });
        }
      } else if (kind === "else" || kind === "end") {
        if (!allow[kind]) throw err(`unexpected command`);
        endedWithElse = kind === "else";
        return template;
      } else {
        if (variable !== undefined) throw err("too many words");
        textCmd.text += whitespace;
        template.cmds.push({ kind: "var", src, variable: kind });
      }
    }
    if (!allow.eof) throw Error(`${name}: unexpected EOF`);
    template.cmds.push({ kind: "text", text: source.slice(offset).trimEnd() });
    return template;
  };
  return [go({ eof: true }), deps];
}

// Template output container.
type Output = { str: string };

// Executes a compiled template with a context.
function execute(prog: Template, ctx: ResolvedContext, out: Output): void {
  const enter = (value: Value) =>
    Object.assign(Object.create(ctx), value, { ".": value });
  for (const def of prog.defs) {
    const out = { str: "" };
    execute(def.body, ctx, out);
    ctx[def.variable] = out.str;
  }
  for (const cmd of prog.cmds) {
    if (cmd.kind === "text") {
      out.str += cmd.text;
    } else if (cmd.kind === "include") {
      if (!cmd.template) throw Error("include did not get compiled properly");
      execute(cmd.template, ctx, out);
    } else {
      const err = (msg: string) => Error(`${cmd.src}: ${msg}`);
      const value = ctx[cmd.variable];
      if (value === undefined) throw err(`"${cmd.variable}" is not defined`);
      if (cmd.kind === "var") {
        out.str += value;
      } else if (cmd.kind === "if") {
        if (value) {
          execute(cmd.body, enter(value), out);
        } else if (cmd.else !== undefined) {
          execute(cmd.else, enter(value), out);
        }
      } else if (cmd.kind === "range") {
        if (!Array.isArray(value)) {
          throw err(`range: "${cmd.variable}" is not an array`);
        }
        for (const item of value) {
          execute(cmd.body, enter(item), out);
        }
      }
    }
  }
}

// Converts a character offset to 1-based line and column numbers.
function getLineAndColumn(source: string, offset: number): [number, number] {
  const matches = Array.from(source.slice(0, offset).matchAll(/\n/g));
  const line = matches.length + 1;
  const last = matches[matches.length - 1]?.index;
  const col = last !== undefined ? offset - last : offset + 1;
  return [line, col];
}
