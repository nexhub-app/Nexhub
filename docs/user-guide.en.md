**English** | [简体中文](./user-guide.md)

# 🧭 User Guide

> This guide is for end users: how to install, import sources, use daily, and FAQs. For highlights see [Core Features](features.en.md); for writing sources see the [Developer Guide](developer-guide.en.md).

## 3.1 Getting & installing

- **Use prebuilt packages**: download the package for your platform (e.g. Android APK, Windows installer) from the project's Releases page. See the repository Releases for the exact channels.
- **Build from source**: see [Developer Guide · Environment & Build](developer-guide.en.md#41-environment) (recommended for developers).

## 3.2 First launch & importing sources (critical)

Because the app **ships with no sources**, it's empty on first launch — you must import sources yourself:

1. Find the "Source management / Import source" entry in the app;
2. Paste a source JSON, or pick a local source JSON file;
3. Once imported, that source's site content appears in Home / Categories for browsing — **no app-code changes needed**.

> What does a source JSON look like, and what fields does it have? See [Developer Guide · Source Authoring Tutorial](developer-guide.en.md#45-source-as-plugin-how-to-write-and-contribute-a-source).

## 3.3 Daily use

- **Browse / search**: browse Home or Categories; use search with keywords;
- **Read / watch**: tap into a detail page, pick a chapter to read manga / novel, or play video (with danmaku, multi-line, sniffer fallback);
- **Download**: use offline downloads for interesting content so it's available without a network;
- **Filter**: some sources provide tag / category filters for quick targeting;
- **Collection groups / ratings / comments**: add favorite entries to groups, give local ratings and short comments, and join site comments on supported sources;
- **Bangumi sync**: optionally log in to a Bangumi account to sync collections / progress / ratings;
- **Network config**: adjust proxy, DNS, Hosts, etc. in Settings when connections fail or a proxy is needed (per-source override supported).

## 3.4 FAQ

- **Why can't I see any content?** Most likely you haven't imported a source yet. Import at least one source per 3.2 first.
- **Still blank after importing a source?** Check whether the source fits the current network environment, or whether the site needs login state / anti-scraping handling (ask the source author to update the source script).
- **No sources in the repo — where do I find them?** Sources are shared and maintained by the community; get them through community channels and evaluate their compliance and content legality yourself.
- **Some content is not shown?** The app enables age rating by default; `mature` (18+) sources are hidden by default. To show them, enable "restricted content" in Settings and confirm it complies with your local laws and age.
