# Merlin Brief

A public information site for Merlin, Inc. (NASDAQ: MRLN). Not investment advice, a forecast, or a company site.

Live site: https://merlinbrief.com (also served at https://merlin-brief.pages.dev)

## What is in this repo

- `dist/` is the exact set of static files the live site serves (Cloudflare Pages project `merlin-brief`, production branch `main`). Every page update is committed here and deployed from this same folder, so the repo and the site stay in step. One file is the exception: `dist/og.jpg`, the social share card, is served live but kept out of git because the current publishing setup can only push text files to GitHub.
- `timeline.md` is the dated timeline writeup, and `sources/` holds short text extracts of the pages it cites. The site's old `/timeline` tab now redirects to the home page, so this writeup lives here only.
- `publish.sh`, `tools/`, and `PUBLISH.md` are the single publish path: commit, push to GitHub `main`, deploy the same tree to Cloudflare Pages, then check that the live site and GitHub both match.

## What a reader can check

- What Merlin says the Merlin Pilot is, on Merlin's own pages
- The difference between an IDIQ ceiling, contract value, revenue, and cash
- Which dated lines are a contract, a concept, or a plan
- What is still unknown, including anything that was only in a screenshot

## Rules

- No number without the page it came from
- A ceiling is not cash
- A path is not a fleet buy
- A planned date is not a result
- Air Force or SOCOM items that do not name Merlin are not Merlin contracts
- No Crossroads fleet-conversion numbers
