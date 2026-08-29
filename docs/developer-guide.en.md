**English** | [简体中文](./developer-guide.md)

# 🛠️ Developer Guide

> For contributors and source authors: environment setup, project structure, and most importantly — the **tiered source-authoring tutorial** (Basic / Intermediate / Advanced) with full examples.
>
> 📚 Online source-authoring tutorial (bilingual with more demos): <https://nexhub-app.github.io/website/>; this document is consistent with it and kept in sync.

## 4.1 Environment

- Install the [Flutter SDK](https://flutter.dev) (this project requires **Flutter 3.32.0**, Dart 3.x);
- Set up the build environment for your platform (Android Studio / Xcode / Visual Studio, etc.);
- Confirm `flutter doctor` shows no significant errors.

## 4.2 Get & run the code

```bash
git clone https://github.com/nexhub-app/nexhub.git
cd nexhub
flutter pub get
flutter run
```

Pick a target device (emulator / real device / desktop) to launch.

## 4.3 Build release packages

```bash
# Android
flutter build apk
# Windows
flutter build windows
# and so on for other platforms
```

## 4.4 Project structure

```
nexhub/
├── lib/                  # App main code (Dart)
│   ├── core/             # Core capabilities: networking, resolver dispatch, source repo, reader/player infra
│   │   ├── models/       # Data models (e.g. PluginConfig source config)
│   │   ├── resolver/     # Resolver engine dispatch (builtin / script / webview / hybrid)
│   │   ├── scraper/      # List/detail/chapter scraping & extraction
│   │   └── services/     # Source repo, history, download services
│   ├── features/         # Feature modules: home, source management, manga, novel, video, settings, download…
│   └── l10n/             # i18n resources (Chinese / English)
├── assets/               # Assets (icons, generic hot-search words, etc.; no site sources)
├── plugins/              # Source directory (see below)
│   └── builtin/          # ⚠️ placeholder only in this repo; no source JSON is committed
├── test/                 # Unit tests (incl. source JSON validation; auto-skipped with no built-in sources)
├── android/ ios/ linux/ macos/ windows/ web/   # Per-platform projects
└── pubspec.yaml          # Dependencies & asset declarations
```

**About `plugins/builtin/`**: this repo **does not** commit any `.json` source files there (excluded in `.gitignore`). The directory exists only as a `.gitkeep` placeholder to keep the project structure complete and buildable. Real sources live locally or come from the community — **not in the public repo**.

**Content that is excluded and must never be committed**:

- `plugins/builtin/*.json` (any built-in / prepared sources)
- `reference/` (local source backups and reference samples)
- Internal dev docs, redevelopment prompts & plans, test-data scan scripts, etc. (under `docs/`, only the whitelisted public docs and their `.en.md` English versions are committed)
- `build/`, `sdk/` (build artifacts and the Flutter SDK; huge)
- `.workbuddy/`, `.trae/`, `.qoder/`, `.probe_tmp/` (local tool & probe temp artifacts)
- Root temp scripts (e.g. `tmp_*.mjs`, `run_probe.*`, `net_check.*`)

---

## 4.5 Source-as-Plugin: how to write and contribute a source

NexHub's parsing capability is fully driven by source JSON. A source is a JSON file describing how to scrape content from a site.

### 4.5.1 Source-level site settings guide (site / network)

Each source's "site metadata" and "network access method" are written in the source file — this is the **source-level site configuration**:

**`site` (required)** — basic site info:

| Key | Type | Description |
| --- | --- | --- |
| `site.domain` | string | Site main domain (e.g. `example.com`) |
| `site.baseUrl` | string | Site root URL (e.g. `https://example.com`), used to join relative links |
| `site.userAgent` | string? | Optional custom UA |
| `site.cookies` | string? | Optional site cookies (e.g. `session=xxx`) |
| `site.headers` | object? | Optional custom request headers |
| `site.mirrors` | array? | Optional mirror list, each `{name, domain, baseUrl}` (auto-switch when the main domain fails) |
| `site.publishPageUrl` | string? | Optional publish-page URL (a navigation page when the main domain fails; mirrors can be extracted from it) |
| `site.publishMirrorSelector` | string? | Optional mirror-extraction rule on the publish page (regex string or CSS selector) |

**`network` (optional, new in v0.4.0)** — source-level network override, letting a source ship "recommended network config":

| Key | Type | Description |
| --- | --- | --- |
| `network.proxy` | object? | Proxy override, e.g. `{ "mode": "manual", "protocol": "http", "host": "...", "port": 7890 }` |
| `network.dns` | object? | DNS override, e.g. `{ "mode": "doh", "dohUrl": "https://cloudflare-dns.com/dns-query" }` or `{ "mode": "custom", "servers": ["8.8.8.8"] }`; also supports `resolveSuffix` / `resolveSuffixDomains` (see below) |
| `network.hosts` | array? | Hosts override, each `{ "ip": "1.2.3.4", "host": "example.com", "enabled": true }` |
| `network.sni` | object? | SNI override, e.g. `{ "enabled": true, "defaultSni": "-" }`; value `-` suppresses SNI entirely, a domain uses that domain as SNI, and `domainSni` maps host patterns (`.example.com` for suffix match) to SNI values |
| `network.ech` | object? | ECH override (not wired up at runtime yet, see limitation below) |

Rules: a key that is **absent = inherit global**; a key that is set = **override the whole aspect**. Priority: **user UI override for the source > source JSON `network` block > global settings > defaults**. Invalid values only warn and never disable the source.

> **How `sni` works**: genuinely effective for direct HTTPS connections (the TLS handshake is completed in-app, so SNI can be overridden with the configured value or suppressed with `-`; suppressing SNI together with hosts pinning a reachable IP bypasses SNI-based blocking — the Cloudflare edge accepts no-SNI handshakes and routes by the Host header). Not applied through a proxy.
>
> ⚠️ Honest limitations: `ech` is not wired up at runtime due to Dart TLS-stack limits — for restricted sites prefer `sni` (no-SNI / custom value) combined with `hosts`, or a local ECH-capable proxy core (manual proxy). The rest (proxy / dns / hosts) genuinely work.

> **`dns.resolveSuffix` (resolve suffix, added in v2.0.0)**: the resolver queries *target host + suffix* and connects to the returned address, while the Host header stays the original hostname.
> Use case: when the site's own domain suffers DNS poisoning, query an unaffected alias (e.g. an alias domain served by the site's CDN) to obtain real addresses — **no IP needs to be hard-coded in the config file**, since each device resolves it with its own DNS. That makes it suitable for publicly shared sources.
>
> | Key | Type | Description |
> | --- | --- | --- |
> | `resolveSuffix` | string? | Like `".alias-cdn.example"` (must start with `.`); empty = disabled |
> | `resolveSuffixDomains` | array? | Scope of the suffix: exact domains or `.example.org` for suffix matching. **Empty list = applies to every host**; listing them explicitly is recommended so unrelated hosts (image nodes, etc.) don't pay for a lookup that is bound to fail |
>
> Failure handling: if the suffixed lookup fails or returns nothing, it falls back to resolving the original hostname — never a hard error.
> Typical combo: `{ "mode": "system", "resolveSuffix": "...", "resolveSuffixDomains": ["..."] }` plus `{ "sni": { "enabled": true, "defaultSni": "-" } }`.

### 4.5.2 Source-authoring tutorial (tiered: Basic / Intermediate / Advanced)

Below is the source-authoring tutorial tiered by difficulty, consistent with the online version. The complete bilingual version is at the [online tutorial](https://nexhub-app.github.io/website/) and the field cheat-sheet in this document.

#### 🟢 Basic: what a source is & basic fields

**What a source is**: a source is a JSON file describing "how to scrape anime / manga / novel / video from a website". NexHub only provides the generic engine; all site-specific parsing logic lives in this file — that's "Source-as-Plugin". The app has a built-in JS sandbox: you can extract fields declaratively with selectors (jsonpath / css / xpath), or embed JavaScript for complex pages.

**Basic fields (every source has)**:

| Field | Description |
| --- | --- |
| `id` | Required, unique id (e.g. `manga_goda`); same-id sources upgrade/skip by `version` |
| `name` | Required, display name |
| `author` | Optional, source author name (shown on the source detail page, for attribution) |
| `version` | Integer version (default 1); same-id sources upgrade/skip by version |
| `type` | Required, media type: `animeSource` (video / anime) / `mangaSource` (manga) / `novelSource` (novel) |
| `site` | Required, site info (see 4.5.1) |
| `parser` | Parse config: `{ type, overrides?, script? }`; `type` is `builtin` / `hybrid` / `script` |
| `ageRating` | **Optional, age rating**: `general` / `teen` (16+) / `mature` (18+); aliases like `all` / `16` / `r18` / `nsfw` accepted; **default `general`; `mature` is hidden by default** |
| `enabled` | Optional, enabled (default true) |

> Note: the source model **does not read** `lang` / `builtin` — writing them is ignored, don't treat them as functional fields; `author` is now a real field shown on the source detail page.

**Minimal example (declarative anime source)**:

```json
{
  "id": "demo_anime",
  "name": "Demo Anime",
  "version": 1,
  "type": "animeSource",
  "ageRating": "general",
  "site": {
    "domain": "example.com",
    "baseUrl": "https://example.com",
    "mirrors": [ { "name": "Main", "domain": "example.com", "baseUrl": "https://example.com" } ]
  },
  "parser": { "type": "hybrid", "overrides": { "latest": { "type": "builtin" } } }
}
```

#### 🟡 Intermediate: six content modules

**Search module (search / ruleSearch)** — triggered when the user types a keyword in the search box:

- Video / manga (pattern A): define `search` in `routes` with `{keyword}` placeholder; extract the result list with `selectors` or a script;
- Novel (pattern B, Legado-compatible): use the `ruleSearch` field with CSS selectors declaring each result's book name, author, cover, detail link;
- Returned fields usually include: `id` (detail-page id), `title`, `cover`, `detailUrl`.

**Discovery / Category module (discovery / ruleExplore)** — "Home" and "browse by category" use this module:

- Pattern A: `latest` / `explore` / `category` routes + `category.categoryEntries` table;
- Pattern B: `ruleExplore` + `exploreUrl` (one "category name::URL" per line);
- Home sections are defined by `homeSections` (title, route, style grid/list, count).

**Detail / Contents module (detail / ruleBookInfo)** — loaded when opening a work: title, cover, synopsis, author / cast, tags, status, and the contents (chapters / episodes) list.

**Content module (content / ruleContent)** — a manga issue's images, a novel's body text, or a video's play page:

- Novel pattern B: `ruleContent` (content / title / nextContentUrl);
- Manga: `chapters` (episode list) → `images` (that episode's images) endpoints;
- Video: `episodes` (episode list) → `video` (real play URL) endpoints.

**Web favorites (`webFavorite`, optional)** — declare this when the source site itself provides a "bookshelf / favorites" web page, so the app's online-browsing page gets an extra "Web favorites" tab (via the source-site account, independent of the app's local favorites):

| Key | Description |
| --- | --- |
| `enabled` | Optional, enable the Web favorites tab (default true) |
| `title` | Optional, tab display name, e.g. "My Bookshelf" |
| `route` / `url` | Route name or full URL for viewing the favorites list; pick one, `route` must be defined in `routes` |
| `addRoute` / `addUrl` | "Add to favorites" route or URL; `{id}` / `{detailUrl}` / `{title}` placeholders supported |
| `requireLogin` | Optional, true requires logging in to the source site first |

```json
"webFavorite": {
  "title": "My Bookshelf",
  "route": "webFavorite",
  "url": "/user/bookshelf",
  "addUrl": "/user/favorite/add?id={id}",
  "requireLogin": true
}
```

**Source announcement (`announcement`, optional)** — source authors can publish an announcement (e.g. "site changed domain") shown as a banner at the top of the source's home / detail pages:

| Key | Description |
| --- | --- |
| `title` | Required, announcement title |
| `body` | Optional, announcement body |
| `url` | Optional, link when tapping the announcement (e.g. a migration notice page); not clickable when absent |
| `updatedAt` | Optional, update time as a Unix-seconds timestamp (for "N days ago") |

```json
"announcement": {
  "title": "Site has changed its domain",
  "body": "The old domain example-old.com is decommissioned; please update to the new domain.",
  "url": "https://example.com/notice",
  "updatedAt": 1700000000
}
```

**Weekly schedule (`schedule`, optional)** — let the source home show a "weekly schedule" (which works updated each day Mon–Sun):

1. Add an entry to `homeSections`: `{ "id": "week", "title": "Weekly", "route": "week", "style": "schedule", "limit": 0, "more": false }`;
2. Define a `week` route with the same name in `routes`; its result must carry a "weekday" field (the app groups works into Mon–Sun by it).

```json
"homeSections": [
  { "id": "week", "title": "Weekly", "route": "week", "style": "schedule", "limit": 0, "more": false }
],
"routes": {
  "week": { "url": "/api/weekly", "method": "get", "responseType": "json" }
}
```

#### 🔴 Advanced: selector syntax, JS script conventions, collection APIs, network / comments / login

**Two-layer parse structure**:

- Top-level `parser.type` takes only three values: `builtin` (pure declarative), `hybrid` (declarative + per-API `overrides`, **most common**), `script` (everything through the JS sandbox);
- Each API can specify its actual parse method via `parser.overrides.<api>.type`: `builtin` / `xpath` / `jsonpath` / `css` (four declarative subtypes) / `script` (JS sandbox) / `webview` (render in an embedded browser before extraction, commonly for m3u8 extraction) / `webview-html` (WebView fetches HTML then parses, commonly for anti-scraping search).

**Selector syntax cheat-sheet** (pick one per overrides.type):

- `jsonpath`: starts with `$`, for JSON APIs, e.g. `$.list[0].vod_name`;
- `css`: standard CSS selectors, for HTML, e.g. `.bookname a`;
- `xpath`: starts with `//` or `./`, for HTML, e.g. `//video/@src`;
- Novel sources (Legado-compatible) additionally support: `@text` for text, `@href` / `@src` for attributes, `@textNodes` for clean body text, `||` as fallback selector, `a:contains(text)` to filter by visible text, and `.0` / `.1` / `-1` to pick the Nth element.

**Embedded JS script conventions** (when declarative selectors aren't enough):

1. Function signature is fixed as `parseXxx(html, context)`; `html` is the page string, `context` contains `baseUrl`, `log`, etc.;
2. Must **return synchronously** (array or object);
3. When async data is needed, return the `{ __meta: true, __fetchUrl, __processor }` protocol object — the engine prefetches that URL, then calls `__processor` as a synchronous handler; **this is the only safe async channel in the sandbox**. Use `__fetchUrls` (array) instead of `__fetchUrl` when several pages must be fetched before one synchronous pass;
4. Never hard-code site constants into the app; keep everything in the source file.

**Collection API interfaces** — "Collection API" means the "set of scraping endpoints" a source exposes, i.e. the endpoints defined in `routes` (search / latest / detail / video / images …):

- Each endpoint defines its url in `routes` first (placeholders `{keyword}` / `{page}` / `{id}` / `{url}` / `{detailUrl}` supported), plus method, responseType, headers, params;
  - **Placeholder offsets**: numeric placeholders accept `{page-1}` / `{page+1}` (the engine always counts from 1; use `-1` for sites whose first page is `page=0`). Non-numeric values are left untouched and negative results clamp to 0;
  - **Batch prefetch**: when a page only exposes N entry links that must each be followed, return `{ __meta: true, __fetchUrls: [...], __fetchResponseType: 'text', __processor: 'handlerName' }`. The engine fetches them concurrently in Dart (default 6, tunable via `__fetchConcurrency`, capped at 16) and hands the response array to `__processor`. A single failure becomes `null` at that position instead of aborting the batch;
- Extraction is decided by `parser.overrides.<endpoint>`: `builtin` / `xpath` / `jsonpath` / `css` / `script` / `webview` / `webview-html`;
- Declarative endpoints use `selectors.<endpoint>`; script endpoints provide functions via `overrides.<endpoint>.script`;
- Common endpoints: `search` (search), `latest` (latest), `explore` / `category` (discovery / category), `detail` (detail + contents), `episodes` (episode list), `video` (video URL), `chapters` (manga episode list), `images` (manga images), `week` (weekly schedule).

**Source-level network / comments / login (new in v0.4.0)**:

- `network`: source-level network override (see 4.5.1); absent = inherit global; invalid values only warn;
- `comments`: declares the source's commenting capability. `provider` defaults to `source` (comments from the source site); `routes` declares `list` (**required**) / `replies` / `post` / `reply` / `like` / `report` (undeclared buttons are not rendered); `selectors` uses the same JSONPath / CSS / XPath engine;
- `comments.login`: **source login declaration, three login types, combinable** —
  - **WebView login**: `login.url` is the login page; the app opens it in a WebView and captures the session cookie locally after login;
  - **Cookie login**: `login.checkCookie` is the cookie key that means "logged in" for a fast check; you can also paste a whole session cookie into `site.cookies` and every request carries it;
  - **API key login**: set `login.sendTokenAs` to `"key"`; the user pastes the key in Source details, the app stores it in the local key store and appends `Authorization: <authScheme> <key>` to protected requests (prefix defaults to `Key`). For sites where login yields an access_token but favorites / profile need a separate API key (some sites' newer APIs explicitly require `Key <api_key>`, not Bearer);
- Token carrier `login.sendTokenAs`: `null` (cookie only) / `"bearer"` (`Authorization: Bearer <cookie value of checkCookie>`) / `"key"` (`Authorization: <authScheme> <manual key>`, i.e. API key login);
- Secondary session check: `login.checkUrl` + `login.loggedInSelector` (GET checkUrl; a non-empty selector match means the session is valid);
- Credentials stay local only; without a login declaration the source is treated as read-only / no-login.

```json
"network": { "proxy": "direct", "dns": "system" },
"comments": {
  "provider": "source",
  "routes": { "list": { "url": "/api/comments?book={id}", "responseType": "json" } },
  "selectors": { "items": "$.list", "content": "$.content", "author": "$.user" },
  "login": {
    "url": "https://example.com/login",
    "checkCookie": "sessionid",
    "checkUrl": "https://example.com/me",
    "loggedInSelector": ".user-info"
  }
}
// Manual cookie login: paste the session cookie into site.cookies
"site": { "baseUrl": "https://example.com", "cookies": "sessionid=abc123; uid=42" }
// API key login (same comments.login block)
"login": {
  "sendTokenAs": "key",    // appends Authorization: <authScheme> <pasted key>
  "authScheme": "Key",     // default Key; change if the site wants another prefix
  "apiKeyParam": "apiKey"  // key name in the local key store, default apiKey
}
```

### 4.5.3 Full examples (novel / video / manga)

#### Example 1: Novel source (Legado-compatible)

> Novel sources do **not** use the top-level `id` / `name` / `type` / `site` fields. Instead they use Legado fields such as `bookSourceName` / `bookSourceUrl` / `bookSourceType` / `ruleSearch` / `ruleToc` / `ruleContent` / `ruleBookInfo`; body text is handled by a script in `parser.overrides.content`.

```json
{
  "bookSourceName": "Demo Novel",
  "bookSourceUrl": "https://m.example.com",
  "bookSourceType": 0,
  "enabledExplore": true,
  "enabledSearch": true,
  "exploreUrl": "Fantasy::https://m.example.com/xuanhuan/\nUrban::https://m.example.com/dushi/",
  "bookSourceGroup": "Built-in book sources",
  "concurrentRate": 0,
  "ruleSearch": {
    "bookList": ".bookbox",
    "bookName": ".bookname a@text",
    "bookAuthor": ".author@text",
    "bookCoverUrl": ".bookimg img@src",
    "bookUrl": ".bookname a@href",
    "bookLastChapter": ".update a@text"
  },
  "ruleExplore": {
    "bookList": ".bookbox",
    "bookName": ".bookname a@text",
    "bookAuthor": ".author@text",
    "bookCoverUrl": ".bookimg img@src",
    "bookUrl": ".bookname a@href"
  },
  "ruleBookInfo": {
    "name": "h1@text",
    "author": "p:contains(Author)@text",
    "coverUrl": ".block_img2 img@src",
    "intro": ".intro_info@text",
    "tocUrl": "a[href^=\"/book_\"]@href",
    "lastChapter": "p:contains(Latest) a@text",
    "bookStatus": "p:contains(Status) span@text"
  },
  "ruleToc": {
    "chapterList": "a[href^=\"/book_\"][href$=\".html\"]",
    "chapterName": "@text",
    "chapterUrl": "@href",
    "nextTocUrl": "a:contains(Next page)@href"
  },
  "ruleContent": {
    "content": "#nr1@html",
    "title": "#nr_title@text",
    "nextContentUrl": "a:contains(Next chapter)@href"
  },
  "parser": {
    "type": "hybrid",
    "overrides": {
      "content": {
        "type": "script",
        "function": "parseContent",
        "script": "function parseContent(html, context){ var raw = context.dom.queryHtml(html, '#nr1') || context.dom.queryHtml(html, '#content') || ''; raw = raw.replace(/<script.*?<\\/script>/gi, ''); return context.content.clean(raw); }"
      }
    }
  },
  "bookSourceComment": "Demo novel source, plain HTML body"
}
```

#### Example 2: Video source (animeSource)

> The core of a video source is the `video` endpoint: here it uses `webview` to extract the real play URL (for m3u8 / sites that need page JS execution to reveal the URL). **An anime source must include the `latest` route.**

```json
{
  "id": "demo_anime",
  "name": "Demo Video",
  "version": 1,
  "type": "animeSource",
  "responseType": "json",
  "useWebview": true,
  "site": {
    "domain": "example.com",
    "baseUrl": "https://example.com",
    "mirrors": [ { "name": "Main", "domain": "example.com", "baseUrl": "https://example.com" } ]
  },
  "parser": {
    "type": "hybrid",
    "overrides": {
      "latest": { "type": "builtin" },
      "search": { "type": "builtin" },
      "detail": { "type": "builtin" },
      "episodes": { "type": "builtin" },
      "video": { "type": "webview" }
    }
  },
  "routes": {
    "latest": { "url": "/api/latest?page={page}", "method": "get", "responseType": "json" },
    "search": { "url": "/s?wd={keyword}&page={page}", "method": "get", "responseType": "json" },
    "detail": { "url": "/detail/{id}", "method": "get", "responseType": "json" },
    "episodes": { "url": "/detail/{id}", "method": "get", "responseType": "json" },
    "video": { "url": "{url}", "method": "get", "responseType": "html" },
    "week": { "url": "/api/weekly", "method": "get", "responseType": "json" }
  },
  "selectors": {
    "list": "$.list",
    "title": "$.vod_name",
    "cover": "$.vod_pic",
    "id": "$.vod_id",
    "detail": { "title": "$.vod_name", "cover": "$.vod_pic", "description": "$.vod_content" },
    "episodes": "ul li a"
  },
  "category": { "categoryEntries": [ { "id": "all", "title": "All" }, { "id": "1", "title": "Anime" } ] },
  "homeSections": [
    { "id": "latest", "title": "Latest", "route": "latest", "style": "grid", "limit": 18 },
    { "id": "week", "title": "Weekly", "route": "week", "style": "schedule", "limit": 0, "more": false }
  ]
}
```

#### Example 3: Manga source (mangaSource, GoDa skeleton)

> A manga source has two extra key endpoints over video / novel: `chapters` (episode list) and `images` (that episode's images). Key points:
> - `chapters` often needs a second request — the script first grabs `data-mid` from the page, then returns `{ __meta: true, __fetchUrl, __processor }` so the engine prefetches the chapters API, then `__processChapters` handles it synchronously;
> - Image URLs are usually encrypted: put the decryption logic in `parseImages` inside `overrides.images.script` and return the image URL array;
> - The `id`s in `selectors.category.tags` use the site's real slug (e.g. 古风=`gufeng`, no hyphen); don't invent your own.
>
> For readability, this example compresses the real source's long regex / decryption scripts into skeletons (importing directly yields empty results) — replace each `script` with real parsing logic before use.

```json
{
  "id": "manga_goda",
  "name": "GoDa Manga",
  "version": 4,
  "type": "mangaSource",
  "responseType": "html",
  "useWebview": true,
  "site": {
    "domain": "godamh.com",
    "baseUrl": "https://godamh.com",
    "mirrors": [
      { "name": "godamh.com", "domain": "godamh.com", "baseUrl": "https://godamh.com" },
      { "name": "m.baozimh.one", "domain": "m.baozimh.one", "baseUrl": "https://m.baozimh.one" }
    ]
  },
  "parser": {
    "type": "hybrid",
    "overrides": {
      "latest": {
        "type": "script",
        "function": "parseList",
        "script": "function parseList(html, context){ var baseUrl = (context.baseUrl || '').replace(/\\/$/, ''); var results = []; /* regex-scrape <a href=\"/manga/...\"> blocks, grab h3 title & cover */ return results; }"
      },
      "search": { "type": "script", "function": "parseList", "script": "function parseList(html, context){ return []; }" },
      "detail": {
        "type": "script",
        "function": "parseDetail",
        "script": "function parseDetail(html, context){ return { title: '', cover: '', description: '', author: '', tags: [] }; }"
      },
      "chapters": {
        "type": "script",
        "function": "parseChapters",
        "script": "function parseChapters(html, context){ var m = html.match(/data-mid=\"(\\d+)\"/i); if (!m) return []; return { __meta: true, __fetchUrl: 'https://v2.apikk.top/api/manga/get?mid=' + m[1] + '&mode=all', __processor: '__processChapters' }; }"
      },
      "images": {
        "type": "script",
        "function": "parseImages",
        "script": "function parseImages(raw, context){ var urls = decrypt(raw); return urls; }"
      }
    }
  },
  "routes": {
    "latest": { "url": "/manga/list/", "method": "get", "responseType": "html" },
    "search": { "url": "/search?keyword={keyword}", "method": "get", "responseType": "html" },
    "detail": { "url": "/manga/{id}", "method": "get", "responseType": "html" },
    "chapters": { "url": "{url}", "method": "get", "responseType": "html" },
    "images": { "url": "{url}", "method": "get", "responseType": "html" }
  },
  "selectors": {
    "category": {
      "categories": [ { "id": "gufeng", "name": "Gufeng" } ],
      "tags": [ { "id": "gufeng", "name": "Gufeng", "url": "/manga-tag/gufeng" } ]
    }
  },
  "category": {
    "dynamicCategories": false,
    "categoryEntries": [ { "id": "all", "title": "All" } ]
  },
  "homeSections": [
    { "id": "latest", "title": "Latest", "route": "latest", "style": "grid", "limit": 18 }
  ]
}
```

### 4.5.4 Source JSON field reference (authoritative cheat-sheet)

> Fields follow what the app actually parses; the definitive constraint is the source code at `lib/core/models/plugin_config.dart`. All fields are optional except `id` / `name` / `type` / `site` / `parser`; unknown keys are ignored.

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | Unique source id (same-id imports decide overwrite / skip by `version`) |
| `name` | string | Source display name |
| `type` | string | `animeSource` / `mangaSource` / `novelSource` |
| `version` | int | Version (default 1); on importing a same-id source: `>=` installed version replaces it, `<` is skipped |
| `ageRating` | string | Optional; `general` / `teen` / `mature` (aliases accepted, default `general`; `mature` hidden by default) |
| `site` | object | Site info (**required**): see 4.5.1 |
| `parser.type` | string | Top-level parse engine: `builtin` / `hybrid` / `script` |
| `parser.overrides` | object | Per-API parse overrides, each `{ type, script?, function? }` |
| `routes` | object | Endpoint set, each `{ url, method?, responseType?, headers?, params?, parser? }`; a plain string `"url"` is also accepted |
| `selectors` | object | Declarative extraction rules (JSONPath / CSS / XPath per overrides.type) |
| `category` | object | Category config: `dynamicCategories` / `categories` / `categoryEntries` (static category table) |
| `homeSections` | array | Optional; custom home sections, each `{ id, title, route, params?, style?, limit?, more? }`; style: `grid` / `rank` / `scroll` / `schedule` |
| `filters` | object | Optional; dynamic filters: `{ route?, groups?, byCategory?, defaults? }`; each group `{ id, title?, route?, param, multiSelect?, options[] }` |
| `tagSearch` | object | Optional; tag-search route, used with `selectors.category.tags` to generate a tag filter |
| `antiHotlinking` | object | Optional; anti-hotlink: `{ referer?, userAgent?, headers? }` |
| `webviewConfig` | object | Optional; `{ adblock?, timeoutSeconds? }` |
| `useWebview` | bool | Optional; use WebView rendering for the whole source |
| `stealthMode` | bool | Optional; stealth mode (fewer fingerprints) |
| `network` | object | Optional (v0.4.0); source-level network override: `proxy` / `dns` / `hosts` / `sni` / `ech` |
| `comments` | object | Optional (v0.4.0); commenting: `provider` / `routes` / `selectors` / `login` |
| `routes.recommend` / `routes.related` | object | Optional; 'You may also like' endpoint (`recommend` preferred, then `related`), called from the detail page with the `{id}` variable |
| `selectors.detail.recommendations` | object | Optional (manga); `{ list, title, cover, url }` to extract the list straight from the detail page |
| `ruleBookInfo.recommendations` | string | Optional (novel, Legado); selector for recommended titles |
| `announcement` | object | Optional; source announcement: `title` (required) / `body` / `url` / `updatedAt` |
| `webFavorite` | object | Optional; web favorites: `enabled` / `title` / `route` / `url` / `addRoute` / `addUrl` / `requireLogin` |
| `deprecated` / `enabled` / `enabledExplore` / `isHidden` | bool | Optional; deprecated flag / enabled / explore enabled / hidden |
| `migrationMessage` | string | Optional; migration notice |

**`comments` sub-fields (new in v0.4.0, all optional)**:

| Field | Description |
| --- | --- |
| `comments.provider` | Default `source` (comments from the source site). `bangumi` is **parsed but not implemented** |
| `comments.routes.list` | **Required** (when `comments` is declared); comment-list route |
| `comments.routes.replies` / `post` / `reply` / `like` / `report` | Optional; **undeclared buttons are not rendered** |
| `comments.selectors` | `items` / `commentId` / `author` / `avatar` / `content` / `time` / `likeCount` / `replyCount` / `hasMore` / `success`, etc. |
| `comments.login.url` | WebView login-page URL when login is needed |
| `comments.login.checkCookie` | Presence of this cookie key means logged in |
| `comments.login.checkUrl` + `loggedInSelector` | Optional secondary probe |
| `comments.login.sendTokenAs` | Token carrier (login type): `null` cookie only / `bearer` → `Authorization: Bearer <cookie value of checkCookie>` / `key` → `Authorization: <authScheme> <manual key>` (**API key login**) |
| `comments.login.authScheme` | Only when `sendTokenAs==key`; `Authorization` prefix, default `Key` |
| `comments.login.apiKeyParam` | Only when `sendTokenAs==key`; key name in the local key store, default `apiKey` (stored as `sourceId:apiKeyParam`) |

**About the `version` import rule (pay attention)**:

- To release a new source version, simply bump `version` in the JSON;
- Importing a same-id source: version **≥ installed** → replace (upgrade / same-version re-import applies your edits); version **< installed** → skip, preventing an old version from clobbering the new one;
- Built-in sources cannot be overwritten; the "enabled / hidden" state is preserved on import.

**Debugging & importing**:

1. Use browser dev tools (F12) to verify the real page's HTML / JSON structure matches your selectors;
2. Import the JSON in the app via "Import source"; if parsing fails, check the JSON format (mind escaped quotes and newlines);
3. For script sources, use `context.log()` in overrides to print intermediate results;
4. First run one module (e.g. search) against a minimal dataset locally, then complete detail / video / images step by step;
5. Share: send the JSON file to friends or submit it to a community source repo — others import it with one tap.

**How to contribute**:

1. Write the source JSON on your own branch and import it into the app to verify scraping works;
2. To share, publish your source JSON through community channels (**do not submit sources to this app repo** — the repo only hosts the engine);
3. To improve the engine / readers / player / docs, file Issues and Pull Requests.

> Co-creation presumes **compliance and copyright respect**: only parse public content you have the right to access and that permits scraping; don't use sources to infringe others' lawful rights.

---

### 4.5.5 Writing 'You may also like'

"**You may also like**" is the recommendation block on the detail page. Adding it lets readers keep discovering without going back to search.

Three ways (pick per source type, can coexist):

1. **Recommendation route (recommended, works for anime / manga / novel)**: declare `recommend` (preferred) or `related` in `routes`; when the detail page opens the engine calls it with the `{id}` variable and renders the results as the block. If neither exists, the block is not rendered.
2. **Manga (mangaSource)**: add a `recommendations` object under `selectors.detail` with `list` / `title` / `cover` / `url` to extract the list straight from the detail page (used by the built-in GoDa, Komiic and FavComic sources).
3. **Novel (Legado)**: use `ruleBookInfo.recommendations` to extract recommended titles.

> Recommendations reuse the list parsing engine, with the same fields as `search` / `latest` (`id` / `title` / `cover` / `detailUrl`) — in most cases copying your `search` selectors just works.

```json
// Way 1 (generic): recommend route + selectors
{
  "routes": {
    "recommend": { "url": "/api/recommend?id={id}", "method": "get", "responseType": "json" }
  },
  "selectors": {
    "recommend": {
      "list": "$.list",
      "title": "$.vod_name",
      "cover": "$.vod_pic",
      "id": "$.vod_id"
    }
  }
}

// Way 2 (manga): selectors.detail.recommendations straight from the detail page
"detail": {
  "title": "h1.text-xl@text",
  "recommendations": {
    "list": ".recommend-list a[href^=\"/manga/\"]",
    "title": "h3@text",
    "cover": "img@src||data-src",
    "url": "@href"
  }
}
```

> The online tutorial (bilingual, with demos) is at [NexHub official site · Source-authoring tutorial](https://nexhub-app.github.io/website/), section 15.
## 4.6 Testing

```bash
flutter test
```

The test suite includes source JSON validation; with no built-in sources present, related cases auto-skip (fitting the open-source no-source model).
