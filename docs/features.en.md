**English** | [简体中文](./features.md)

# 📖 Core Features

> This document details NexHub's most distinctive — and often most misunderstood — capabilities. For installation & usage see the [User Guide](user-guide.en.md); for writing sources see the [Developer Guide](developer-guide.en.md).

What makes NexHub different from similar tools is that it completely strips "parsing capability" out of the app and hands it to the community to maintain via source files. Here is a breakdown of each capability.

## 2.1 Source-as-Plugin · Co-created Community (the core)

This is the soul of NexHub. Please understand it first:

- **Parsing logic is fully decoupled from sites**: there is no "logic hard-coded for a specific site" anywhere in the app code. Whether a site can be parsed depends solely on whether you have a matching source JSON;
- **Two authoring styles — declarative + scripted — freely combinable**:
  - **Declarative**: describe "where the list items are, where the title is, where the chapter links are" with XPath / JSONPath / CSS selectors. Best for stable server-rendered pages — zero code, intuitive to modify;
  - **Scripted**: embed a JavaScript snippet in the source (executed in the `flutter_js` safe sandbox) to handle dynamic rendering, login-state injection, encrypted-parameter assembly, API signing, and other complex scenarios;
- **Multi-engine dispatch via `ResolverRegistry`**: once the app reads a source, it automatically selects a resolver by `parser.type` —
  - `builtin` / `xpath` / `jsonpath` / `css` → declarative parsing;
  - `script` → executes the source's embedded script in the JS sandbox;
  - `hybrid` → switches between "declarative / scripted" per route;
  - `webview` → renders in an embedded browser before extraction;
- **One engine, unlimited sources**: the community can add and fix sources every day while the app itself keeps working for months without an update.

> In one sentence: **the app is a bookshelf; sources are the books. The shelf doesn't care about the books, and the books don't care about the shelf.**

## 2.2 The iron rules of the source JS sandbox (required reading for source authors)

Source scripts run in the `flutter_js` (QuickJS engine) sandbox, isolated from the Dart main thread. Two **device-verified** constraints matter here — understanding them saves you many detours:

1. **The async channel is limited**: sandbox support for `Promise` / `async` is incomplete. When a script needs HTTP data, it should NOT `await fetch` itself. Instead it returns a "protocol object" telling the engine "fetch this URL, then process the data with this function"; the Dart side fetches it and feeds the data back to a synchronous handler;
2. **Synchronous processing + bridged fetching**: separate "computing" from "fetching" — fetching goes through the engine's bridge channel; the source script only does pure synchronous parsing and transformation. This "generic protocol" has zero impact on fully synchronous scripts and provides the only reliable channel for scripts that need networking.

Master these two points and you can implement advanced effects like "logged-in scraping, API signing, dynamic pagination" without getting stuck on "why doesn't async work".

## 2.3 Home multi-section & dynamic filters (what you see is what you get)

To keep each source's home experience consistent yet distinct:

- **Home sections**: a source can declare `homeSections` (which sections its home page shows and what they're called); if not declared, the app **automatically** generates "latest + each category" sections from the source's categories (skipping aggregation items like "All / Summary", up to 8 sections) — so old sources get a multi-section home instantly without re-exporting;
- **Dynamic filters**: a source can declare `filters.groups` to provide filter dimensions. **Category itself is already a top tab, so it won't be duplicated as a filter group**; when a source provides tag routes + tag lists, the app auto-generates a "tag filter" whose option `value`s use the site's real tag slug (e.g. `gufeng` on the gufeng site, not `gu-feng`) while `label` shows the Chinese display name — ensuring filtered results **accurately match the site**.

> Key lesson of this mechanism: **confirm the URL / slug spelling first, then judge whether the page is JS-rendered**. A source once mistyped a tag slug (extra hyphen) causing an empty shell page, which was misjudged as "SPA client rendering" and fell back to the search endpoint — but search did full-title matching and results were inaccurate. With correct spelling, the server-rendered page scrapes directly and content is accurate.

## 2.4 Manga reader (dedicated polish)

Not just "readable" — it has dedicated fixes for real pain points:

- Supports **double-page / single-page** layouts, page-turn gestures, chapter selection, left/right swipe switching;
- Handles "**over-screen ranges**" (extra-long webtoons spanning screens), "**missing image** auto-skip placeholder", "**progress regression**" (reading progress wrongly reset) and other common issues;
- Reading progress and bookmarks are persisted — closing and reopening returns to the same spot.
- **v2.0.0-beta.2**: night-light warm overlay, sleep timer (by minutes / by chapters), triple-state double-tap / E-Ink refresh / ICC color (6 presets), auto-favorite cover, configurable preload count (1–16), keyboard shortcut completion and adjustable scroll-wheel speed, plus resource & memory optimization (archive temp-dir cleanup, memory-budget image cache, progress flush when backgrounded).

## 2.5 Novel reader (six UX principles)

The novel reader follows an explicit set of UX principles so that "settings truly take effect and don't fight each other":

1. **Styles coexist**: font, size, line height, margins, theme, brightness etc. coexist as "combinations / bit flags" instead of single-select overrides — turn on eye-care AND night mode and both apply;
2. **Instant effect + persistence**: any change takes effect immediately, is written locally, and stays that way next time;
3. **Every item truly works**: no placeholders; toggles don't conflict;
4. **Controls give feedback**: adjustments have animation / visual feedback so you know "it moved";
5. **Secondary settings inline**: advanced settings use an "inline / bottom previewable panel", **not a separate page**, so the reading flow isn't interrupted;
6. **Ask before changing**: any UI / interaction change gets a plan confirmed first.

> Note: the brightness control just left-of-center in the reader maps to the "left vertical swipe" gesture, consistent with the video player's interaction habits.

**v2.0.0-beta.2 highlights**: dual-page mode (side-by-side in landscape), whole-book page numbers, bilingual / paragraph translation (AI), AI chapter illustration, AI reading summary, in-reader text editing, e-ink theme, source JS simplified⇄traditional helpers, Mobi / PDF portable doc parsing, batch archive import, per-book fine-grained WebDAV reading-progress sync, EPUB export with custom template + WebDAV upload, highlight / annotate / share, online multi-voice TTS, smooth auto-page and custom bookmark badge icons, etc.

**Existing capabilities (always available)**:

- **Typography**: widow/orphan control (never leaves one or two characters dangling at the top or bottom of a page), font size / line height / paragraph spacing / margins / letter spacing, background presets and custom colors, shadow / underline / italic, chapter-title alignment with independent font scaling, 9 header/footer content combinations, separate body and title fonts.
- **Reading aids**: sleep timer (auto-stop when it fires) and background wake lock; tap zones for page turning (screen split into zones, each configurable); bookmarks (book / chapter / page) and notes (per book / per chapter).
- **Local & import**: EPUB lazy loading with NCX / spine table of contents; TXT split into chapters by internal headings; TXT export.
- **Sync**: WebDAV backup / restore (favorites + progress) for moving between devices.
- **Shelf**: empty groups are hidden automatically so long lists aren't filled with empty categories.

## 2.6 Video player (with danmaku)

- Based on `media_kit` (libmpv engine) for cross-platform hardware-accelerated playback, with built-in decode-error auto-degradation and a playback statistics panel;
- Uses `canvas_danmaku` for **danmaku (bullet comments)** rendering (supports open danmaku networks such as DandanPlay, auto-matching danmaku pools by title) for a "watching together" feel;
- Dedicated optimization for "line selection, episode deduplication, player UI interaction" to reduce "can't play after selecting / duplicated episodes / stutter when switching episodes".

**Player gestures & interaction:**

- **Tap on screen**: show / hide the control bar (one tap toggles, more natural);
- **Double-tap center**: play / pause; **double-tap left half**: rewind 10s; **double-tap right half**: forward 10s;
- **Long-press**: temporarily switch to a custom fast-forward speed (released to restore), configurable in the player more-menu or "Settings → Player Settings → Long-press speed" (default 2.0x);
- **Horizontal swipe**: seek (with progress preview), seek multiplier adjustable in settings (0.5x / 1x / 2x);
- **Left-half vertical swipe**: brightness; **right-half vertical swipe**: volume;
- **Buffering animation**: shows a spinner center-screen while buffering instead of a silent black screen;
- **Parse progress bar**: when opening an episode to "find the video URL", a thin progress bar appears at the top (like a web loading bar), advancing in two stages: sniff / parse;
- The player more-menu and "Settings → Player Settings" provide: decode mode, audio channel, aspect ratio, default speed, default volume, auto-play-next, orientation lock, subtitle style, long-press speed, etc. — **all settings truly take effect** (read and applied at player startup).
- **v2.0.0-beta.2**: Anime4K super-resolution (efficiency / quality modes), danmaku sending after signing in to DandanPlay, cache degrade (auto-downgrade on cellular / low-memory), graded error retry (auto-reopen on episode switch), declarative player menu, subtitle memory per video, anti-overlap track algorithm, stable danmaku position after seek, etc.
- **v2.0.0-beta.2**: PiP and casting now have full lifecycles — system PiP saves position on entry, resumes on exit, offers three mini-window actions (play/pause, danmaku, fast-forward) and enters only when eligible; casting supports two-way position sync, error reporting and auto-pause on disconnect; desktop PiP becomes a pinned mini window that is draggable and restores the original window when closed.

## 2.7 Video sniffer engine (new in v0.3.0)

When a source's video parsing fails, there's a fallback: the built-in sniffer borrows the "network interception + DOM detection + API hooking" methodology of open-source projects like cat-catch, sniffing the real video URL (m3u8 / mp4 etc.) from the play page, and can merge sniffed results into the source video-fetching flow to compensate for failed parsing.

- Custom sniffer scripts supported (configurable on the settings page; ships with a generic rule set);
- Sniffed URLs can be played with anti-hotlink headers (Referer / User-Agent).

## 2.8 Download management

Supports offline downloads with download settings and task management — read / watch on without a network (subway, plane, expensive data).

## 2.9 Bangumi sync (new in v0.4.0)

Sync local tracking / reading progress to [Bangumi](https://bgm.tv):

- **Two login methods**: OAuth 2.0 (browser authorization redirects back to the app, auto-refreshed) or a manually-entered personal Access Token; credentials are stored in the system secure storage;
- **What syncs**: collection status (wish / doing / done), watched episode counts for anime, manga / novel reading progress, local ratings and short comments;
- **Conservative strategy**: local-push-first; status only moves forward, progress only increases; never overrides your "on-hold / dropped" on Bangumi; pulls ratings / comments back only when local data is missing;
- **Entry binding**: local entries auto-match Bangumi entries by title similarity (threshold ≥0.85), otherwise a candidate list for manual selection; unbind anytime;
- **Detail-page Bangumi tab**: rating, collection stats, synopsis, episodes & air dates, tags, characters, related works, and comments;
- **v0.4.1 enhancements**: one-click sync from the detail page (down to a specific episode / chapter), manual per-episode / per-chapter sync, multi-select sync dialog, incremental sync + conflict detection with detailed status, unified backup archive, remember-position toggle;
- **Proxy / mirror**: separately configure main-site, API, and image domains for unreliable direct connections.

> OAuth credentials are injected at **compile time** and never written into source code. Official builds have them injected; when self-building without injection the OAuth button is unavailable — use an Access Token instead, or register an app at [bgm.tv/dev/app/create](https://bgm.tv/dev/app/create) (callback URL `nexhub://oauth/callback`) and build with `--dart-define=BANGUMI_CLIENT_ID=... --dart-define=BANGUMI_CLIENT_SECRET=...`.

> Cloud sync: as of v2.0.0-beta.2, novel reading progress supports **fine-grained per-book WebDAV sync** (one file per book, silent upload on background, automatic conflict resolution); general favorites/settings backup remains based on local import/export and Bangumi sync.

## 2.10 Network config: global + source-level override (new in v0.4.0)

Hands problems like "can't connect, polluted DNS, need a proxy" back to the user instead of waiting for the source author to change the source:

- **Global settings**: proxy (direct / follow system / manual, HTTP & SOCKS5 with credentials), DNS (system / custom UDP / **DoH** / **DoT**, built-in Cloudflare / Google / Quad9 presets, optional cache), custom Hosts, SNI, ECH;
- **Source-level override**: each source can independently choose "inherit global" or "override" for proxy / DNS / SNI / ECH / Hosts; a source JSON can also ship a recommended `network` block;
- **Priority**: user override > source JSON `network` block > global settings > defaults;
- **Scope**: global config covers all app network requests (including cover loading and the downloader); DNS has TTL caching and hits custom Hosts first; **changes apply instantly, no restart needed**;
- **Built-in tests**: proxy test, DNS test, DoH test.

> **SNI genuinely works for direct HTTPS connections**: you can set a custom SNI value, or `-` to suppress SNI entirely (no-SNI, which together with custom hosts pinning a reachable IP bypasses SNI-based blocking); the settings page adds a "host → SNI mappings" editor and a "Test SNI handshake" button.
>
> ⚠️ Honest limitations: **ECH** is **not wired up at runtime** due to Dart TLS-stack limits — for restricted sites prefer no-SNI / custom SNI combined with Hosts, or a local ECH-capable proxy core (manual proxy, e.g. mihomo / sing-box).

## 2.11 Collection groups, local ratings & comments (new in v0.4.0)

- **Multiple groups**: one entry can belong to multiple groups (tag-style), independent of the site's genre categories; groups are **isolated per module** (anime / manga / novel), can be **hidden**, drag-reordered, and renamed; deleting a group only unlinks entries, never deletes them;
- **Multi-select filter**: the group bar supports selecting multiple groups for union filtering; the bookshelf filter adds a "group" dimension (including "ungrouped");
- **Local ratings & short comments**: 0–10 rating + a short comment, optionally pushed as part of Bangumi sync;
- **Comments**: the detail-page "Comments" tab has "Site comments" (from the source site; post / reply / like / report depending on which routes the source declares) and "Bangumi comments" (read-only, no login needed).

## 2.12 Source login auth (new in v0.4.0)

For sources that require login to view content:

- **Web login (WebView)**: an embedded WebView opens the site's login page and captures the session cookie on success;
- **Manual cookie paste**: fallback for desktop and other WebView-less scenarios;
- **API key login**: when a source declares `comments.login.sendTokenAs = "key"`, the user pastes the key in Source details → Login; the app stores it in the local key store and appends `Authorization: Key <key>` to protected requests (prefix via `authScheme`, key name via `apiKeyParam`). For sites that hand out an access_token on login but require a separate API key on favorites / profile endpoints;
- Login state is auto-detected and refreshed; **logout** supported (clears only that site's session, not other sources).

## 2.13 Source management (refactored in v0.4.1)

- **Source-library subscribe / pick-import**: browse the source library, pick, and one-click import — no longer only manual JSON paste;
- **Full-field editing**: visual editing of source JSON fields inside source management;
- **Login fix**: fixed login-state detection & refresh for some sources on the source-management page.

## 2.14 Age-rating system (new in v0.4.1)

- A complete age-rating policy: sources can declare `ageRating` (`general` / `teen` (16+) / `mature` (18+));
- **18+ (`mature`) sources are automatically hidden by default**; can be manually enabled;
- Network favorites and source management also respect the age-rating filter.

## 2.15 Source announcements & web favorites (new in v0.4.x)

- **Source announcement `announcement`**: source authors can declare an announcement in the source JSON (e.g. "site changed domain"), shown as a banner at the top of the source's home / detail pages — the app hard-codes no site copy;
- **Web favorites `webFavorite`**: if the source site itself provides a "bookshelf / favorites" web page, the source can declare web-favorite config to add a "Web favorites" tab in online browsing (via the source-site account, independent of the app's local favorites); the detail page / reader / player can also offer "Add to web favorites".

## 2.16 RSS subscription

Built-in configurable RSS routes — subscribe to public RSS feeds (e.g. anime news) and read updates directly in the app.

## 2.17 History & update tracking

Records browsing history and tracks chapter update times (with a fallback for sources that don't return update times, avoiding "always shows not-updated").

## 2.18 Material 3 design + dynamic color

Built on the Material 3 design system, with light / dark themes, custom accent color, and Material You dynamic color extraction on supported systems (auto-follows wallpaper).

## 2.19 Multilingual

Built-in Chinese / English language packs (based on Flutter official `gen-l10n`); **all user-visible copy goes through i18n**, easing global community collaboration and localization.

## 2.20 Cross-platform

Built on Flutter, compilable to **Android / iOS / Windows / macOS / Linux / Web** (platform support per release build).

---

> What changed in each version? See the [Release Notes](../RELEASE_NOTES.md) (Chinese).

## 2.21 You may also like (source capability)

- **Recommendation route**: a source declares `recommend` (preferred) or `related` in `routes`; the detail page calls it with the `{id}` variable and shows the results as the "You may also like" block (hidden when neither is declared);
- **Manga**: use `selectors.detail.recommendations` (`list` / `title` / `cover` / `url`) to extract the list straight from the detail page;
- **Novel (Legado)**: use `ruleBookInfo.recommendations` for recommended titles;
- Recommendations reuse the list parsing engine with the same fields as search / latest — **declared by the source author, the app hard-codes no site recommendation logic**.

## 2.22 Manga page translation (MTL · new in v2.0.0-beta.3)

Cross-language manga reading gets its barrier lowered by "machine-translated embedded text":

- **Translate on page turn**: when you open a page, it is automatically run through visual OCR + translation; the translated bubbles are mapped onto the original image position based on viewport / aspect ratio / reading mode;
- **Remembered per work**: the toggle lives in the long-press menu and reader settings panel; the preference is remembered per work, and a failed page can be retried;
- **Four-level cache**: translations are cached by work | chapter | page | language, so re-opening an already-seen page opens instantly;
- **Stability hardening**: a concurrency semaphore (network requests capped at 2; cache hits don't consume a slot) prevents rapid page-turns from triggering 429 rate-limiting;
- **Dedicated endpoint**: the "Manga translation" settings page accepts a dedicated AI endpoint (falls back to the general translation endpoint when empty).

## 2.23 Real-time video subtitle translation (new in v2.0.0-beta.3)

Cross-language video is covered by "real-time subtitle translation":

- **Subtitle panel toggle**: remembered across sessions; reads player subtitles throttled and translates sentence by sentence;
- **Fallback when no subtitles**: when no subtitle track exists, it captures frames and OCRs the on-screen text as a fallback;
- **Original text optional**: the overlay at the bottom can toggle whether to show the original text alongside; cached persistently by language | md5;
- **No dropped lines**: a single line uses exponential backoff retry (up to 3 times), so a momentary network blip no longer drops a line;
- **Dedicated endpoint**: the "Video translation" settings page accepts a dedicated AI endpoint (falls back to the general translation endpoint when empty).

> Manga page translation / real-time subtitle translation depend on AI endpoint config; when not configured they fall back to the general translation endpoint or are unavailable.

## 2.24 Highlight / annotate / extract / share (novel reader)

When you meet a striking line in a novel, you can save and share it without leaving the app:

- **Trigger**: long-press to select a word / sentence inside the novel reader, and an action bar pops up: highlight, annotate, extract, share;
- **Highlight / annotate**: persisted per book, still visible when you re-enter the book; highlights color-mark key passages for easy review;
- **Extract**: selected sentences go into the book's "extracts / notes", where you can browse, manage, and delete them together;
- **Share card**: generates a "book cover + gradient literary card" style share image (based on `share_plus`), broadcasting the quote together with the book title / cover to other apps in one tap;
- These operations only touch local data — they don't affect the source site and upload nothing.

## 2.25 Update channels & version upgrade (beta channel / SemVer)

Get new features early without being bothered by unstable builds — two upgrade channels split the difference:

- Inside the app, "Settings → About / Update" checks for new versions, splitting **stable** and **pre-release** into two channels;
- Version comparison follows **SemVer**: when the core version matches, pre-release numbers are compared segment by segment — fixing the bug where "beta.1 → beta.2 same-core iteration was judged 'up to date'", so the beta channel stopped receiving updates;
- The pre-release channel identifies **alpha / beta / rc** by tag and upgrades level by level (alpha < beta < rc < release); the stable channel auto-filters pre-release tags;
- Turn on "pre-release channel" for early access; stay on stable if you want stability; upgrades reuse the same signing key, so they install over the previous build directly.

## 2.26 Reading statistics

Review "how much / how long you read" — all the data stays local:

- Locally records **reading time** and **reading progress**, aggregated by day (daily granularity); depends on no account and uploads nothing;
- Covers the **novel / manga / video** readers, all instrumented uniformly;
- View cumulative and recent data in "Settings / About" or the relevant stats entry, handy for self-review and finding where you left off.

## 2.27 Danmaku rendering & integration (video player)

The video player has built-in danmaku, creating a "watching together" feel:

- Renders danmaku with `canvas_danmaku`, overlaid on the `media_kit` video frame;
- **Danmaku source**: can connect to open danmaku networks like DandanPlay, auto-matching the danmaku pool by title / episode; some sources require a signed-in danmaku account before pulling / sending;
- **Rendering detail**: since beta.2 it includes an anti-overlap track algorithm, stable danmaku position after seek, and per-video subtitle memory; after signing in to DandanPlay you can send danmaku;
- The danmaku toggle and basic style are adjustable in the player "more" menu / settings; films without a danmaku source show no danmaku layer.
## 2.28 Translation Advancements (v2.0.0-beta.3+)

On top of the three translation pipelines (novel paragraphs / manga pages / video subtitles), a cross-module advanced toolkit:

- **Glossary & name consistency**: an editor under Settings → AI configuration maintains "term → preferred translation + accepted aliases" with JSON import/export; entries are injected into all three pipelines so character names stay consistent across a book; deviations are logged as conflicts;
- **Context injection**: subtitle requests carry recent dialogue pairs, novel chunked requests carry the previous chunk tail, manga page requests carry a short previous-page summary;
- **Style presets & deliberate translation**: one style preset (standard / colloquial / elegant / internet slang) applies to all three modules; the deliberate (chain-of-thought) toggle is off by default;
- **Whole-book prescan (novel)**: triggered from the translation panel; per-chapter summaries are batched and merged into a ~200-word book overview, resumable when interrupted; later translations automatically receive the book context and current-chapter recap;
- **Checkpoint resume (novel)**: long chapters persist a checkpoint after every chunk; "Resume translation" continues from where it stopped without re-billing finished chunks;
- **Optional polish**: once enabled in settings, finished chapters can be polished in a second pass; results live in a separate slot and the panel toggles between first-pass and polished text;
- **Translation review reports**: Settings → AI configuration → review runs local zero-cost checks (glossary consistency / missing translations / suspicious literal style) with per-finding evidence; reports are stored and exportable as JSON;
- **Offline whole-video translation (phase 1)**: pick an external subtitle file (SRT / VTT / ASS) in the subtitle panel, translate the whole track in checkpointed batches, then export bilingual SRT/ASS and upload to WebDAV, with batch export for all finished jobs; **limitation**: embedded subtitle tracks cannot be extracted in full, use external subtitle files;
- **Multi-provider failover**: each of novel / manga / video translation accepts a backup endpoint; connection failures, timeouts and 429 rate limits fail over within a single request, and an endpoint failing twice in a row is suspended for 5 minutes (session memory);
- **Export enhancements**: manga translations export/import as JSON (cache hits after import, no re-billing); the novel appendix honors the translation-first / source-first / bilingual layout setting.

> The glossary is stored per book + language; the global table applies everywhere, including subtitle translation where no book identity exists. Review reports are local heuristics only (no extra request cost); deeper pronoun-breakage review requires model re-reading and is not included yet.
