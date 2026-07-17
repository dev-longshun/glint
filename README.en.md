# Glint (custom fork)

English · [中文](README.md)

> **This is a fork of [chenbstack/glint](https://github.com/chenbstack/glint)** (this repo: `dev-longshun/glint`), not the upstream original.  
> Built for our own use and development. Upstream updates can be merged in, but **our local changes must be preserved** — never replace the tree with upstream wholesale. See `AGENTS.md` → “二开与上游同步”.

A macOS terminal for AI agents (SwiftUI + AppKit, [Ghostty](https://ghostty.org)). This fork also includes, for example:

- Grok agent integration and status art  
- Terminal accessibility fixes (so tools like Typeless can insert / select correctly)  
- Kaku/MUX0-style defaults (font, bar cursor, padding)  
- Auto DMG builds on push to `main` (GitHub Actions)

## Install (this fork)

Download the latest `Glint-*.dmg` from this repo’s [Releases](https://github.com/dev-longshun/glint/releases), mount it, and drag into Applications.

If Gatekeeper blocks an ad-hoc signed build:

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
```

> Official Homebrew / official Releases are **upstream** artifacts, not this fork. For stock Glint use [the upstream repo](https://github.com/chenbstack/glint).

## Dev & syncing upstream

```bash
# remotes
# origin   → this fork (dev-longshun/glint)
# upstream → official (chenbstack/glint)

git fetch upstream
git merge upstream/main --no-commit --no-ff
# resolve conflicts carefully; do not reset --hard to upstream
```

On conflicts: **prefer keeping our fork-only behavior**; take upstream-only new files; hand-merge shared hunks. Full rules in `AGENTS.md`.

## License

MIT — see [LICENSE](LICENSE).
