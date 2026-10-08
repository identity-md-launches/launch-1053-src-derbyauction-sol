# WP5: Nightly theme job (one `job.continue` per auction winner)

**Goal:** turn the winning answers into a valid theme pack (WP1 format) and republish the
site under the same name, in **one** `job.continue` on the hosting project. Fills
`{{…}}` from the auction's `Settled` and `Bid` events. Cost: 0.5 IMD (about 0.25 net), paid
from the operator's job wallet (build fee is 0 in v1).

## Inputs

| Placeholder | Source |
|---|---|
| `{{DATE}}`, `{{DAY}}` | theme day as `YYYY-MM-DD` and as a day number |
| `{{WINNER}}` | `Settled.winner` |
| `{{CREATURE}}`, `{{TITLE}}`, `{{SHOUTOUT}}` | winning `Bid` strings |
| `{{VIBE}}`, `{{STADIUM}}`, `{{WEATHER}}` | enum names (WP3) |
| `{{PRUNE}}` | dated folders older than the newest 6 in `themes/index.json` |
| `{{HEAD}}` | the hosting project's `project.head` (`GET /jobs/:id`) |

**Screen first (operator).** If the creature or title names an existing character, real
person or brand, or is offensive, don't build: escalate to the owner for `veto` (WP6).
Borderline but fixable ("Mario" → "an original plumber-ish creature") is fine to build,
because the brief tells the swarm to make an original instead.

## The job body

```json
{
  "parentJobId": "{{HEAD}}",
  "objective": "Add the Swarm Derby theme pack for {{DATE}} and republish the site.",
  "shape": "chain",
  "steps": [
    {
      "skill": "refine-project",
      "paths": ["themes/{{DATE}}", "themes/index.json"],
      "objective": "<BRIEF below, filled in>",
      "acceptanceCriteria": [
        "node dev/validate-theme.mjs --all passes",
        "themes/index.json maps {{DATE}} to {{DATE}} and lists at most 7 dated themes",
        "themes/{{DATE}}/theme.json has winner {{WINNER}} and auctionDay {{DAY}}",
        "screenshots of idle, swing and celebrate with the date forced to {{DATE}} are attached",
        "no file outside the listed paths changed"
      ]
    },
    { "skill": "import-site",
      "objective": "Copy exactly index.html, agent.md, agent-bot.mjs, LICENSE, NOTICES.md and the whole themes/ folder into dist/, byte for byte. Nothing else." },
    { "skill": "site-content-check" }
  ],
  "ipfs": true
}
```

Dry-run with `POST /requests/check`. Only the wallet that paid the hosting job can pay.
Afterwards, mirror `themes/{{DATE}}/` and `themes/index.json` from the job's result into the
GitHub repo so the open-source repo matches what's live.

## BRIEF (the refine-project objective)

```
Build the Swarm Derby theme pack for {{DATE}} following specs/WP1-theme-packs.md exactly.
Write it to themes/{{DATE}}/ and map "{{DATE}}": "{{DATE}}" in themes/index.json.
Remove these old dated entries and their folders: {{PRUNE}}. Never remove themes/gus.

The day's design comes from the auction winner:
- Batter: an original {{CREATURE}} baseball player with a {{VIBE}} personality.
- Stadium: a {{STADIUM}} ballpark. Weather visuals: {{WEATHER}}.
- Title "{{TITLE}}". Shoutout "{{SHOUTOUT}}" exactly as given (null if empty).
- winner {{WINNER}}, auctionDay {{DAY}}.

Art direction:
- The game's chunky sticker style: thick dark outlines (#1a1410), flat colours, simple
  shapes, readable at 128x160. Match themes/gus/ for scale, pose and anchor point.
- Draw the batter as code (SVG or canvas) with one function per pose and render all seven
  PNGs from it, so the character is identical in every pose. Same for the pitcher.
- Jersey number 7 unless the title suggests another 1-2 digit number.
- Backdrop: a {{STADIUM}} scene above the fence; keep x 380-1220, y 60-480 low-detail.
  Choose a palette that suits it and keeps the field lines readable.
- Commentary: 3-8 playful lines per result in the voice of the pitcher daemons, about this
  batter, stadium and weather; {feet} in homer, bomb and slam lines. No mention of oracles,
  attestations or signatures.

Content rules:
- Original characters only. Never draw or name an existing character, mascot, logo,
  artwork, real person or brand, even if the answers mention one; make an original
  creature of the same general kind instead.
- Nothing sexual, violent, hateful or mocking a group. No text in images except the jersey
  number. No URLs.
```

## Deadlines (UTC)

| Time | |
|---|---|
| 18:00 | auction closes (19:00 at the latest, after extensions); `settle(day)` |
| 18:15 | job sent |
| ~19:15 | typical finish (builds have taken 40–60 min) |
| by 21:00 | published; preview to the owner. Time for one send-back (another `job.continue`) |
| by 23:30 | owner's last comfortable moment to `veto` |
| 00:00 | theme day starts |

If nothing is published by 00:00, the day runs on `gus`; the bonus still pays out from the
board. A late pack is picked up by the page within a minute.

## Done when (this template, run once on a test date)

1. [ ] With sample answers (`lobster`, `chaotic`, `underwater`, `rain`, `Lobster Cup`,
       `@test`), the job validates, publishes under the same site name, and the live site
       shows the pack on that date.
2. [ ] With a creature naming a famous character, the result is an original creature
       (check the screenshots).
3. [ ] Pruning keeps at most 7 dated themes and never touches `gus`.
