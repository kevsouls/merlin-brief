# Publishing

Every update goes to GitHub `main` first and then to Cloudflare Pages production from the same folder. Never deploy to Pages any other way.

Edit files in `dist/`, then run from the repo root:

```bash
./publish.sh all "Short description of the update"
```

`publish.sh all` runs, in order:

1. `check`: guardrails. No personal names (word list in `.git/info/forbidden-words`, kept out of the repo), no PDFs or images other than `dist/favicon.svg` and `dist/og.jpg`, no secrets, no `node_modules`, `.wrangler`, or `.publish` files.
2. `commit`: commits any changes.
3. `push`: pushes HEAD to GitHub `main`.
4. `deploy`: uploads `dist/` and creates a production deployment on branch `main`, tagged with the git commit SHA. It refuses to run unless the tree is clean and GitHub `main` equals local HEAD.
5. `verify`: fetches every file in `dist/` from merlin-brief.pages.dev and merlinbrief.com and compares bytes, checks each `_redirects` rule, and confirms GitHub `main` equals local HEAD (and the deployment's commit SHA, when given).

When git and Cloudflare credentials are present in the environment (`git push` works, and `CLOUDFLARE_API_TOKEN` plus `CLOUDFLARE_ACCOUNT_ID` are set), that one command does everything.

## Agent path (no credentials on the machine)

The script stops at the step that needs a connector, prints what to do, and exits with 20 (GitHub) or 30 (Cloudflare). The full sequence:

1. `./publish.sh all "message"` commits, then exits 20 and writes `.publish/connector-push.json`.
2. GitHub connector `push_files` with the `push_files` object from that file, unchanged. Each `content` is a `$file:` reference that the tool call expands. Run `delete_file` for any `delete_file` entries.
3. `./publish.sh adopt` checks that GitHub's tree equals the local tree and moves local HEAD to GitHub's commit, so both SHAs match.
4. Cloudflare MCP `execute` with code `$file:<repo>/tools/mcp-get-upload-token.js`. It returns a short-lived upload JWT.
5. `CF_PAGES_UPLOAD_JWT='<jwt>' ./publish.sh deploy` uploads the assets, writes `.publish/mcp-create-deployment.js`, and exits 30.
6. Cloudflare MCP `execute` with code `$file:<repo>/.publish/mcp-create-deployment.js`. It returns the deployment id and commit_hash.
7. `./publish.sh verify <commit_hash>` must print `verify: ok`.

## Notes

- `_redirects` is sent as the deployment's redirects file. `_headers` is currently uploaded as a plain static file (as all earlier deploys did), so its header rules are not applied by Pages.
- Deploy logs for each run land in `.publish/` (ignored by git).
