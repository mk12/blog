// Copyright 2023 Mitchell Kember. Subject to the MIT License.

import { mkdir } from "fs/promises";
import { dirname } from "path";

// If s starts with prefix, removes it and returns the result.
export function eat(s: string, prefix: string): string | undefined {
  return s.startsWith(prefix) ? s.slice(prefix.length) : undefined;
}

// Changes the extension of a path.
export function changeExt(path: string, ext: string): string {
  return removeExt(path) + ext;
}

// Removes the extension from a path.
export function removeExt(path: string): string {
  return path.slice(0, path.lastIndexOf("."));
}

// Writes to a file if the new content is different.
export async function writeIfChanged(
  path: string,
  content: string
): Promise<void> {
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
export function groupBy<T, U>(array: T[], key: (item: T) => U): [U, T[]][] {
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
