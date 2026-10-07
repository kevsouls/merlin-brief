// Cloudflare Pages direct upload for project merlin-brief.
//
//   node tools/pages-deploy.mjs upload
//     Hashes every file in dist/, uploads missing assets, and writes
//     .publish/manifest.json plus .publish/mcp-create-deployment.js.
//     Auth: CF_PAGES_UPLOAD_JWT (from the Cloudflare MCP, see PUBLISH.md),
//     or CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID (token fetches the JWT).
//
//   node tools/pages-deploy.mjs create
//     Creates the production deployment directly. Needs CLOUDFLARE_API_TOKEN
//     and CLOUDFLARE_ACCOUNT_ID. Without them, run the generated
//     .publish/mcp-create-deployment.js through the Cloudflare MCP execute tool.
//
// Behavior kept identical to the deploys made before this repo existed:
// _redirects is sent as the deployment's redirects file, and every other file
// in dist/ (including _headers) is uploaded as a static asset.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { blake3 } from "@noble/hashes/blake3.js";

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIST = path.join(ROOT_DIR, "dist");
const OUT = path.join(ROOT_DIR, ".publish");
const PROJECT = process.env.PAGES_PROJECT || "merlin-brief";
const BRANCH = process.env.PAGES_BRANCH || "main";
const API = "https://api.cloudflare.com/client/v4";

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".xml": "application/xml; charset=utf-8",
};

function walk(dir, out = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

function hashFile(full) {
  const b64 = fs.readFileSync(full).toString("base64");
  const ext = path.extname(full).substring(1);
  return Buffer.from(blake3(new TextEncoder().encode(b64 + ext))).toString("hex").slice(0, 32);
}

function contentType(rel) {
  if (rel === "_headers" || rel === "robots.txt") return "text/plain; charset=utf-8";
  return CONTENT_TYPES[path.extname(rel).toLowerCase()] || "application/octet-stream";
}

async function api(pathname, { method = "GET", body, token, form } = {}) {
  const headers = { Authorization: `Bearer ${token}` };
  let payload;
  if (form) payload = form;
  else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${API}${pathname}`, { method, headers, body: payload });
  const data = await res.json();
  if (!res.ok || data.success === false) {
    throw new Error(`${method} ${pathname} -> ${res.status} ${JSON.stringify(data.errors || data)}`);
  }
  return data;
}

function git(...args) {
  return execFileSync("git", args, { cwd: ROOT_DIR, encoding: "utf8" }).trim();
}

function collect() {
  const files = walk(DIST).filter((f) => {
    const base = path.basename(f);
    return !base.startsWith(".") && base !== "_redirects";
  });
  return files.map((full) => {
    const rel = path.relative(DIST, full).split(path.sep).join("/");
    const buf = fs.readFileSync(full);
    return { path: rel, hash: hashFile(full), contentType: contentType(rel), base64: buf.toString("base64"), size: buf.length };
  });
}

async function getJwt() {
  if (process.env.CF_PAGES_UPLOAD_JWT) return process.env.CF_PAGES_UPLOAD_JWT;
  const { CLOUDFLARE_API_TOKEN: t, CLOUDFLARE_ACCOUNT_ID: a } = process.env;
  if (t && a) {
    const r = await api(`/accounts/${a}/pages/projects/${PROJECT}/upload-token`, { token: t });
    return r.result.jwt;
  }
  throw new Error("No upload auth. Set CF_PAGES_UPLOAD_JWT (via Cloudflare MCP, see PUBLISH.md) or CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID.");
}

function deploymentFields() {
  const head = git("rev-parse", "HEAD");
  const msg = git("log", "-1", "--format=%s");
  const redirectsPath = path.join(DIST, "_redirects");
  const redirects = fs.existsSync(redirectsPath) ? fs.readFileSync(redirectsPath, "utf8") : null;
  const manifest = JSON.parse(fs.readFileSync(path.join(OUT, "manifest.json"), "utf8"));
  return { head, msg, redirects, manifest };
}

async function upload() {
  const jwt = await getJwt();
  const files = collect();
  const hashes = files.map((f) => f.hash);
  const missing = new Set((await api("/pages/assets/check-missing", { method: "POST", body: { hashes }, token: jwt })).result || []);
  const toUpload = files.filter((f) => missing.has(f.hash));
  for (let i = 0; i < toUpload.length; i += 40) {
    const batch = toUpload.slice(i, i + 40).map((f) => ({ key: f.hash, value: f.base64, metadata: { contentType: f.contentType }, base64: true }));
    await api("/pages/assets/upload", { method: "POST", body: batch, token: jwt });
  }
  await api("/pages/assets/upsert-hashes", { method: "POST", body: { hashes }, token: jwt });
  console.log(`assets: ${files.length} total, ${toUpload.length} uploaded`);

  fs.mkdirSync(OUT, { recursive: true });
  const manifest = {};
  for (const f of files) manifest[`/${f.path}`] = f.hash;
  fs.writeFileSync(path.join(OUT, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

  const { head, msg, redirects } = deploymentFields();
  const code = `async () => {
  const fields = {
    manifest: ${JSON.stringify(JSON.stringify(manifest))},
    branch: ${JSON.stringify(BRANCH)},
    commit_hash: ${JSON.stringify(head)},
    commit_message: ${JSON.stringify(msg)},
    commit_dirty: "false",
  };
  const redirects = ${JSON.stringify(redirects)};
  const b = "----merlinbrief" + Date.now();
  let body = "";
  for (const [k, v] of Object.entries(fields)) {
    body += "--" + b + "\\r\\nContent-Disposition: form-data; name=\\"" + k + "\\"\\r\\n\\r\\n" + v + "\\r\\n";
  }
  if (redirects !== null) {
    body += "--" + b + "\\r\\nContent-Disposition: form-data; name=\\"_redirects\\"; filename=\\"_redirects\\"\\r\\nContent-Type: text/plain\\r\\n\\r\\n" + redirects + "\\r\\n";
  }
  body += "--" + b + "--\\r\\n";
  const r = await cloudflare.request({
    method: "POST",
    path: "/accounts/" + accountId + "/pages/projects/${PROJECT}/deployments",
    body,
    contentType: "multipart/form-data; boundary=" + b,
    rawBody: true,
  });
  const d = r.result || {};
  return {
    success: r.success,
    errors: r.errors,
    id: d.id,
    url: d.url,
    environment: d.environment,
    stage: d.latest_stage,
    commit_hash: d.deployment_trigger && d.deployment_trigger.metadata && d.deployment_trigger.metadata.commit_hash,
  };
}
`;
  fs.writeFileSync(path.join(OUT, "mcp-create-deployment.js"), code);
  console.log(`wrote ${path.join(OUT, "manifest.json")} and ${path.join(OUT, "mcp-create-deployment.js")} (commit ${head})`);
}

async function create() {
  const { CLOUDFLARE_API_TOKEN: t, CLOUDFLARE_ACCOUNT_ID: a } = process.env;
  if (!t || !a) throw new Error("create needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID; otherwise run .publish/mcp-create-deployment.js via the Cloudflare MCP.");
  const { head, msg, redirects, manifest } = deploymentFields();
  const form = new FormData();
  form.set("manifest", JSON.stringify(manifest));
  form.set("branch", BRANCH);
  form.set("commit_hash", head);
  form.set("commit_message", msg);
  form.set("commit_dirty", "false");
  if (redirects !== null) form.set("_redirects", new Blob([redirects], { type: "text/plain" }), "_redirects");
  const r = await api(`/accounts/${a}/pages/projects/${PROJECT}/deployments`, { method: "POST", form, token: t });
  const d = r.result;
  const out = { id: d.id, url: d.url, environment: d.environment, stage: d.latest_stage, commit_hash: d.deployment_trigger?.metadata?.commit_hash };
  fs.writeFileSync(path.join(OUT, "deployment.json"), JSON.stringify(out, null, 2) + "\n");
  console.log(JSON.stringify(out, null, 2));
}

const cmd = process.argv[2];
try {
  if (cmd === "upload") await upload();
  else if (cmd === "create") await create();
  else {
    console.error("usage: node tools/pages-deploy.mjs upload|create");
    process.exit(2);
  }
} catch (e) {
  console.error(String(e.message || e));
  process.exit(1);
}
