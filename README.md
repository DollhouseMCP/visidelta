# VisiDelta

A visual old-vs-new diff tool for static websites.

It builds two versions of a site (`base` and `current`), then serves a browser UI for page-by-page rendered comparison with:

- Split and single-pane viewing
- Sidebar navigation across changed pages
- Add / delete / moved highlighting toggles
- Fuzzy moved-line detection to reduce false positives

## Why this exists

Git diffs are great for source-level review, but website changes often need rendered review. This tool gives you a fast workflow for that.

## Requirements

- `git`
- `docker` (default build path)
- `python3` (for local preview server)

## Quick start

Run from any repository you want to review (Jekyll default):

```bash
/path/to/visidelta/scripts/visidelta.sh origin/main /tmp/site-diff serve .
```

Open:

- `http://127.0.0.1:4310`

## Usage

```bash
visidelta.sh [BASE_REF] [OUT_DIR] [MODE] [TARGET_REPO]
```

- `BASE_REF`: Git ref to compare against (default `origin/main`)
- `OUT_DIR`: output directory for generated diff site (default `/tmp/visidelta`)
- `MODE`: `build` or `serve` (default `build`)
- `TARGET_REPO`: repo path to diff (default `.`)

## Custom build commands

For non-Jekyll sites, pass build commands with env vars:

```bash
BUILD_OLD_CMD='npm ci && npm run build && cp -R dist/. "$DEST_DIR"' \
BUILD_NEW_CMD='npm ci && npm run build && cp -R dist/. "$DEST_DIR"' \
./scripts/visidelta.sh origin/main /tmp/site-diff serve /path/to/repo
```

Available env vars inside build commands:

- `SRC_DIR`
- `DEST_DIR`
- `BASEURL` (`/old` or `/new`)

## Notes

- Changed pages are inferred from changed `*.md` files by default.
- Excludes include `README.md`, `LICENSE`, `docs/*`, `scripts/*`, `.github/*`.
- Add extra excludes with `EXTRA_EXCLUDE_GLOBS`.

## License

AGPL-3.0-or-later.
