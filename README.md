# LumoraTV

🌐 **English** · [Español](LEEME.md)

<p align="center">
  <img src="docs/screenshots/02-home-top10.png" alt="LumoraTV — a cinematic, streaming-grade home screen on Apple TV" width="100%">
  <br>
  <sub><i>For illustrative purposes only — sample TMDB metadata shown in a tvOS Simulator.</i></sub>
</p>

### 🤖 An entire premium Apple TV app. Written by AI. Zero lines of human code.

**LumoraTV is a premium, cinematic streaming client for Apple TV (tvOS) — a cinematic home, a
desktop-grade media player, a recommendation engine, multi-user profiles — and every single
line of it was engineered by Anthropic's frontier models, directed by a human who never
touched the code.**

This is not a demo, a prototype, or a code-generation experiment that someone cleaned up
afterwards. It is a **shipped-quality consumer product running on real hardware**, and it
exists to document a turning point: **the moment building real software stopped requiring a
human to write it.**

> ⚡ **~26 hours** of wall-clock collaboration · **169** human↔AI interactions ·
> **1,500+** autonomous engineering actions · **~15,000** lines of Swift 6 across **53**
> files · **~3.85 million** tokens of pure output · **zero** lines of human-written code.

LumoraTV is service-agnostic: it presents a unified, beautiful interface on top of whatever
media source you connect, with a real libmpv/FFmpeg player, per-user state, a recommendation
engine, parental controls and full English/Spanish localization.

---

## Table of contents

- [The experiment](#the-experiment)
- [Why this exists — a note from the human](#why-this-exists--a-note-from-the-human)
- [The numbers](#the-numbers)
- [A new way of building products](#a-new-way-of-building-products)
- [Features](#features)
- [Screenshots](#screenshots)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation & deployment](#installation--deployment)
- [First-run setup (onboarding)](#first-run-setup-onboarding)
- [Optional external sources](#optional-external-sources)
- [Privacy](#privacy)
- [Services referenced & disclaimers](#services-referenced--disclaimers)
- [Independence & trademarks](#independence--trademarks)
- [License](#license)
- [Third-party software](#third-party-software)
- [Contributing](#contributing)

---

## The experiment

One question started everything:

> *Can today's frontier AI build a premium consumer app that feels **shipped** — not a toy,
> not a scaffold, not a weekend demo — working only through natural-language direction?*

The answer is this repository. **100% of the design, architecture, code, debugging,
refactoring and documentation was produced by AI** — **Claude Fable 5**, Anthropic's newest
frontier model, together with **Claude Opus 4.8** — working as the sole engineer. The human
role was strictly **assistance**: product vision, taste, on-device testing on a physical
Apple TV, and feedback. **No code was hand-written by a person. Not one line.**

And this is not CRUD with a nice coat of paint. The models handled what is usually considered
*hard* engineering, unassisted:

- Integrating **libmpv/FFmpeg with a Metal render pipeline** (gpu-next via MoltenVK) on tvOS,
  with VideoToolbox hardware decoding and HDR10 / Dolby Vision colorspace handling.
- **Swift 6 strict concurrency** across the entire codebase — the newest, most demanding
  concurrency model in the ecosystem, building clean.
- A **service-agnostic playback architecture** that resolves and merges content across
  multiple backends behind one premium UI.
- A **local database with 11 schema migrations**, an incremental sync engine with
  reconciliation, image caching with LRU enforcement, and a per-user state system.
- The entire **tvOS focus-engine choreography** — the part of TV development that veteran
  developers describe as the most unforgiving.
- Its own **bilingual localization system**, a hybrid recommendation engine, parental
  controls, and the build pipeline itself (no Xcode IDE — everything is generated and built
  from the command line).

> **Roles, stated plainly:** AI (Claude Fable 5 & Claude Opus 4.8) — 100% of the design,
> engineering, code, debugging and documentation. Human ([Jose Canchila](AUTHORS)) — product
> vision, on-device testing, and feedback. The model is the engineer. The human is the
> director and tester.

## Why this exists — a note from the human

I am a software developer with **more than 20 years of professional experience** building
software. I have written code for longer than some of my tools have existed. I did not need an
AI to build this app for me — **I needed to know, first-hand, exactly how far the current
generation of models can go.**

So I set the hardest test I could think of that would fit in my living room: a full premium
tvOS app — a platform with a brutal focus engine, a niche toolchain, strict concurrency, and
real hardware in the loop — built **end-to-end by the model**, with me acting only as product
director and tester. I deliberately wrote zero code. Every bug went back to the model in plain
language. Every fix came back as a diff I never edited.

After two decades of writing software by hand, watching a model own an entire codebase —
architecture decisions, gnarly debugging sessions, performance work, polish — and deliver
something I would be proud to ship, is the closest thing to a paradigm shift I have
experienced in my career. This repository is my evidence, and my way of sharing it.

## The numbers

Everything below was measured from the actual session logs — nothing is estimated.

| Metric | Value |
|---|---|
| Engineering done by AI | **100%** — zero lines of human-written code |
| Models | **Claude Fable 5** & **Claude Opus 4.8** (Anthropic) |
| Total build time (wall-clock) | **~26 hours** of collaboration |
| Human ↔ model interactions | **169** conversational turns |
| Autonomous engineering actions | **1,504** (builds, file edits, installs, debugging) |
| Output tokens generated | **~3.85 million** (Fable 5: ~1.74M · Opus 4.8: ~2.11M) |
| Total tokens processed (incl. context cache) | **~1.44 billion** |
| Source files | **53 Swift files** |
| Lines of code | **~14,900** (Swift 6, strict concurrency) |
| Human estimate for the same scope, solo | **months** — done here in ~26 hours |

## A new way of building products

This project demonstrates a workflow that simply did not exist a short time ago:

1. **The human describes intent** — in plain language, often dictated: *"the hero card should
   reveal the synopsis on focus"*, *"continue watching must reuse the same source"*.
2. **The model engineers the solution** — it reads the codebase, makes architecture decisions,
   writes the code, regenerates the project, compiles it, and installs it **onto the physical
   Apple TV by itself**.
3. **The human tests on the couch, remote in hand** — and reports back in seconds: *"the focus
   gets trapped in the filter panel"*.
4. **Repeat.** 169 times. ~26 hours later: a finished product.

No tickets, no specs, no handoffs, no boilerplate sessions. The iteration loop collapses to
the speed of conversation. **The bottleneck is no longer writing software — it is deciding
what the software should be.**

**An honest finding from the experiment:** this workflow does *not* mean anyone can build
anything yet. One thing became clear across 169 interactions — **a base of knowledge in
technology, software development and design is still required** to make the *right* requests:
to describe a feature in terms the model can engineer correctly, to recognize when a flow can
be improved and articulate how, and to report a bug with enough precision for it to be
diagnosed and fixed. The model removes the need to *write* the solution; it does not (yet)
remove the need to *understand* the problem. Direction quality is what turns raw model power
into a shipped product.

---

## Features

The design bar was set against the best living-room apps in the industry — fluid motion and
focus, a dense home with smart rows, and cinematic aesthetics — and then pushed further. This is
the full list; nothing here is a mockup, everything ships and runs on a real Apple TV.

### 🎬 A home screen that feels alive
- **Cinematic hero** with full-bleed artwork, official logos and gradient treatments — focus a
  card and the short synopsis reveals itself in place.
- **Smart rows**: Continue Watching (with live progress bars), Trending (oversized horizontal
  backdrop cards with embedded info), In Theaters and Coming Soon — each row with its **own
  distinct visual design**, not a cloned carousel.
- **Category navigation** with unique, non-repeating backdrop art per category.
- **"For You"** — a personalized row computed per user, surfaced right under the categories
  next to **My List**.
- **Zero-spinner philosophy**: content is precached and rendered before you arrive whenever
  physically possible.

### 🧠 Recommendations that actually know you
- A **hybrid recommendation engine**: your local taste profile (genres, cast, likes/dislikes,
  watch history) blended with **catalog-wide metadata intelligence** for high-precision picks.
- **"More like this"** computed against the full metadata catalog, not just what you own.
- **Like / dislike** signals feed back into every row, per user.
- Recommendations, search, grids and similar-content are all **parental-filtered** per user.

### 📺 A player most commercial apps can't match
- **libmpv / FFmpeg** rendered through **Metal** (gpu-next via MoltenVK) — the same engine
  enthusiasts trust on desktop, running natively on tvOS.
- **Direct play of essentially everything**: MKV, HEVC, AV1, high-bitrate remuxes — no server
  transcoding required.
- **HDR10, HLG and Dolby Vision reshaping** with correct colorspace hinting, plus hardware
  decoding via VideoToolbox. Per-version **HDR badges** in the UI.
- **Multichannel LPCM 5.1 / 7.1** audio and experimental bitstream passthrough.
- **Skip intro / skip credits**, credits-aware **smart next episode** with countdown card, and
  a full **in-player episodes browser** (seasons, thumbnails, watch state) without leaving
  playback.
- **Cumulative seek with preview thumbnails** (BIF), Apple-TV-style invisible focus surface,
  and a top panel for Info / Audio / Subtitles / Settings.
- **Configurable on-screen info**: clock, date, age rating, genres, score, year, quality,
  current audio and subtitle tracks — every element toggleable.
- **Cinematic picture modes** — Normal, Sleep (dimmed/desaturated for night viewing), Vivid
  (punchier color) and **Noir** (black & white) — global, persistent, switchable from both the
  player panel and Settings, with an on-screen badge when a non-default mode is active.
- **Content frame-rate matching**: the display refresh rate switches to the video's native
  cadence (24/25/30/50/60) for judder-free motion (via AVDisplayManager), HDR-aware.
- **Stats for nerds**: an optional live technical overlay (resolution, codecs, bitrate, dropped
  frames, cache, connection) for diagnosing playback.
- **Adaptive buffering states** with live detail (connection, speed, peers, percentage) and a
  stall watchdog that recovers or offers alternatives instead of freezing.
- Screensaver and idle timer are correctly suppressed during playback.

### 💬 Subtitles & audio done right
- **External subtitle support** with **automatic language detection** (on-device natural
  language analysis) when tracks come unlabeled.
- **OpenSubtitles integration** for fetching missing subtitles.
- Full styling control: **size, font and color**, per user preference, live.
- Preferred audio/subtitle language applied automatically on every play.
- **Per-content audio & subtitle memory**: the audio and subtitle you picked are
  remembered per title (and carried across a series binge) and restored
  automatically when you resume — even for **unlabeled embedded tracks**, matched
  by position when no language tag is present.

### 🗣️ Learn a language while you watch — a feature nobody else has
- Turn any movie or series into a **passive language tutor**. Watch with
  subtitles in the language you're learning and the app quietly **highlights the
  words that are new to you** and tracks your vocabulary as you go — **the film
  itself becomes your spaced-repetition system** (a word graduates to "known"
  after enough on-screen encounters).
- **Zero interaction required while watching** — learning happens in the
  background without altering the viewing experience.
- **On-demand recall**: pause, and the player offers a *"what was just said?"*
  panel — review the recent lines, replay them, hear them spoken aloud
  (on-device text-to-speech), and get a tutor-style explanation.
- 100% **on-device** vocabulary model (Apple's Natural Language framework), per
  user, no backend. Toggle it from the player panel or Settings.

### ✨ A built-in AI language tutor — bring your own provider
- A dedicated **Artificial Intelligence** settings tab that works with **any
  OpenAI-compatible provider**: OpenAI, Anthropic (Claude), Google Gemini, Groq,
  OpenRouter, or a local model (Ollama / LM Studio).
- Enter your key and **validate it by listing the models you actually have access
  to** — no blind free-text field — then pick one.
- Select a subtitle line and the AI **explains the whole line** (meaning and
  usage) using the surrounding lines as context, **answering concisely in your
  preferred subtitle language**, like a real teacher. The explanation is
  scrollable, with a **bounded cache** so it never fills the disk; a built-in tip
  recommends an economical model for learning.

### 🗂 A library without limits
- **Multi-server, merged catalog**: the same title across several servers is fused into one
  entry; a **version picker** appears only when it matters, with quality/HDR badges per
  version.
- **Per-server speed test** built into Settings to know exactly what your network can sustain.
- **Series intelligence**: seasons and episodes with watch state, **missing-episode detection**
  against authoritative episode counts, and Play that automatically starts at the **first
  unwatched episode**.
- **Top 10 Today**, **collection / saga rows** that group a franchise, **new-episode alerts**
  for the shows you're watching, and **smart resume** that picks up exactly where you left off.
- **Premium metadata**: posters, official logos, backdrops, synopses and cast — re-downloaded
  and **re-localized when you switch the app language**.
- **People view**: jump from any title to its cast and browse everything by actor or director.
- **Search** with recent-history, across your library and the extended catalog.
- **Trailer for everything**: when a trailer isn't available, the app plays a 15-second
  preview of the title itself — no dead buttons.

### 🔌 Service-agnostic to the core
- The entire app is built around an abstract **source** model: any backend that can resolve a
  catalog entry and a playable URL gets the **exact same premium UI** — same detail screen,
  same cards, same player.
- **Source picker** as a blurred cinematic modal with **provider filter chips**; **change
  source mid-playback** from inside the player, and the error overlay offers alternative
  sources instead of a dead end.
- **Auto-best-source** mode: one press on Play, the app picks the optimal version for you,
  driven by a **composite ranking** (quality, swarm health, your configured languages,
  reasonable size, freeleech) plus **automatic failover**: if the best source won't start, it
  moves on to the next one with on-screen feedback.
- **Smart Data — a ranking that learns by watching you watch**: the app learns from real
  behavior — which indexers load and get finished, and which *uploaders* (release groups)
  ship files you watch to the end **with their embedded subtitles on** (ground truth isn't
  what the title promises, it's you finishing the movie with those subs active; having to
  download external subtitles mid-watch counts against them). All of it visible in
  **Settings → Smart Data**: reputation gauges per indexer and uploader, with a reset button.
  Bayesian-smoothed counters, local to the device, zero telemetry.
- **Local / remote origin badges** on every card type, so you always know where content lives.
- An optional, **off-by-default Streaming Mode** extends browsing to a full metadata-driven
  catalog with paginated grids and a professional **filter panel** (genre, year, rating,
  sorting) designed to handle tens of thousands of titles.

### 👨‍👩‍👧 Truly multi-user
- **Per-user everything**: watch progress, Continue Watching, My List, likes/dislikes, recent
  searches — keyed to the active Apple TV user identity.
- **Parental controls per user**: PIN plus maximum age rating, enforced across home, grids,
  search, recommendations and similar content.
- **Cross-device sync (with iCloud)**: with a paid Apple Developer account, your watch
  progress, My List, ratings, preferences, learned vocabulary, parental controls and your
  chosen/downloaded subtitles sync **per person** across all your Apple TVs through your private
  iCloud — **end-to-end encrypted** for the sensitive parts (Apple only ever sees ciphertext).
  Downloaded subtitles "follow" you by reference (the app re-fetches them on the other TV).
  Without iCloud, everything stays **fully local** and nothing changes.
  - **Requirement:** each Apple TV user must sign in with **their own Apple ID**. That is what
    keeps profiles isolated *and* lets each person's data sync across their own TVs — your
    daughter's profile and yours never mix. Several profiles sharing a single Apple ID can't be
    told apart by iCloud, so they can't be kept separate (a platform limitation, not the app).
- Progress is reported to a backend **only** when content is actually playing from that
  backend; everything else stays local and private.

### ✨ Usability & craft
- **Guided onboarding** designed for non-technical users: automatic account link with a short
  code and **QR code** — no typing on the TV if you don't want to.
- **Apple-grade focus engine work**: scale + glow focus effects, smooth `.smooth` motion
  everywhere, large rounded typography, and focus-driven navigation that never traps you.
- **Long-press context menu** on every card (play, My List, like/dislike, go to details).
- **Deep links** (`lumoratv://`) ready for Top Shelf and external integration.
- **Two languages, first-class**: complete English and Spanish localization — UI *and*
  metadata.
- **Connection test per service** in Settings, with clear pass/fail diagnostics.
- **Local-first persistence** (SQLite via GRDB), **incremental sync with reconciliation**,
  metadata response caching, and an **image cache with a configurable size limit and LRU
  purge**.
- Robust network-error handling: clear messages, retry paths, never a silent hang.

---

## Screenshots

> ⚠️ **For illustrative purposes only.** The catalog imagery below is **sample TMDB metadata** captured in a tvOS Simulator to show the interface. LumoraTV ships with **no content of its own** — it is a player for sources *you* configure and own, and it does not host, distribute, or promote piracy.

<table>
  <tr>
    <td width="33%"><img src="docs/screenshots/02-home-top10.png" alt="Home — Top 10"><br><sub><b>Home</b> — Top 10 row, cinematic</sub></td>
    <td width="33%"><img src="docs/screenshots/04-movie-detail.png" alt="Movie detail"><br><sub><b>Detail</b> — cinematic hero, cast, actions</sub></td>
    <td width="33%"><img src="docs/screenshots/05-series-detail.png" alt="Series detail"><br><sub><b>Series</b> — seasons & episodes</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/06-browse-movies.png" alt="Browse movies"><br><sub><b>Browse</b> — filterable catalog grid</sub></td>
    <td><img src="docs/screenshots/08-browse-anime.png" alt="Browse anime"><br><sub><b>Categories</b> — Movies · TV · Anime · Doramas · Docs</sub></td>
    <td><img src="docs/screenshots/12-settings-playback.png" alt="Settings — playback"><br><sub><b>Settings</b> — minimalist, deep playback control</sub></td>
  </tr>
</table>

**[→ Full gallery](docs/screenshots/)** — every screen (home, detail, all categories, full settings).

---

## How it works

LumoraTV is built around an abstract notion of a **source**. The detail screen, the catalog
rows and the playback UI don't care where content comes from: a self-hosted media server, an
external metadata-driven catalog, or a future backend all flow through the same components.
When you press Play, a resolver collects every available version across your configured sources
and either plays the best one or asks you to choose.

- **Catalog**: your self-hosted media server (the app is built and tested against Plex as the
  reference backend) provides your real library; a metadata provider enriches it with artwork
  and recommendations.
- **Playback**: a unified player plays whatever URL the resolver returns.
- **State**: progress, lists and ratings live locally, per user. Progress is only reported back
  to a backend when the content is actually being played *from* that backend.

This design is what makes the app extensible to additional server types in the future.

---

## Requirements

**Hardware**
- An **Apple TV 4K** (2nd gen or newer recommended), running **tvOS 26** or later, in developer
  mode and paired to your Mac.

**Build machine**
- **macOS** with the **Xcode** toolchain installed.
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An **Apple Developer account** — a free account works (with limitations, see below); a paid
  account removes them.

**Backends you provide**
- A **self-hosted media server** on your network (Plex is the reference backend).
- A free **metadata API key** ([TMDB](https://www.themoviedb.org/settings/api)), entered during
  onboarding — required for premium artwork and recommendations.
- *(Optional)* external sources — see [Optional external sources](#optional-external-sources).

> **Free Apple account limitations:** provisioning profiles expire every **7 days**, so you must
> re-build and re-install weekly to keep the app running. A paid account ($99/year) removes
> that limit and unlocks per-user profiles and Top Shelf.

---

## Installation & deployment

This project is **built entirely from the command line** — the Xcode project is generated from
`project.yml` by XcodeGen and should never be edited by hand.

```sh
# 1. Clone the repository, then open project.yml and set DEVELOPMENT_TEAM
#    to your personal Apple team ID.

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Build a signed app for the device
xcodebuild -project LumoraTV.xcodeproj -scheme LumoraTV \
  -destination 'generic/platform=tvOS' -allowProvisioningUpdates build

# 4. Find the built .app
xcodebuild -project LumoraTV.xcodeproj -scheme LumoraTV \
  -destination 'generic/platform=tvOS' -showBuildSettings | grep BUILT_PRODUCTS_DIR

# 5. Install on your paired Apple TV (replace <UDID> and the path)
xcrun devicectl device install app --device <UDID> <BUILT_PRODUCTS_DIR>/LumoraTV.app

# 6. Launch it
xcrun devicectl device process launch --device <UDID> dev.jodacame.lumoratv
```

**Pairing tips**
- Find your Apple TV's UDID with `xcrun devicectl list devices`.
- If the device shows as `unavailable`, wake it with the remote.
- If pairing drops: on the Apple TV go to *Settings → Remotes and Devices → Remote App and
  Devices*, then run `xcrun devicectl manage pair --device <UDID>`.

After changing `project.yml` or adding files, always re-run `xcodegen generate`.

---

## First-run setup (onboarding)

The app guides you through setup with the remote (no typing required where avoidable):

1. **Connect your media server** — either the automatic link flow (you get a short code and
   confirm it from your phone, and the app finds your servers), or a manual setup where you
   enter the server's IP, port and access token directly.
2. **Premium metadata** — paste your free metadata API key (you can also do this later in
   Settings). This enables high-quality posters, logos and recommendations.
3. **Done** — explore your library.

All secrets you enter are stored in the system **Keychain**, never in plain text.

---

## Optional external sources

Welcome to the section the legal department insisted on labeling *"purely experimental"*,
that engineering describes as *"a thin client over HTTP"*, and that you — the first time you
see it work — will describe as **witchcraft**. ☕

*(Note: this project has no legal department. It has a disclaimer at the end of this section
and a great deal of faith in your common sense.)*

Every self-hosted library has the same ceiling: your disk. Terabytes of NAS, years of curating
collections — and the movie you want to watch tonight is, of course, the one that isn't there.
**Streaming Mode** (optional, **off by default**) flips the equation: instead of browsing
*what you own*, you browse **the entire metadata catalog — tens of thousands of titles,
effectively infinite** — with the same premium rows, the same detail screen, the same player…
and content resolves **on demand, at the moment you press Play, storing absolutely nothing**.

No disks full of media. No waiting for downloads. No library to maintain. You press Play on
something you don't own, and seconds later it's playing on your Apple TV as if it had always
been there. The first time it works it is, frankly, a little absurd: an infinite video library
served by a little box that draws less power than your TV's standby LED.

The catch? *(There is always one.)* The app performs no magic on its own — it is a **thin
client**. The dirty work is done by two services that **you** host on any always-on machine in
your network (a mini-PC, a Raspberry Pi, that old laptop in the drawer — a NAS works too, you
just no longer *need* one for anything but this):

| Piece | What it does | What you need |
|---|---|---|
| [Prowlarr](https://prowlarr.com) | The search engine: finds releases for a title across the indexers you configure. | Install it, add indexers, paste its URL + API key into Settings → Streaming Mode. |
| [TorrServer](https://github.com/YouROK/TorrServer) | The bridge: turns a torrent into a playable HTTP URL on the fly, with smart buffering. Nothing touches the Apple TV's storage. | Install it and paste its URL into Settings → Streaming Mode. Alternative: [FluxTorrent](https://github.com/jodacame/FluxTorrent), a simpler, lighter bridge by the same author, compatible with the same setup. |
| A [TMDB](https://www.themoviedb.org) key | The "infinite" catalog you browse. | The same free key from onboarding. |

With all three pieces configured, you flip the Streaming Mode toggle (which shows you a very serious
warning you should genuinely read) and the Home expands: the full catalog with professional
filters, source selection with provider filtering, season packs that play the exact episode
you asked for, and Continue Watching that remembers the original source. The app only ever
plays an HTTP URL; it does not download, index or store anything.

> ⚠️ **Legal disclaimer (the part without sarcasm).** This is **dual-use technology**. It is
> disabled by default and gated behind an explicit toggle with a warning. **You are solely
> responsible** for what you index, stream or access through any source you connect, and for
> complying with the laws and rights applicable in your jurisdiction. The authors provide this
> feature for legitimate uses only (e.g. your own content) and **do not endorse or condone
> copyright infringement**. Use it at your own risk.

---

## Privacy

LumoraTV is a **local-first** client:

- It **collects no analytics** and sends **no telemetry** to the authors.
- It connects **only** to the servers and services **you** configure.
- All credentials (tokens, API keys) are stored in the device **Keychain**.
- Watch state, lists and ratings are stored **locally** on the device.

---

## Services referenced & disclaimers

LumoraTV can interoperate with the following third-party services. **None of them is bundled,
pre-configured or required beyond what you choose to set up yourself.** Each one is an
independent product of its respective owner:

| Service | What LumoraTV uses it for | Disclaimer |
|---|---|---|
| [Plex](https://www.plex.tv) | Reference self-hosted media-server backend: library catalog, streams, account link flow. | Plex is a trademark of Plex, Inc. LumoraTV is an **unofficial, independent client**, not affiliated with, endorsed or certified by Plex, Inc. You need your own Plex server and account. |
| [TMDB](https://www.themoviedb.org) | Premium metadata: posters, logos, backdrops, synopses, cast, recommendations. | This product uses the TMDB API but is **not endorsed or certified by TMDB**. You must provide your own free API key and comply with [TMDB's terms of use](https://www.themoviedb.org/terms-of-use). |
| [Prowlarr](https://prowlarr.com) | *(Optional, off by default)* Self-hosted indexer manager queried by Streaming Mode to search releases. | Independent open-source project (GPL-3.0). Not affiliated with LumoraTV. **You** run it, configure its indexers, and are responsible for what it indexes. |
| [TorrServer](https://github.com/YouROK/TorrServer) | *(Optional, off by default)* Self-hosted torrent→HTTP bridge; LumoraTV only plays the HTTP URL it exposes. | Independent open-source project. Not affiliated with LumoraTV. Runs on **your** hardware, under **your** responsibility — see the [legal disclaimer](#optional-external-sources). |
| [FluxTorrent](https://github.com/jodacame/FluxTorrent) | *(Optional, off by default)* TorrServer alternative by the same author: a simpler, lighter torrent→HTTP bridge. | Sibling but independent project. Runs on **your** hardware, under **your** responsibility — the same [legal disclaimer](#optional-external-sources) applies. |
| [OpenSubtitles](https://www.opensubtitles.com) | *(Optional)* Fetching missing subtitles. | Requires your own account/API key and compliance with their terms. Not affiliated with LumoraTV. |
| [Trakt](https://trakt.tv) | *(Optional)* Community comments & ratings in the player; rate / mark watched / comment when you link your account. Setup: [docs/TRAKT.md](docs/TRAKT.md). | Independent service. Needs your own free API app (Client ID/Secret) and, to write, your per-user login. Not affiliated with LumoraTV. |
| [plex.tv/link](https://plex.tv/link) | Device-link flow during onboarding (short code / QR). | Part of the Plex service; same disclaimer as above. |

Apple, Apple TV, tvOS and Siri Remote are trademarks of Apple Inc. LumoraTV is not affiliated
with, endorsed or certified by Apple Inc.; it is a sideloaded app you build and install with
your own developer account.

## Independence & trademarks

LumoraTV is an **independent, non-commercial, open-source project** created to explore the
capabilities of Anthropic's model. **It is not affiliated with, endorsed, sponsored or
certified by any of the services it can connect to, nor by any company, product or trademark
mentioned in this repository.**

All product names, logos and trademarks are the property of their respective owners. References
to third-party services exist only to describe interoperability. LumoraTV ships with **no
content and no credentials** and acts solely as a client that **you** configure and run.

This product uses third-party metadata APIs but is **not endorsed or certified** by those
providers; their required attributions are shown inside the app and in [NOTICE](NOTICE).

---

## License

LumoraTV is open source under the **Apache License 2.0** — see [LICENSE](LICENSE).

You may use, study, modify and redistribute it freely, including commercially, provided you
preserve the copyright, patent, trademark and attribution notices and state significant changes
you make. The license includes an explicit patent grant and provides the software **"AS IS",
without warranties of any kind**.

Copyright © 2026 Jose Canchila.

## Third-party software

LumoraTV builds on open-source software, each under its own license: mpv/libmpv (LGPL-2.1+),
FFmpeg (LGPL-2.1+), libplacebo (LGPL-2.1), libass (ISC), MoltenVK (Apache-2.0),
dav1d (BSD-2-Clause), MPVKit (LGPL-2.1), GRDB.swift (MIT). If you distribute binaries that link
the LGPL components, you must comply with the LGPL yourself. See [NOTICE](NOTICE) for the full
attribution text.

Profile avatars are generated with [DiceBear](https://www.dicebear.com): styles *Adventurer
Neutral* and *Fun Emoji* by their authors under **CC BY 4.0**, *Avataaars Neutral* and *Bottts
Neutral* by Pablo Stanley (free for personal & commercial use), and *Pixel Art Neutral* under
**CC0 1.0**. See [docs/AVATARS.md](docs/AVATARS.md) for per-style credits.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Under Apache-2.0,
contributions are accepted under the same license as the project (inbound = outbound). No CLA is
required.
