#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path, { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const localScriptExtensions = new Set([".cjs", ".js", ".mjs", ".ps1", ".py", ".sh"]);
const reviewedHelperPaths = [
  "scripts/verify-ai-provider.mjs",
  "scripts/test-autoresearch-wrapper.ps1",
  "scripts/test-autoresearch-acceptance.ps1",
];

function gitRootAvailable() {
  const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  if (result.status === 0) return true;
  if (result.error?.code === "ENOENT") return false;
  if ((result.stderr ?? "").includes("not a git repository")) return false;
  throw new Error((result.stderr || result.error?.message || "git probe failed").trim());
}

function createGitArchiveSnapshot() {
  const tree = execFileSync("git", ["write-tree"], {
    cwd: repoRoot,
    encoding: "utf8",
  }).trim();
  const temporaryRoot = mkdtempSync(join(tmpdir(), "autoresearch-clean-archive-"));
  const archivePath = join(temporaryRoot, "source.tar");
  const archiveRoot = join(temporaryRoot, "source");
  const emptyGlobalConfig = join(temporaryRoot, "empty.gitconfig");
  const emptyTemplate = join(temporaryRoot, "empty-template");

  try {
    mkdirSync(archiveRoot);
    mkdirSync(emptyTemplate);
    writeFileSync(emptyGlobalConfig, "", "utf8");
    execFileSync("git", ["archive", "--format=tar", `--output=${archivePath}`, tree], {
      cwd: repoRoot,
      stdio: "pipe",
    });
    const listing = execFileSync("tar", ["-tf", archivePath], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    execFileSync("tar", ["-xf", archivePath, "-C", archiveRoot], {
      cwd: repoRoot,
      stdio: "pipe",
    });
    const files = new Set(
      listing
        .split(/\r?\n/)
        .filter(Boolean)
        .map((entry) => entry.replace(/\\/g, "/").replace(/^\.\//, "").replace(/\/$/, "")),
    );
    const isolatedGitEnvironment = {
      ...process.env,
      GIT_CONFIG_GLOBAL: emptyGlobalConfig,
      GIT_CONFIG_NOSYSTEM: "1",
    };
    for (const key of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"]) {
      delete isolatedGitEnvironment[key];
    }
    execFileSync("git", ["init", "--quiet", `--template=${emptyTemplate}`, archiveRoot], {
      cwd: temporaryRoot,
      env: isolatedGitEnvironment,
      stdio: "pipe",
    });
    for (const helperPath of reviewedHelperPaths) {
      const result = spawnSync(
        "git",
        ["-C", archiveRoot, "check-ignore", "--no-index", "--quiet", "--", helperPath],
        { cwd: temporaryRoot, env: isolatedGitEnvironment, encoding: "utf8" },
      );
      if (result.status === 0) throw new Error(`${helperPath} is ignored by the clean archive's .gitignore.`);
      if (result.status !== 1) {
        throw new Error((result.stderr || result.error?.message || `git check-ignore exited ${result.status}`).trim());
      }
    }

    return {
      description: `Git archive tree ${tree.slice(0, 12)}`,
      files,
      has: (filePath) => files.has(filePath),
      read: (filePath) => readFileSync(join(archiveRoot, filePath), "utf8"),
      cleanup: () => rmSync(temporaryRoot, { recursive: true, force: true }),
    };
  } catch (error) {
    rmSync(temporaryRoot, { recursive: true, force: true });
    throw error;
  }
}

function createArchiveDirectorySnapshot() {
  const workflowDirectory = join(repoRoot, ".github", "workflows");
  const workflows = existsSync(workflowDirectory)
    ? readdirSync(workflowDirectory, { withFileTypes: true })
        .filter((entry) => entry.isFile() && /\.ya?ml$/i.test(entry.name))
        .map((entry) => `.github/workflows/${entry.name}`)
    : [];

  return {
    description: "clean archive directory without Git metadata",
    workflows,
    has: (filePath) => existsSync(join(repoRoot, filePath)),
    read: (filePath) => readFileSync(join(repoRoot, filePath), "utf8"),
    cleanup: () => {},
  };
}

function normalizeScriptPath(value, source) {
  const normalized = path.posix.normalize(value.trim().replace(/\\/g, "/").replace(/^\.\//, ""));
  if (
    !normalized ||
    normalized === "." ||
    normalized === ".." ||
    normalized.startsWith("../") ||
    normalized.startsWith("/") ||
    /^[A-Za-z]:/.test(normalized)
  ) {
    throw new Error(`${source} contains a non-repository script path: ${value}`);
  }
  return normalized;
}

function extractInvocations(command) {
  const npmScripts = [];
  const localScripts = [];
  const npmPattern = /\bnpm(?:\.cmd)?\s+(?:run\s+([A-Za-z0-9:_-]+)|test)(?=\s|$|[;&|])/gi;
  const nodePattern =
    /\bnode(?:\.exe)?\s+(?:"([^"\r\n]+\.(?:cjs|js|mjs))"|'([^'\r\n]+\.(?:cjs|js|mjs))'|([^\s"';&|]+\.(?:cjs|js|mjs)))/gi;
  const powershellPattern =
    /\b(?:powershell|pwsh)(?:\.exe)?\b[^\r\n]*?\s+-File\s+(?:"([^"\r\n]+\.ps1)"|'([^'\r\n]+\.ps1)'|([^\s"';&|]+\.ps1))/gi;
  const pythonPattern =
    /\b(?:python(?:3(?:\.\d+)?)?|bash|sh)(?:\.exe)?\s+(?:"([^"\r\n]+\.(?:py|sh))"|'([^'\r\n]+\.(?:py|sh))'|([^\s"';&|]+\.(?:py|sh)))/gi;

  for (const match of command.matchAll(npmPattern)) {
    npmScripts.push(match[1] ?? "test");
  }
  for (const pattern of [nodePattern, powershellPattern, pythonPattern]) {
    for (const match of command.matchAll(pattern)) {
      localScripts.push(match[1] ?? match[2] ?? match[3]);
    }
  }
  return { npmScripts, localScripts };
}

function verifyScriptReferences(snapshot) {
  if (!snapshot.has("package.json")) throw new Error("package.json is missing from the clean archive.");
  const manifest = JSON.parse(snapshot.read("package.json"));
  const scripts = manifest.scripts;
  if (!scripts || typeof scripts !== "object") throw new Error("package.json has no scripts object.");

  const targets = new Map();
  const recordTarget = (value, source) => {
    const target = normalizeScriptPath(value, source);
    const extension = path.posix.extname(target).toLowerCase();
    if (!localScriptExtensions.has(extension)) {
      throw new Error(`${source} targets an unsupported script file: ${target}`);
    }
    if (!targets.has(target)) targets.set(target, new Set());
    targets.get(target).add(source);
  };

  function visitPackageScript(name, stack = []) {
    if (!Object.hasOwn(scripts, name)) throw new Error(`npm run references missing package script '${name}'.`);
    if (stack.includes(name)) throw new Error(`package.json has a script cycle: ${[...stack, name].join(" -> ")}.`);
    const command = scripts[name];
    if (typeof command !== "string") throw new Error(`package.json script '${name}' is not a string.`);
    const source = `package.json scripts.${name}`;
    const invocations = extractInvocations(command);
    for (const target of invocations.localScripts) recordTarget(target, source);
    for (const nestedName of invocations.npmScripts) {
      visitPackageScript(nestedName, [...stack, name]);
    }
  }

  for (const name of Object.keys(scripts)) visitPackageScript(name);

  const workflowPaths = snapshot.workflows ?? [...snapshot.files].filter((filePath) =>
    /^\.github\/workflows\/[^/]+\.ya?ml$/i.test(filePath),
  );
  if (workflowPaths.length === 0) throw new Error("No GitHub Actions workflow files exist in the clean archive.");
  for (const workflowPath of workflowPaths) {
    if (!snapshot.has(workflowPath)) throw new Error(`${workflowPath} is missing from the clean archive.`);
    const invocations = extractInvocations(snapshot.read(workflowPath));
    for (const target of invocations.localScripts) recordTarget(target, workflowPath);
    for (const name of invocations.npmScripts) visitPackageScript(name);
  }

  for (const [target, sources] of targets) {
    if (!snapshot.has(target)) {
      throw new Error(`${target} is referenced by ${[...sources].join(", ")} but is missing from the clean archive.`);
    }
  }

  console.log(
    `Clean archive script-reference check passed: ${targets.size} local script target(s) resolved across package scripts and ${workflowPaths.length} workflow file(s) (${snapshot.description}).`,
  );
}

function main() {
  let snapshot;
  try {
    snapshot = gitRootAvailable() ? createGitArchiveSnapshot() : createArchiveDirectorySnapshot();
    verifyScriptReferences(snapshot);
  } catch (error) {
    console.error(`Clean archive script-reference check failed: ${error.message}`);
    process.exitCode = 1;
  } finally {
    snapshot?.cleanup();
  }
}

main();
