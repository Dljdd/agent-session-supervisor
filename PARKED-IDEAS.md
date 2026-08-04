# Parked ideas
### Everything else worth keeping from the research, with honest assessments

Not dead — just not first. Each has the criticism attached so you don't have to re-derive it later.

---

## Pluks — Mac copy-paste is a 4-step process

**Source:** Ask HN, June 2026 — *"copy paste is a 4 step process on mac (natively)"*

**The honest problem:** clipboard management on macOS is a crowded, well-served category. **Maccy** is free and excellent, **Raycast** has it built in, **Paste** and **Alfred** are established paid options. macOS still has no native clipboard history (Windows has Win+V), which is why this keeps getting rebuilt — but the third-party answer is mature.

**What would need to be true:** you'd need an angle the incumbents don't cover. I don't know what Pluks' specific angle is — worth 20 minutes of looking before investing anything.

**Verdict:** real annoyance, crowded solution space. Only worth it with a specific differentiator.

---

## getstowly.app — appliance receipts and maintenance

**Source:** Ask HN, July 2026 — tracking appliance receipts, maintenance history, upcoming service tasks

**The honest problem:** there's a graveyard of home-inventory apps, and they all die the same way — **data entry**. Nobody wants to type in 30 appliances, so the app stays empty, so they never come back.

**What would need to be true:** the entire product is *not making people type*.
- Parse receipts straight out of Gmail
- Read the model plate from a photo
- Pull purchase history from Amazon order emails

**The retention hook is warranty expiry.** *"Your washing machine's warranty ends in 30 days"* is a reason to open an app you installed a year ago — which is exactly what these apps normally lack.

**Verdict:** real, small, low willingness to pay. A nice thing, not a business. Good weekend project if you want something non-technical to ship.

---

## The Pareto-frontier directory

**Model:** [MiniPCs.zip](https://minipcs.zip) — 115 HN points, June 2026

**The recipe:**
1. Pick a category where buying is confusing — many models, messy specs, obscure brands
2. Scrape listings automatically, refresh often
3. Reduce the decision to one chart — price vs. what people actually care about
4. Make one strong checkable claim: *"red means you can't get a better deal for the price"*
5. Affiliate links, or just audience

**Categories that fit:** GPUs · NAS boxes · monitors · mechanical keyboards · e-bikes · 3D printers · mesh wifi · air purifiers · solar and battery · used cars · robot vacuums · espresso machines

**Pick one you'd enjoy arguing about**, because the judgement *is* the product. Scraping is the easy half.

**Verdict:** proven recipe, one weekend, ages well, accrues SEO. Genuinely good and completely independent of the plugin work.

---

## AccessMRF — healthcare price transparency data

**Source:** Ask HN, June 2026 — healthcare price transparency datasets *"unmanageable at scale"*

Hospitals are **legally required** to publish machine-readable pricing files. The files are enormous, schemas are inconsistent, and the data underneath is genuinely valuable.

**Why it's interesting:** mandated to exist, published in a hostile format, nobody has cleaned it. Do it once and you're the canonical source permanently — people link your version instead of the raw files.

**Why it's not first:** it's a slog, not a weekend. US-centric. Compounding rather than fast.

**Verdict:** best long-term "trapped data" play I found. Park it properly rather than losing it.

---

## Other problems worth keeping

| Problem | Source | Note |
|---|---|---|
| *"which of my friends is free to talk right now?"* (Beacon) | HN June 2026 | Attempted many times, never solved. High risk, high reward. |
| *"GitHub, discourse forum, email and internal docs all are fragmented"* (seaticket) | HN July 2026 | Internal knowledge search. Crowded, but the pain is universal. |
| *"minutes trying to browse all my 30,000 photos"* | HN July 2026 | Local photo search without Google/Apple lock-in. |
| Saved content scattered across LinkedIn/Instagram/YouTube (Linkosh) | HN July 2026 | Everyone has this. Hostile APIs are why it's unsolved. |
| Forgot an AWS instance → $1,700 bill (watchmy.cloud) | HN July 2026 | Their insight is sharper than their product: *"existing tools require manual setup people forget about."* Zero-config-by-default is the whole game. |
| Expensive niche professional software with no cheap tier | HN June 2026 (optics, circuit schematics) | A search strategy, not one idea. Look for $2,000+/seat tools unchanged since 2010. |
| Dairy farm software locked into proprietary formats | HN June 2026 | The generalisable version: any industry where one vendor owns the data format. |
| Content rot — *"the bigger the website grows, the harder it is to keep track of certain facts"* | HN, All About Berlin | Watch the sources, flag the stale pages. Still unbuilt generally. |

---

## Explicitly ruled out

Checked and found occupied — recorded so you don't rediscover them:

- **AI-content detection** — 1,102 HN points of demand, but the thread's own conclusion is that detection doesn't work. Demand wrapped around an unsolved research problem.
- **AI visibility / "does ChatGPT cite my site"** — Ahrefs ships a free one; plus Birdeye, Sona, isvisible.ai, amivisibleonai, UltraScout.
- **Competitor monitoring for founders** — Visualping, Thunderbit, PageCrawl, Snitchfeed, GrowthOS, Beaconmon.
- **Auto-changelog from commits** — ReleasePad, ReleaseGlow, BunnyDesk, and GitHub ships auto-generated release notes natively.
- **Docs-drift tooling** — Mintlify, GitBook, GitDoc, Tembo.
- **"AI employee" role bundles** — Sintra, teammates.ai (from $25/mo), Asana AI Teammates. Commoditising fast.
