const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const root = "/usr/local/lib/node_modules/openclaw";
const exts = path.join(root, "dist", "extensions");
const deps = new Map();

for (const d of fs.readdirSync(exts)) {
  const p = path.join(exts, d, "package.json");
  if (!fs.existsSync(p)) continue;
  const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
  const all = { ...pkg.dependencies, ...(pkg.optionalDependencies || {}) };
  for (const [name, version] of Object.entries(all)) {
    const sentinel = path.join(root, "node_modules", ...name.split("/"), "package.json");
    if (!fs.existsSync(sentinel)) deps.set(name, `${name}@${version}`);
  }
}

if (deps.size === 0) {
  console.log("[install-deps] All bundled plugin deps present");
  process.exit(0);
}

const specs = [...deps.values()];
console.log(`[install-deps] Installing ${specs.length} missing deps...`);
try {
  execSync(
    `npm install --omit=dev --no-save --package-lock=false ${specs.join(" ")}`,
    { stdio: "inherit", cwd: root }
  );
  console.log("[install-deps] Done");
} catch (e) {
  console.error("[install-deps] Some deps failed, continuing anyway");
}
