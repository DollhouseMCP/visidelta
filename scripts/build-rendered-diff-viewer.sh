#!/usr/bin/env bash

set -euo pipefail

BASE_REF="${1:-origin/main}"
OUT_DIR="${2:-/tmp/visidelta}"
MODE="${3:-build}"
TARGET_REPO="${4:-.}"
PORT="${PORT:-4310}"

REPO_ROOT="$(git -C "$TARGET_REPO" rev-parse --show-toplevel)"
TMP_ROOT="$(mktemp -d /tmp/rsd.XXXXXX)"
MAIN_SRC="$TMP_ROOT/base-src"
OLD_DIR="$OUT_DIR/old"
NEW_DIR="$OUT_DIR/new"
ROUTES_FILE="$OUT_DIR/routes.json"
DIFF_DIR="$OUT_DIR/diffs"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$MAIN_SRC" "$OUT_DIR"
rm -rf "$OLD_DIR" "$NEW_DIR" "$DIFF_DIR"
mkdir -p "$OLD_DIR" "$NEW_DIR" "$DIFF_DIR"
# Docker images may run as a different UID than the host user.
# Keep output dirs writable for containerized static-site builds.
chmod -R a+rwx "$OLD_DIR" "$NEW_DIR"

echo "Exporting base ref '$BASE_REF' from $REPO_ROOT ..."
git -C "$REPO_ROOT" archive --format=tar "$BASE_REF" | tar -xf - -C "$MAIN_SRC"

build_with_default_jekyll() {
  local src_dir="$1"
  local dest_dir="$2"
  local label="$3"
  local baseurl="$4"
  local host_uid host_gid
  host_uid="$(id -u)"
  host_gid="$(id -g)"

  echo "Building $label site with jekyll/jekyll:pages ..."
  docker run --rm \
    -e HOST_UID="$host_uid" \
    -e HOST_GID="$host_gid" \
    -v "$src_dir":/srv/jekyll \
    -v "$dest_dir":/out \
    jekyll/jekyll:pages \
    sh -lc "jekyll build --source /srv/jekyll --destination /out --baseurl '$baseurl' --verbose >/dev/null && chown -R \"\$HOST_UID:\$HOST_GID\" /out || true"
}

build_with_cmd() {
  local src_dir="$1"
  local dest_dir="$2"
  local label="$3"
  local baseurl="$4"
  local cmd="$5"

  echo "Building $label site with custom command ..."
  (
    cd "$src_dir"
    SRC_DIR="$src_dir" DEST_DIR="$dest_dir" BASEURL="$baseurl" sh -lc "$cmd"
  )
}

build_site() {
  local src_dir="$1"
  local dest_dir="$2"
  local label="$3"
  local baseurl="$4"
  local cmd_override="$5"

  if [[ -n "$cmd_override" ]]; then
    build_with_cmd "$src_dir" "$dest_dir" "$label" "$baseurl" "$cmd_override"
  else
    build_with_default_jekyll "$src_dir" "$dest_dir" "$label" "$baseurl"
  fi
}

build_site "$MAIN_SRC" "$OLD_DIR" "base" "/old" "${BUILD_OLD_CMD:-}"
build_site "$REPO_ROOT" "$NEW_DIR" "current" "/new" "${BUILD_NEW_CMD:-${BUILD_OLD_CMD:-}}"

rewrite_prefixed_links_relative() {
  local site_dir="$1"
  local segment="$2"
  local needle="/${segment}/"

  while IFS= read -r -d '' html_file; do
    local dir rel prefix count i
    dir="$(dirname "$html_file")"
    if [[ "$dir" == "$site_dir" ]]; then
      prefix=""
    else
      rel="${dir#"$site_dir"/}"
      count="$(awk -F'/' '{print NF}' <<<"$rel")"
      prefix=""
      for ((i = 0; i < count; i += 1)); do
        prefix+="../"
      done
    fi
    NEEDLE="$needle" REPL="$prefix" perl -0pi -e 's/\Q$ENV{NEEDLE}\E/$ENV{REPL}/g;' "$html_file"
  done < <(grep -rIlZ -- "$needle" "$site_dir")
}

# Hosted previews often live under nested paths. Convert absolute /old/... and
# /new/... links to page-relative links so CSS and assets resolve correctly.
rewrite_prefixed_links_relative "$OLD_DIR" "old"
rewrite_prefixed_links_relative "$NEW_DIR" "new"

route_for_markdown() {
  local path="$1"
  if [[ "$path" == "index.md" ]]; then
    printf "/"
  elif [[ "$path" == */index.md ]]; then
    local dir="${path%/index.md}"
    printf "/%s/" "$dir"
  else
    local no_ext="${path%.md}"
    printf "/%s/" "$no_ext"
  fi
}

EXCLUDE_GLOBS=(README.md LICENSE LICENSING.md docs/* scripts/* .github/*)
if [[ -n "${EXTRA_EXCLUDE_GLOBS:-}" ]]; then
  # shellcheck disable=SC2206
  EXCLUDE_GLOBS+=( ${EXTRA_EXCLUDE_GLOBS} )
fi

is_excluded() {
  local file="$1"
  for glob in "${EXCLUDE_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    if [[ "$file" == $glob ]]; then
      return 0
    fi
  done
  return 1
}

CHANGED_MD=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if is_excluded "$line"; then
    continue
  fi
  CHANGED_MD+=("$line")
done < <(git -C "$REPO_ROOT" diff --name-only "$BASE_REF"...HEAD -- "*.md" | sort -u)

if [[ "${#CHANGED_MD[@]}" -eq 0 ]]; then
  CHANGED_MD=("index.md")
fi

{
  printf "[\n"
  for i in "${!CHANGED_MD[@]}"; do
    file="${CHANGED_MD[$i]}"
    route="$(route_for_markdown "$file")"
    id="$(printf "p%03d" $((i + 1)))"
    add_file="$DIFF_DIR/$id.add.txt"
    del_file="$DIFF_DIR/$id.del.txt"
    : >"$add_file"
    : >"$del_file"
    while IFS= read -r dline; do
      case "$dline" in
        "+++"*|"---"*|"@@"*)
          continue
          ;;
        "+"*)
          content="${dline#+}"
          [[ -n "${content// }" ]] && printf "%s\n" "$content" >>"$add_file"
          ;;
        "-"*)
          content="${dline#-}"
          [[ -n "${content// }" ]] && printf "%s\n" "$content" >>"$del_file"
          ;;
      esac
    done < <(git -C "$REPO_ROOT" diff --unified=0 "$BASE_REF"...HEAD -- "$file")
    awk '!seen[$0]++' "$add_file" >"$add_file.tmp" && mv "$add_file.tmp" "$add_file"
    awk '!seen[$0]++' "$del_file" >"$del_file.tmp" && mv "$del_file.tmp" "$del_file"
    comma=","
    if [[ "$i" -eq $(( ${#CHANGED_MD[@]} - 1 )) ]]; then
      comma=""
    fi
    printf "  {\"id\":\"%s\",\"file\":\"%s\",\"route\":\"%s\"}%s\n" "$id" "$file" "$route" "$comma"
  done
  printf "]\n"
} >"$ROUTES_FILE"

cat >"$OUT_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>VisiDelta</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 1.25rem; color: #111827; }
      h1 { margin: 0 0 0.5rem; }
      p { margin: 0 0 1rem; color: #374151; }
      table { border-collapse: collapse; width: 100%; max-width: 70rem; }
      th, td { border-bottom: 1px solid #e5e7eb; padding: 0.55rem; text-align: left; font-size: 0.95rem; }
      th { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; color: #6b7280; }
      a { color: #1d4ed8; text-decoration: none; margin-right: 0.65rem; }
      a:hover { text-decoration: underline; }
      code { background: #f3f4f6; padding: 0.08rem 0.28rem; border-radius: 0.25rem; }
    </style>
  </head>
  <body>
    <h1>VisiDelta</h1>
    <p>Compare <code>old</code> (base) vs <code>new</code> (current branch) as rendered pages.</p>
    <table>
      <thead>
        <tr>
          <th>Source file</th>
          <th>Route</th>
          <th>Links</th>
        </tr>
      </thead>
      <tbody id="rows"></tbody>
    </table>
    <script>
      fetch("./routes.json")
        .then((r) => r.json())
        .then((items) => {
          const tbody = document.getElementById("rows");
          for (const item of items) {
            const tr = document.createElement("tr");
            tr.innerHTML = `
              <td><code>${item.file}</code></td>
              <td><code>${item.route}</code></td>
              <td>
                <a href="./viewer.html?path=${encodeURIComponent(item.route)}" target="_blank" rel="noopener">Compare</a>
                <a href="./old${item.route}" target="_blank" rel="noopener">Old</a>
                <a href="./new${item.route}" target="_blank" rel="noopener">New</a>
              </td>
            `;
            tbody.appendChild(tr);
          }
        });
    </script>
  </body>
</html>
HTML

cat >"$OUT_DIR/viewer.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Rendered Page Compare</title>
    <style>
      :root { --line: #d1d5db; --bg: #f8fafc; --panel: #ffffff; --text: #111827; --muted: #4b5563; --accent: #1d4ed8; }
      * { box-sizing: border-box; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--text); background: var(--bg); }
      .app { display: grid; grid-template-columns: 18rem minmax(0, 1fr); height: 100vh; }
      .sidebar { border-right: 1px solid var(--line); background: var(--panel); padding: 0.8rem 0.7rem; overflow: auto; }
      .sidebar h1 { margin: 0 0 0.35rem; font-size: 1.02rem; }
      .sidebar p { margin: 0 0 0.7rem; font-size: 0.85rem; color: var(--muted); }
      .route-list { display: grid; gap: 0.35rem; }
      .route-item { width: 100%; border: 1px solid var(--line); background: #fff; border-radius: 0.35rem; text-align: left; padding: 0.45rem 0.5rem; cursor: pointer; }
      .route-item strong { display: block; font-size: 0.82rem; color: var(--text); line-height: 1.25; }
      .route-item span { display: block; margin-top: 0.14rem; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 0.76rem; color: var(--muted); }
      .route-item.active { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); background: #eff6ff; }
      .sidebar-links { margin-top: 0.75rem; border-top: 1px solid var(--line); padding-top: 0.6rem; font-size: 0.83rem; }
      .sidebar-links a { color: var(--accent); text-decoration: none; }
      .sidebar-links a:hover { text-decoration: underline; }
      .compare { min-width: 0; display: grid; grid-template-rows: auto auto 1fr; }
      .bar { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; padding: 0.65rem 0.8rem; border-bottom: 1px solid var(--line); background: #fff; position: sticky; top: 0; z-index: 2; }
      .bar strong { margin-right: 0.4rem; }
      .bar code { background: #eef2ff; padding: 0.12rem 0.35rem; border-radius: 0.28rem; }
      .btn { border: 1px solid var(--line); border-radius: 0.35rem; background: #fff; color: var(--text); padding: 0.25rem 0.5rem; cursor: pointer; font-size: 0.9rem; text-decoration: none; }
      .btn[disabled] { opacity: 0.45; cursor: not-allowed; }
      .btn.active { background: #1d4ed8; color: #fff; border-color: #1d4ed8; }
      .btn.toggle-on { background: #1d4ed8; color: #fff; border-color: #1d4ed8; }
      .diff-meta { color: var(--muted); font-size: 0.84rem; white-space: nowrap; }
      .page-meta { color: var(--muted); font-size: 0.84rem; white-space: nowrap; }
      .hint { margin-left: auto; color: var(--muted); font-size: 0.86rem; }
      .stage { display: grid; gap: 0; min-height: 0; }
      .stage.split { grid-template-columns: 1fr 1fr; }
      iframe { width: 100%; height: 100%; border: 0; background: #fff; }
      .single .new-pane, .single-old .new-pane, .single-new .old-pane { display: none; }
      .single .old-pane, .single-old .old-pane, .single-new .new-pane { display: block; }
      .labels { display: grid; grid-template-columns: 1fr 1fr; border-bottom: 1px solid var(--line); background: #fff; font-size: 0.8rem; color: var(--muted); }
      .labels > div { padding: 0.35rem 0.55rem; border-right: 1px solid var(--line); }
      .labels > div:last-child { border-right: 0; }
      .labels.hidden { display: none; }
      @media (max-width: 72rem) {
        .app { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
        .sidebar { border-right: 0; border-bottom: 1px solid var(--line); max-height: 14rem; }
      }
    </style>
  </head>
  <body>
    <div class="app">
      <aside class="sidebar">
        <h1>Changed Pages</h1>
        <p>Click any page to view rendered old/new versions.</p>
        <nav id="routeList" class="route-list"></nav>
        <div class="sidebar-links">
          <a href="./index.html">Open Table View</a>
        </div>
      </aside>
      <section class="compare">
        <div class="bar">
          <strong>Route</strong> <code id="route"></code>
          <button class="btn" id="prevBtn" type="button" title="Previous page (Left Arrow)">Prev</button>
          <button class="btn" id="nextBtn" type="button" title="Next page (Right Arrow)">Next</button>
          <span class="page-meta" id="pageMeta">Page 0 of 0</span>
          <button class="btn active" id="splitBtn" type="button">Split</button>
          <button class="btn" id="oldBtn" type="button">Old only</button>
          <button class="btn" id="newBtn" type="button">New only</button>
          <button class="btn" id="highlightBtn" type="button">Highlight changes</button>
          <button class="btn toggle-on" id="addBtn" type="button">Additions</button>
          <button class="btn toggle-on" id="delBtn" type="button">Deletions</button>
          <button class="btn" id="moveBtn" type="button">Moved</button>
          <span class="diff-meta" id="diffMeta">+0 / -0 / ~0</span>
          <a class="btn" id="oldLink" target="_blank" rel="noopener">Open Old</a>
          <a class="btn" id="newLink" target="_blank" rel="noopener">Open New</a>
          <span class="hint">Tip: side-by-side first, then switch to single view.</span>
        </div>
        <div id="labels" class="labels">
          <div>Old (base)</div>
          <div>New (current branch)</div>
        </div>
        <div id="stage" class="stage split">
          <iframe class="old-pane" id="oldFrame"></iframe>
          <iframe class="new-pane" id="newFrame"></iframe>
        </div>
      </section>
    </div>
    <script>
      const routeList = document.getElementById("routeList");
      const routeCode = document.getElementById("route");
      const oldFrame = document.getElementById("oldFrame");
      const newFrame = document.getElementById("newFrame");
      const oldLink = document.getElementById("oldLink");
      const newLink = document.getElementById("newLink");
      const prevBtn = document.getElementById("prevBtn");
      const nextBtn = document.getElementById("nextBtn");
      const pageMeta = document.getElementById("pageMeta");
      const stage = document.getElementById("stage");
      const labels = document.getElementById("labels");
      const splitBtn = document.getElementById("splitBtn");
      const oldBtn = document.getElementById("oldBtn");
      const newBtn = document.getElementById("newBtn");
      const highlightBtn = document.getElementById("highlightBtn");
      const addBtn = document.getElementById("addBtn");
      const delBtn = document.getElementById("delBtn");
      const moveBtn = document.getElementById("moveBtn");
      const diffMeta = document.getElementById("diffMeta");
      const allBtns = [splitBtn, oldBtn, newBtn];
      let pages = [];
      let currentRoute = "/";
      let currentPage = null;
      let currentAdds = [];
      let currentDels = [];
      let currentMoved = [];
      let highlightEnabled = false;
      let showAdds = true;
      let showDels = true;
      let showMoved = false;
      const diffCache = {};

      function currentIndex() {
        return pages.findIndex((p) => normalizeRoute(p.route) === currentRoute);
      }

      function refreshPageMeta() {
        if (!pages.length) {
          pageMeta.textContent = "Page 0 of 0";
          prevBtn.disabled = true;
          nextBtn.disabled = true;
          return;
        }
        const idx = currentIndex();
        const pageNum = idx >= 0 ? idx + 1 : 1;
        pageMeta.textContent = `Page ${pageNum} of ${pages.length}`;
        prevBtn.disabled = idx <= 0;
        nextBtn.disabled = idx < 0 || idx >= pages.length - 1;
      }

      function goRelative(delta) {
        const idx = currentIndex();
        if (idx < 0) return;
        const next = idx + delta;
        if (next < 0 || next >= pages.length) return;
        updateRoute(pages[next].route);
      }

      function normalizeRoute(path) {
        if (!path) return "/";
        const withLeading = path.startsWith("/") ? path : `/${path}`;
        return withLeading.endsWith("/") ? withLeading : `${withLeading}/`;
      }

      function normalizeText(str) {
        return (str || "").toLowerCase().replace(/\s+/g, " ").trim();
      }

      function canonicalForCompare(str) {
        return normalizeText(str)
          .replace(/[^a-z0-9 ]+/g, " ")
          .replace(/\s+/g, " ")
          .trim();
      }

      function cleanDiffLine(str) {
        let s = (str || "").trim();
        s = s.replace(/\[(.*?)\]\((.*?)\)/g, "$1");
        s = s.replace(/`+/g, "");
        s = s.replace(/^#{1,6}\s+/, "");
        s = s.replace(/^[-*+]\s+/, "");
        s = s.replace(/^\d+\.\s+/, "");
        s = s.replace(/<[^>]+>/g, " ");
        s = s.replace(/\s+/g, " ").trim();
        if (s.length < 10) return "";
        return s;
      }

      function tokenizeForCompare(str) {
        const canon = canonicalForCompare(str);
        if (!canon) return [];
        return canon.split(" ").filter(Boolean);
      }

      function overlapScore(a, b) {
        const aTokens = tokenizeForCompare(a);
        const bTokens = tokenizeForCompare(b);
        if (!aTokens.length || !bTokens.length) return 0;
        const bSet = new Set(bTokens);
        let common = 0;
        for (const token of aTokens) {
          if (bSet.has(token)) common += 1;
        }
        const denom = Math.max(aTokens.length, bTokens.length);
        return denom ? common / denom : 0;
      }

      function looksLikeMovedPair(addLine, delLine) {
        const addCanon = canonicalForCompare(cleanDiffLine(addLine));
        const delCanon = canonicalForCompare(cleanDiffLine(delLine));
        if (!addCanon || !delCanon) return false;
        if (addCanon === delCanon) return true;
        const minLen = Math.min(addCanon.length, delCanon.length);
        const maxLen = Math.max(addCanon.length, delCanon.length);
        const ratio = maxLen ? minLen / maxLen : 0;
        if (minLen >= 24 && ratio >= 0.72 && (addCanon.includes(delCanon) || delCanon.includes(addCanon))) {
          return true;
        }
        return ratio >= 0.72 && overlapScore(addCanon, delCanon) >= 0.78;
      }

      async function loadDiffForPage(page) {
        if (!page) return { additions: [], deletions: [] };
        if (diffCache[page.id]) return diffCache[page.id];
        const [addRaw, delRaw] = await Promise.all([
          fetch(`./diffs/${page.id}.add.txt`).then((r) => (r.ok ? r.text() : "")),
          fetch(`./diffs/${page.id}.del.txt`).then((r) => (r.ok ? r.text() : "")),
        ]);
        const additionsRaw = addRaw.split("\n").map(cleanDiffLine).filter(Boolean);
        const deletionsRaw = delRaw.split("\n").map(cleanDiffLine).filter(Boolean);
        const addMap = new Map();
        const delMap = new Map();
        additionsRaw.forEach((line) => {
          const norm = normalizeText(line);
          if (!norm) return;
          if (!addMap.has(norm)) addMap.set(norm, line);
        });
        deletionsRaw.forEach((line) => {
          const norm = normalizeText(line);
          if (!norm) return;
          if (!delMap.has(norm)) delMap.set(norm, line);
        });
        const moved = [];
        addMap.forEach((line, norm) => {
          if (delMap.has(norm)) {
            moved.push(line);
            addMap.delete(norm);
            delMap.delete(norm);
          }
        });

        const remainingAdds = Array.from(addMap.values());
        const remainingDels = Array.from(delMap.values());
        const consumedAdds = new Set();
        const consumedDels = new Set();
        for (let i = 0; i < remainingAdds.length; i += 1) {
          if (consumedAdds.has(i)) continue;
          const addLine = remainingAdds[i];
          let bestIdx = -1;
          let bestScore = 0;
          for (let j = 0; j < remainingDels.length; j += 1) {
            if (consumedDels.has(j)) continue;
            const delLine = remainingDels[j];
            if (!looksLikeMovedPair(addLine, delLine)) continue;
            const score = overlapScore(addLine, delLine);
            if (score > bestScore) {
              bestScore = score;
              bestIdx = j;
            }
          }
          if (bestIdx >= 0) {
            consumedAdds.add(i);
            consumedDels.add(bestIdx);
            moved.push(addLine);
          }
        }
        consumedAdds.forEach((idx) => {
          const key = normalizeText(remainingAdds[idx]);
          addMap.delete(key);
        });
        consumedDels.forEach((idx) => {
          const key = normalizeText(remainingDels[idx]);
          delMap.delete(key);
        });

        const additions = Array.from(addMap.values());
        const deletions = Array.from(delMap.values());
        diffCache[page.id] = { additions, deletions, moved };
        return diffCache[page.id];
      }

      function ensureFrameHighlightStyle(doc) {
        if (!doc || doc.getElementById("rsd-diff-style")) return;
        const style = doc.createElement("style");
        style.id = "rsd-diff-style";
        style.textContent = `
          .rsd-add-hl { box-shadow: inset 0 0 0 2px rgba(16, 185, 129, 0.45) !important; background: rgba(16, 185, 129, 0.12) !important; }
          .rsd-del-hl { box-shadow: inset 0 0 0 2px rgba(239, 68, 68, 0.45) !important; background: rgba(239, 68, 68, 0.12) !important; }
          .rsd-move-hl { box-shadow: inset 0 0 0 2px rgba(245, 158, 11, 0.45) !important; background: rgba(245, 158, 11, 0.12) !important; }
        `;
        doc.head.appendChild(style);
      }

      function clearFrameHighlights(frame) {
        const doc = frame.contentDocument;
        if (!doc) return;
        doc.querySelectorAll(".rsd-add-hl, .rsd-del-hl, .rsd-move-hl").forEach((el) => {
          el.classList.remove("rsd-add-hl");
          el.classList.remove("rsd-del-hl");
          el.classList.remove("rsd-move-hl");
        });
      }

      function applyLinesToFrame(frame, lines, className) {
        const doc = frame.contentDocument;
        if (!doc) return;
        ensureFrameHighlightStyle(doc);
        const snippets = lines.map((line) => normalizeText(cleanDiffLine(line))).filter((line) => line.length >= 10);
        if (!snippets.length) return;
        const targets = Array.from(doc.querySelectorAll("main p, main li, main h1, main h2, main h3, main h4, main h5, main h6, main td, main th, main blockquote, main figcaption"));
        targets.forEach((el) => {
          const text = normalizeText(el.innerText || "");
          if (!text) return;
          if (snippets.some((snippet) => text.includes(snippet))) {
            el.classList.add(className);
          }
        });
      }

      function refreshDiffMeta(addCount = currentAdds.length, delCount = currentDels.length, movedCount = currentMoved.length) {
        diffMeta.textContent = `+${addCount} / -${delCount} / ~${movedCount}`;
      }

      function classifyRenderedDiffLines() {
        const oldDoc = oldFrame.contentDocument;
        const newDoc = newFrame.contentDocument;
        if (!oldDoc || !newDoc || !oldDoc.body || !newDoc.body) {
          return { adds: currentAdds, dels: currentDels, moved: currentMoved };
        }

        const oldText = canonicalForCompare(oldDoc.body.innerText || "");
        const newText = canonicalForCompare(newDoc.body.innerText || "");
        const adds = [];
        const dels = [];
        const moved = [...currentMoved];

        currentAdds.forEach((line) => {
          const canon = canonicalForCompare(cleanDiffLine(line));
          if (canon && oldText.includes(canon)) moved.push(line);
          else adds.push(line);
        });

        currentDels.forEach((line) => {
          const canon = canonicalForCompare(cleanDiffLine(line));
          if (canon && newText.includes(canon)) moved.push(line);
          else dels.push(line);
        });

        const seen = new Set();
        const movedDeduped = [];
        moved.forEach((line) => {
          const key = canonicalForCompare(cleanDiffLine(line));
          if (!key || seen.has(key)) return;
          seen.add(key);
          movedDeduped.push(line);
        });

        return { adds, dels, moved: movedDeduped };
      }

      function applyHighlights() {
        clearFrameHighlights(oldFrame);
        clearFrameHighlights(newFrame);
        const classified = classifyRenderedDiffLines();
        refreshDiffMeta(classified.adds.length, classified.dels.length, classified.moved.length);
        if (!highlightEnabled) return;
        if (showDels) applyLinesToFrame(oldFrame, classified.dels, "rsd-del-hl");
        if (showAdds) applyLinesToFrame(newFrame, classified.adds, "rsd-add-hl");
        if (showMoved) {
          applyLinesToFrame(oldFrame, classified.moved, "rsd-move-hl");
          applyLinesToFrame(newFrame, classified.moved, "rsd-move-hl");
        }
      }

      function setToggle(btn, enabled) {
        btn.classList.toggle("toggle-on", enabled);
      }

      async function updateRoute(route) {
        currentRoute = normalizeRoute(route);
        const oldSrc = `./old${currentRoute}`;
        const newSrc = `./new${currentRoute}`;
        currentPage = pages.find((p) => normalizeRoute(p.route) === currentRoute) || null;
        routeCode.textContent = currentRoute;
        oldFrame.src = oldSrc;
        newFrame.src = newSrc;
        oldLink.href = oldSrc;
        newLink.href = newSrc;

        const url = new URL(window.location.href);
        url.searchParams.set("path", currentRoute);
        history.replaceState({}, "", url.toString());
        renderRouteList();
        refreshPageMeta();
        const diff = await loadDiffForPage(currentPage);
        currentAdds = diff.additions;
        currentDels = diff.deletions;
        currentMoved = diff.moved || [];
        refreshDiffMeta();
        applyHighlights();
      }

      function renderRouteList() {
        routeList.innerHTML = "";
        pages.forEach((item) => {
          const btn = document.createElement("button");
          btn.type = "button";
          btn.className = `route-item${normalizeRoute(item.route) === currentRoute ? " active" : ""}`;
          btn.innerHTML = `<strong>${item.file}</strong><span>${item.route}</span>`;
          btn.addEventListener("click", () => updateRoute(item.route));
          routeList.appendChild(btn);
        });
      }

      function setMode(mode) {
        stage.className = "stage";
        labels.className = "labels";
        allBtns.forEach((b) => b.classList.remove("active"));
        if (mode === "split") {
          stage.classList.add("split");
          splitBtn.classList.add("active");
          return;
        }
        labels.classList.add("hidden");
        if (mode === "old") {
          stage.classList.add("single-old");
          oldBtn.classList.add("active");
          return;
        }
        stage.classList.add("single-new");
        newBtn.classList.add("active");
      }

      splitBtn.addEventListener("click", () => setMode("split"));
      oldBtn.addEventListener("click", () => setMode("old"));
      newBtn.addEventListener("click", () => setMode("new"));
      highlightBtn.addEventListener("click", () => {
        highlightEnabled = !highlightEnabled;
        setToggle(highlightBtn, highlightEnabled);
        applyHighlights();
      });
      addBtn.addEventListener("click", () => {
        showAdds = !showAdds;
        setToggle(addBtn, showAdds);
        applyHighlights();
      });
      delBtn.addEventListener("click", () => {
        showDels = !showDels;
        setToggle(delBtn, showDels);
        applyHighlights();
      });
      moveBtn.addEventListener("click", () => {
        showMoved = !showMoved;
        setToggle(moveBtn, showMoved);
        applyHighlights();
      });
      prevBtn.addEventListener("click", () => goRelative(-1));
      nextBtn.addEventListener("click", () => goRelative(1));
      window.addEventListener("keydown", (event) => {
        if (event.defaultPrevented) return;
        if (event.altKey || event.ctrlKey || event.metaKey) return;
        const targetTag = (event.target && event.target.tagName) ? event.target.tagName.toLowerCase() : "";
        if (targetTag === "input" || targetTag === "textarea" || targetTag === "select") return;
        if (event.key === "ArrowLeft") {
          goRelative(-1);
        } else if (event.key === "ArrowRight") {
          goRelative(1);
        }
      });
      oldFrame.addEventListener("load", applyHighlights);
      newFrame.addEventListener("load", applyHighlights);

      fetch("./routes.json")
        .then((r) => r.json())
        .then((items) => {
          pages = items;
          const params = new URLSearchParams(window.location.search);
          const requested = normalizeRoute(params.get("path") || "/");
          const known = pages.some((p) => normalizeRoute(p.route) === requested);
          const fallback = pages.length ? normalizeRoute(pages[0].route) : "/";
          updateRoute(known ? requested : fallback);
          refreshDiffMeta();
        });
    </script>
  </body>
</html>
HTML

echo
echo "VisiDelta output generated at: $OUT_DIR"
echo "Base ref: $BASE_REF"
echo "Target repo: $REPO_ROOT"
echo "Changed markdown pages: ${#CHANGED_MD[@]}"
echo

if [[ "$MODE" == "serve" ]]; then
  echo "Starting viewer on http://127.0.0.1:$PORT ..."
  exec python3 -m http.server "$PORT" --directory "$OUT_DIR"
fi

echo "To serve manually:"
echo "  python3 -m http.server $PORT --directory $OUT_DIR"
