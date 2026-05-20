# messagesfor.ai — marketing site

Static landing page deployed to Vercel at https://messagesfor.ai.

## Deploy

One-time setup:

```sh
cd site
npx vercel link        # link to a new or existing Vercel project
npx vercel --prod      # deploy to production
```

Vercel auto-detects static HTML and serves `index.html`. No build step.

## Custom domain

In the Vercel project's Settings → Domains, add `messagesfor.ai` (and
`www.messagesfor.ai` if desired). Vercel surfaces the DNS records you
need to point at your registrar — typically:

- `A` record on `@` → `76.76.21.21`
- `CNAME` on `www` → `cname.vercel-dns.com`

(Vercel will give exact values — use those rather than the placeholders
above.)

## TODO

- Replace the screenshot-placeholder div with a real PNG (`screenshot.png`)
  showing the menu bar drafts list with a few drafts staged.
- Add `icon.png` at site root (or `/public/icon.png` if a build step is
  added later) — referenced by `<link rel="icon">` and the header logo.
- If the site grows beyond a landing page, migrate to a framework
  (Next.js / Astro / SvelteKit) and re-deploy. Vercel handles all three
  with zero config.

## Release-time checklist

The Download button points at
`/releases/latest/download/Messages-for-AI.dmg`. GitHub resolves the
`latest` segment to the most recent release, and `scripts/build-dmg.sh`
always outputs the .dmg under that stable filename — so `index.html`
never needs touching across releases. As long as every release uploads
a `Messages-for-AI.dmg` asset, the marketing site stays current
automatically.

(History: through v0.3.2 the asset was versioned, e.g.
`messages-for-ai-v0.3.2.dmg`, which required bumping the link on every
release. Switched to the stable name starting v0.3.2.1.)
