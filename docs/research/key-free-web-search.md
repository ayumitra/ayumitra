# Key-free public web search: research (no implementation)

Context: production search uses Brave and needs a key. After discussing
key-free alternatives on 13 October 2026, the founder chose to provide a
Brave key for the POC. Key-free options below remain research only; none is
implemented or required for this milestone.

Constraint reminder: only filtered general public queries may leave the
device; records never leave; no secrets embedded in the open-source APK.

## Option A — supported keyless APIs (no key at all)

- **DuckDuckGo Instant Answer** (`api.duckduckgo.com/?q=…&format=json`):
  verified live 2026-10-13, but returns instant answers only
  (`AbstractText`/`RelatedTopics`) with an empty web-`Results` list on probe.
  The old API docs page is retired, so this is best-effort with no SLA. It is
  **not** full web search and must never be presented as such.
- **NCBI E-utilities** (PubMed/PMC literature): officially keyless at
  3 requests/second per IP (10/s with a free key). Fits the app's bounded
  research rounds (≤6 calls) and medical domain; responses are structured
  XML/JSON, no HTML parsing.
- **OpenFDA** (drugs/devices/food adverse events, labels): its authentication
  page lists limits without a key (240 requests/minute, 1,000/day per IP),
  but also says a key is required. Resolve this inconsistent guidance with
  current endpoint checks before treating it as a dependable keyless source.
- Both medical APIs are HTTPS GET, work from Android and iOS with the same
  client code, and do not require embedding a shared secret in the APK.

## Option B — public HTML search pages (unofficial)

Fetching `html.duckduckgo.com/html/`-style result pages and parsing them has
no key, but there is **no supported endpoint**: markup changes break parsing,
bots face rate-limiting/CAPTCHA with no recourse, and DuckDuckGo's Terms
require authorized use with suspension for violations. No SLA, fragile on
both platforms, and the app would be one markup change away from silent
wrong answers. Not recommended as a product dependency.

## Option C — user-hosted SearXNG (self-hosted meta-search)

SearXNG documents a clean `GET/POST /search?q=…&format=json` API, but its own
docs warn that **many public instances disable JSON/CSV/RSS (HTTP 403)** and
public instances routinely throttle bots. The honest deployment is the one
its docs are built for: the **user runs their own instance** (server, Pi, or
desktop) and points the app at it. Privacy is then excellent (queries go to
the user's box), but it replaces "no personal key" with "run a server" —
worse setup friction than a Brave key for a child-first app. Never bundle a
third-party public instance: availability is unreliable and queries would
leak to strangers.

## Platform notes

- Android native direct HTTPS and iOS URLSession HTTPS both suffice for A
  and C; every endpoint above is HTTPS (App Transport Security fine).
- No CAPTCHA solving anywhere: a blocked provider must surface an honest
  "search unavailable" state, never a bypass attempt.

## Recommendation (for Main + human decision)

1. Keep Brave-with-user-key as the only general web-search path if the human
   chooses it (key lives in phone settings, never in the repo/APK).
2. If the human declines any key: do **not** ship HTML scraping or a bundled
   public SearXNG. Ship **domain keyless APIs only** (NCBI E-utilities +
   OpenFDA) inside the existing bounded research budget — they are official,
   key-free, rate-documented, and match the medical use. Label general web
   research as unavailable without a key.
3. Offer user-hosted SearXNG as an optional advanced endpoint later (user
   types their own instance URL), never as the default.

## Honest limitations

- Keyless domain APIs cover literature/labels, not the whole web; some
  extended-thinking questions will legitimately return "no public sources".
- Keyless IP-based limits are shared with everything else on the IP; a busy
  network can throttle the app with no recourse except backing off.
- DDG Instant Answer coverage is narrow and undocumented; treat it as a
  nice-to-have snippet source at most, not evidence.

## Sources (official, fetched 2026-10-13)

- DuckDuckGo Terms of Service (authorized-use / suspension basis):
  https://duckduckgo.com/terms
- DuckDuckGo Instant Answer endpoint (live probe, instant answers only):
  https://api.duckduckgo.com/?q=hemoglobin+normal+range&format=json&no_html=1&skip_disambig=1
- SearXNG Search API (`format=json`, often disabled on public instances):
  https://docs.searxng.org/dev/search_api.html
- NCBI E-utilities key policy (3 req/s keyless, 10 req/s with free key):
  https://ncbiinsights.ncbi.nlm.nih.gov/2017/11/02/new-api-keys-for-the-e-utilities/
- OpenFDA authentication and limits (240/min + 1,000/day keyless per IP):
  https://open.fda.gov/apis/authentication/
