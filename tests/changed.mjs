// Prints the checks a change can affect, space-separated, or "all": files changed in the working tree (and
// untracked ones) against a base, default HEAD. Each file's reason goes to stderr. See tests/affected.mjs.
//   node tests/changed.mjs [base]
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { areas, needs } from "./affected.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const base = process.argv[2] ?? "HEAD";
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" });
const lines = (text) => text.split("\n").filter(Boolean);

const files = [...new Set([
  ...lines(git("diff", "--name-only", base)),
  ...lines(git("ls-files", "--others", "--exclude-standard")),
])];

const checkNames = (() => {
  const text = readFileSync(join(root, "tests/checks.mjs"), "utf8");
  return [...text.matchAll(/^  async "?([a-z0-9-]+)"?\(\) \{/gm)].map((m) => m[1]);
})();

// Every name in the map must be a real check, so a typo can't quietly drop one.
for (const [key, value] of Object.entries(areas)) {
  if (value === "all") continue;
  const unknown = value.filter((name) => !checkNames.includes(name));
  if (unknown.length) {
    console.error(`tests/affected.mjs: ${key} names unknown checks: ${unknown.join(", ")}`);
    process.exit(2);
  }
}

/** Line numbers (1-based, in the current file) that the diff touches; every line for a new file. */
function changedLines(file) {
  const path = join(root, file);
  if (!existsSync(path)) return null;
  const tracked = lines(git("ls-files", "--", file)).length > 0;
  const count = readFileSync(path, "utf8").split("\n").length;
  if (!tracked) return Array.from({ length: count }, (_, i) => i + 1);
  const out = [];
  for (const [, start, length] of git("diff", "-U0", base, "--", file).matchAll(/^@@ -\S+ \+(\d+)(?:,(\d+))? @@/gm)) {
    const from = Number(start), n = length === undefined ? 1 : Number(length);
    if (n === 0) out.push(Math.max(1, from)); // a deletion: the line it was removed after
    for (let i = 0; i < n; i++) out.push(from + i);
  }
  return out;
}

/** The entry for a whole file: the exact path, else the longest folder prefix. */
function fileEntry(file) {
  if (file in areas) return areas[file];
  const folder = Object.keys(areas).filter((k) => k.endsWith("/") && file.startsWith(k)).sort((a, b) => b.length - a.length)[0];
  return folder ? areas[folder] : undefined;
}

const selected = new Set();
let all = false;
const add = (file, why, value) => {
  console.error(`  ${why} -> ${value === "all" ? "all" : value.length ? [...new Set(value)].join(" ") : "(unit tests only)"}`);
  if (value === "all") all = true;
  else value.forEach((name) => selected.add(name));
};

for (const file of files) {
  if (file === "tests/checks.mjs") {
    // The checks whose bodies changed; anything outside a check (helpers, the runner) can affect them all.
    const text = readFileSync(join(root, file), "utf8").split("\n");
    const starts = text.map((l, i) => [l.match(/^  async "?([a-z0-9-]+)"?\(\) \{/)?.[1], i + 1]).filter(([n]) => n);
    const end = text.findIndex((l, i) => i + 1 > (starts.at(-1)?.[1] ?? 0) && l === "};") + 1;
    const names = new Set();
    let shared = false;
    for (const line of changedLines(file) ?? []) {
      const owner = starts.filter(([, at]) => at <= line).at(-1);
      if (!owner || line > end) shared = true;
      else names.add(owner[0]);
    }
    add(file, shared ? `${file} (shared code)` : file, shared ? "all" : [...names]);
    continue;
  }
  const sections = Object.keys(areas).filter((k) => k.startsWith(`${file}#`));
  const changed = sections.length ? changedLines(file) : null;
  if (!changed) {
    const entry = fileEntry(file);
    add(file, entry === undefined ? `${file} (not in tests/affected.mjs)` : file, entry ?? "all");
    continue;
  }
  const text = readFileSync(join(root, file), "utf8").split("\n");
  // A section runs from its mark to the next mark or the next top-level declaration (a class after it isn't in it).
  const topLevel = /^(?:(?:private|fileprivate|public|final|@objc)\s+)*(?:class|struct|enum|extension|protocol|func)\s/;
  const marks = text.map((l, i) => [topLevel.test(l) ? null : l.match(/\/\/ MARK: (.+)$/)?.[1]?.trim(), i + 1, topLevel.test(l)])
    .filter(([m, , decl]) => m || decl);
  const seen = new Set();
  for (const line of changed) {
    const section = marks.filter(([, at]) => at <= line).at(-1)?.[0];
    const key = section ? `${file}#${section}` : `${file} (outside its MARK sections)`;
    if (seen.has(key)) continue;
    seen.add(key);
    add(file, key, areas[key] ?? fileEntry(file) ?? "all");
  }
}

for (const name of [...selected]) for (const setup of needs[name] ?? []) selected.add(setup);
console.log(all ? "all" : [...selected].join(" "));
