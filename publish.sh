#!/usr/bin/env bash
# Merlin Brief: the one publish path. GitHub main first, then Cloudflare Pages
# production (branch main) from the same tree, then verification.
#
#   ./publish.sh all "commit message"   commit, push, deploy, verify
#   ./publish.sh check                  guardrails only
#   ./publish.sh commit "message"       guardrails, then commit any changes
#   ./publish.sh push                   push HEAD to GitHub main
#   ./publish.sh adopt                  after a connector push: make local HEAD = GitHub HEAD
#   ./publish.sh deploy                 upload dist/ and create the production deployment
#   ./publish.sh verify [commit_sha]    live site == dist/, GitHub HEAD == local HEAD
#
# Exit codes: 0 done, 1 error, 20 push must go through the GitHub connector,
# 30 deployment must be created through the Cloudflare MCP. See PUBLISH.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
PUB="$ROOT/.publish"
mkdir -p "$PUB"
HOSTS=(merlin-brief.pages.dev merlinbrief.com)
BRANCH=main
# The only file allowed to be deployed from dist/ without being in git.
ALLOWED_UNTRACKED_DIST="dist/og.jpg"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

remote_slug() {
  git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##'
}

remote_head() {
  git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}'
}

cmd_check() {
  local fail=0
  # 1. No personal names in anything published or committed. The word list
  #    lives outside the repo (.git/info/forbidden-words, one word per line)
  #    so the list itself is never published.
  local words="$ROOT/.git/info/forbidden-words"
  [ -s "$words" ] || die "missing $words (one forbidden word per line)"
  local hits
  hits=$( { git ls-files -co --exclude-standard; find dist -type f; } | sort -u | grep -v -x -F "$ALLOWED_UNTRACKED_DIST" \
      | xargs -r grep -l -i -F -f "$words" 2>/dev/null || true)
  if [ -n "$hits" ]; then say "check: forbidden personal name found in:"; say "$hits"; fail=1; fi
  if git log -1 --format=%B HEAD 2>/dev/null | grep -q -i -F -f "$words"; then
    say "check: forbidden personal name in the last commit message"; fail=1
  fi
  # 2. No PDFs or images except the site's own favicon and social card.
  local media
  media=$(find . -path ./.git -prune -o -path ./node_modules -prune -o -type f \
      \( -iname '*.pdf' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.heic' \) -print \
      | sed 's#^\./##' | grep -v -x -F "$ALLOWED_UNTRACKED_DIST" || true)
  if [ -n "$media" ]; then say "check: PDFs or images not allowed:"; say "$media"; fail=1; fi
  if find sources -type f ! -name '*.md' 2>/dev/null | grep -q .; then
    say "check: sources/ may only hold .md text extracts"; fail=1
  fi
  # 3. No secrets, caches, or dependencies tracked.
  if git ls-files -co --exclude-standard | grep -E '(^|/)(node_modules|\.wrangler|\.publish)/|(^|/)\.env' ; then
    say "check: caches, dependencies, or env files would be committed"; fail=1
  fi
  if git ls-files -co --exclude-standard | grep -v -x 'publish.sh' | xargs -r grep -l -E 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY|CLOUDFLARE_API_TOKEN=[^ ]' 2>/dev/null; then
    say "check: possible secret in the files above"; fail=1
  fi
  # 4. Everything under dist/ is either tracked or the one allowed binary.
  local stray
  stray=$(git ls-files -o -i --exclude-standard -- dist | grep -v -x -F "$ALLOWED_UNTRACKED_DIST" || true)
  [ -z "$stray" ] || { say "check: gitignored files in dist/ would deploy but not reach GitHub:"; say "$stray"; fail=1; }
  [ -f dist/index.html ] || { say "check: dist/index.html missing"; fail=1; }
  [ "$fail" = 0 ] || die "guardrails failed"
  say "check: ok"
}

cmd_commit() {
  local msg="${1:-}"
  cmd_check
  git add -A
  if git diff --cached --quiet; then
    say "commit: nothing to commit, HEAD $(git rev-parse --short HEAD)"
  else
    [ -n "$msg" ] || die "commit message required: ./publish.sh commit \"message\""
    if printf '%s' "$msg" | grep -q -i -F -f "$ROOT/.git/info/forbidden-words"; then git reset -q; die "commit message contains a forbidden personal name"; fi
    git commit -q -m "$msg"
    say "commit: $(git rev-parse HEAD)"
  fi
}

write_connector_push() {
  local slug owner repo msg
  slug=$(remote_slug); owner=${slug%%/*}; repo=${slug#*/}
  msg=$(git log -1 --format=%B HEAD)
  git fetch -q origin "$BRANCH"
  git merge-base --is-ancestor "origin/$BRANCH" HEAD || die "GitHub $BRANCH has commits that are not in local HEAD. Run: git fetch origin && git rebase origin/$BRANCH"
  node --input-type=module - "$ROOT" "$owner" "$repo" "$BRANCH" "$msg" <<'NODE' > "$PUB/connector-push.json"
import { execFileSync } from "node:child_process";
const [root, owner, repo, branch, message] = process.argv.slice(2);
const out = execFileSync("git", ["diff", "--name-status", "--no-renames", `origin/${branch}`, "HEAD"], { cwd: root, encoding: "utf8" });
const files = [], deletes = [];
for (const line of out.split("\n").filter(Boolean)) {
  const [status, p] = line.split("\t");
  if (status === "D") deletes.push(p);
  else files.push({ path: p, content: `$file:${root}/${p}` });
}
// The connector expands at most 4 $file: references per call, so split.
const chunks = [];
for (let i = 0; i < files.length; i += 4) chunks.push(files.slice(i, i + 4));
const n = chunks.length;
const calls = chunks.map((c, i) => ({ owner, repo, branch, message: n === 1 ? message.trim() : `${message.trim()} (part ${i + 1} of ${n})`, files: c }));
console.log(JSON.stringify({ push_files_calls: calls, delete_file: deletes.map((p) => ({ owner, repo, branch, path: p, message: `Remove ${p}` })) }, null, 2));
NODE
}

cmd_push() {
  local local_head; local_head=$(git rev-parse HEAD)
  if [ "$(remote_head)" = "$local_head" ]; then say "push: GitHub $BRANCH already at $local_head"; return 0; fi
  if GIT_TERMINAL_PROMPT=0 git push -q origin "HEAD:$BRANCH" 2>"$PUB/push.err"; then
    say "push: pushed $local_head to GitHub $BRANCH"
    return 0
  fi
  say "push: git has no GitHub credentials on this machine ($(head -1 "$PUB/push.err"))"
  write_connector_push
  say "push: wrote $PUB/connector-push.json"
  say "NEXT: call the GitHub connector push_files once per entry in 'push_files_calls', one at a"
  say "      time and in order (never in parallel). Pass each object unchanged; every content value"
  say "      is a \$file: reference. Then delete_file for any 'delete_file' entries, then run:"
  say "      ./publish.sh adopt && ./publish.sh deploy"
  exit 20
}

cmd_adopt() {
  git fetch -q origin "$BRANCH"
  local rt lt
  rt=$(git rev-parse "origin/$BRANCH^{tree}"); lt=$(git rev-parse "HEAD^{tree}")
  if [ "$rt" != "$lt" ]; then
    git diff --stat HEAD "origin/$BRANCH" >&2 || true
    die "GitHub tree $rt differs from local tree $lt; the connector push is incomplete"
  fi
  git reset -q --soft "origin/$BRANCH"
  say "adopt: local HEAD = GitHub HEAD = $(git rev-parse HEAD) (tree $lt)"
}

require_synced() {
  [ -z "$(git status --porcelain)" ] || { git status --short >&2; die "working tree not clean; run ./publish.sh commit first"; }
  local rh lh; rh=$(remote_head); lh=$(git rev-parse HEAD)
  [ "$rh" = "$lh" ] || die "GitHub $BRANCH ($rh) != local HEAD ($lh). Push (and adopt) before deploying."
}

cmd_deploy() {
  cmd_check
  require_synced
  [ -d node_modules/@noble/hashes ] || npm ci --silent
  if [ -z "${CF_PAGES_UPLOAD_JWT:-}" ] && { [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; }; then
    say "deploy: no Cloudflare auth in the environment"
    say "NEXT: run tools/mcp-get-upload-token.js through the Cloudflare MCP execute tool, then:"
    say "      CF_PAGES_UPLOAD_JWT='<jwt>' ./publish.sh deploy"
    exit 30
  fi
  node tools/pages-deploy.mjs upload
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    node tools/pages-deploy.mjs create
    cmd_verify "$(git rev-parse HEAD)"
  else
    say "NEXT: run the Cloudflare MCP execute tool with code \"\$file:$PUB/mcp-create-deployment.js\""
    say "      then: ./publish.sh verify <commit_hash returned by that call>"
    exit 30
  fi
}

sha() { sha256sum | cut -c1-64; }

cmd_verify() {
  local deployed_commit="${1:-}" fail=0 lh rh
  lh=$(git rev-parse HEAD); rh=$(remote_head)
  [ -z "$(git status --porcelain)" ] || { say "verify: working tree not clean"; fail=1; }
  if [ "$rh" = "$lh" ]; then say "verify: GitHub $BRANCH == local HEAD == $lh"; else say "verify: MISMATCH GitHub $BRANCH $rh vs local $lh"; fail=1; fi
  if [ -n "$deployed_commit" ]; then
    if [ "$deployed_commit" = "$lh" ]; then say "verify: deployment commit_hash == HEAD"; else say "verify: MISMATCH deployment commit_hash $deployed_commit vs HEAD $lh"; fail=1; fi
  fi
  local files; files=$(cd dist && find . -type f ! -name '_redirects' ! -name '.*' | sed 's#^\./##' | sort)
  local host f url want got n=0 attempt
  for host in "${HOSTS[@]}"; do
    for f in $files; do
      url="https://$host/${f%index.html}?v=${lh:0:12}"
      want=$(sha < "dist/$f")
      for attempt in 1 2 3 4 5 6; do
        got=$(curl -sSfL --max-time 20 "$url" | sha) || got=fetch-failed
        [ "$got" = "$want" ] && break
        sleep 10
      done
      if [ "$got" = "$want" ]; then n=$((n+1)); else say "verify: MISMATCH $url"; fail=1; fi
    done
    if [ -f dist/_redirects ]; then
      while read -r from to code; do
        [ -n "${from:-}" ] && [ "${from#\#}" = "$from" ] || continue
        local res; res=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "https://$host$from")
        if [ "${res%% *}" = "$code" ] && [ "${res#* }" = "https://$host$to" ]; then n=$((n+1)); else say "verify: MISMATCH redirect $host$from -> got $res, want $code $to"; fail=1; fi
      done < dist/_redirects
    fi
  done
  {
    date '+%Y-%m-%d %H:%M %Z'
    echo "head=$lh github=$rh deployment_commit=${deployed_commit:-n/a} checks_passed=$n failed=$fail"
  } > "$PUB/verify.txt"
  [ "$fail" = 0 ] || die "verification failed (see above)"
  say "verify: ok, $n live checks passed on ${HOSTS[*]}"
}

cmd_all() {
  cmd_commit "${1:-}"
  cmd_push
  cmd_deploy
}

case "${1:-}" in
  check) cmd_check ;;
  commit) shift; cmd_commit "${1:-}" ;;
  push) cmd_push ;;
  adopt) cmd_adopt ;;
  deploy) cmd_deploy ;;
  verify) shift; cmd_verify "${1:-}" ;;
  all) shift; cmd_all "${1:-}" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
