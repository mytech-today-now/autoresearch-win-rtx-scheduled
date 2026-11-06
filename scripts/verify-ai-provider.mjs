#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = process.cwd();
const allowedPackage = "ai-powered";
const disallowedPackages = new Set([
  "@anthropic-ai/sdk",
  "anthropic",
  "openai",
  "lumaai",
  "@azure/openai",
  "@google/generative-ai",
]);
const directProviderPackages = Array.from(disallowedPackages);
const directProviderImportPatterns = [
  ...directProviderPackages.flatMap((name) => {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return [
      new RegExp(`\\bimport\\s+(?:[^'"\\n]+\\s+from\\s+)?["']${escaped}["']`),
      new RegExp(`\\bimport\\s*\\(\\s*["']${escaped}["']`),
      new RegExp(`\\bexport\\s+(?:[^'"\\n]+\\s+from\\s+)?["']${escaped}["']`),
      new RegExp(`\\brequire\\s*\\(\\s*["']${escaped}["']`),
    ];
  }),
  /Augment Code AI/i,
];
const pythonProviderLiteralPatterns = directProviderPackages.map((name) => {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // Python comments and string literals should not be able to hide a banned
  // provider name, so treat the raw provider token as suspicious in .py files.
  return /^[A-Za-z0-9_]+$/.test(name)
    ? new RegExp(`\\b${escaped}\\b`, "i")
    : new RegExp(escaped, "i");
});
const providerCredentialPatterns = [
  /\bAI_PROVIDER\s*=/,
  /\bOPENAI_API_KEY\b/,
  /\bANTHROPIC_API_KEY\b/,
  /\bAZURE_OPENAI_API_KEY\b/,
];
const launcherSource = "scripts/launch.ps1";
const launcherCopyPattern = /^scripts\/launch copy(?: \d+)?\.ps1$/i;
const testHarnessPattern = /^(?:tests\/|scripts\/test-)/i;
const excludedDirs = new Set([
  ".git",
  ".augment",
  ".beads",
  ".agents",
  ".venv",
  "ai-prompts",
  "env",
  "node_modules",
  "openspec",
  "venv",
]);
const sourceExtensions = new Set([
  ".ps1",
  ".psm1",
  ".psd1",
  ".mjs",
  ".js",
  ".ts",
  ".py",
  ".json",
  ".toml",
  ".yaml",
  ".yml",
]);

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function dependencyNames(section) {
  return Object.keys(section ?? {});
}

function isLauncherCopy(path) {
  return launcherCopyPattern.test(path);
}

function shouldCheckProviderCredentials(path) {
  // Copied launchers remain governed launcher variants, so they keep the
  // approved launcher-style credential forwarding exemption even though they
  // are still scanned for direct provider usage and other risky literals.
  return path !== launcherSource && !isLauncherCopy(path) && !testHarnessPattern.test(path);
}

function verifyManifest() {
  const manifest = readJson(join(root, "package.json"));
  const direct = [
    ...dependencyNames(manifest.dependencies),
    ...dependencyNames(manifest.optionalDependencies),
    ...dependencyNames(manifest.peerDependencies),
  ];
  if (!direct.includes(allowedPackage)) {
    fail(`package.json must declare ${allowedPackage}`);
  }
  for (const name of direct) {
    if (disallowedPackages.has(name)) {
      fail(`package.json declares disallowed AI package ${name}`);
    }
  }
}

function verifyLockfile() {
  const lockPath = join(root, "package-lock.json");
  if (!existsSync(lockPath)) {
    fail("package-lock.json is missing");
    return;
  }
  const lock = readJson(lockPath);
  const rootPackage = lock.packages?.[""] ?? {};
  const rootDeps = dependencyNames(rootPackage.dependencies);
  if (!rootDeps.includes(allowedPackage)) {
    fail(`package-lock.json root must declare ${allowedPackage}`);
  }
  for (const name of rootDeps) {
    if (disallowedPackages.has(name)) {
      fail(`package-lock.json root declares disallowed AI package ${name}`);
    }
  }
}

function shouldScan(path) {
  const name = path.split(/[\\/]/).pop() ?? "";
  if (name === "verify-ai-provider.mjs") return false;
  if (name === "package-lock.json") return false;
  if (name.startsWith(".env")) return false;
  const dot = name.lastIndexOf(".");
  const ext = dot >= 0 ? name.slice(dot).toLowerCase() : "";
  return sourceExtensions.has(ext);
}

function walk(dir, files = []) {
  for (const entry of readdirSync(dir)) {
    if (excludedDirs.has(entry) || entry.startsWith(".test-tmp-")) continue;
    const path = join(dir, entry);
    const info = statSync(path);
    if (info.isDirectory()) {
      walk(path, files);
    } else if (info.isFile() && shouldScan(path)) {
      files.push(path);
    }
  }
  return files;
}

function verifySourceAndConfig() {
  for (const file of walk(root)) {
    const rel = relative(root, file).replace(/\\/g, "/");
    const text = readFileSync(file, "utf8");
    const lines = text.split(/\r?\n/);
    const checkProviderCredentials = shouldCheckProviderCredentials(rel);
    const isPythonSource = rel.toLowerCase().endsWith(".py");
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      if (directProviderImportPatterns.some((pattern) => pattern.test(line))) {
        fail(`${rel}:${index + 1} contains disallowed direct provider usage`);
        continue;
      }
      if (
        isPythonSource &&
        pythonProviderLiteralPatterns.some((pattern) => pattern.test(line))
      ) {
        fail(`${rel}:${index + 1} contains disallowed direct provider usage`);
        continue;
      }
      if (
        checkProviderCredentials &&
        providerCredentialPatterns.some((pattern) => pattern.test(line))
      ) {
        fail(`${rel}:${index + 1} contains disallowed provider configuration`);
      }
    }
  }
}

verifyManifest();
verifyLockfile();
verifySourceAndConfig();

if (process.exitCode) {
  process.exit(process.exitCode);
}
console.log("Provider verification passed: ai-powered is the only direct AI interface.");
