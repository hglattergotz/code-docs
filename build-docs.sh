#!/bin/bash
# build-docs.sh - Convert markdown files from ~/Documents/code/ projects to HTML
#
# Usage:
#   build-docs.sh              Full rebuild of all docs + index
#   build-docs.sh --file X.md  Rebuild a single file + index
#   build-docs.sh --clean      Remove all output and rebuild

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"

CODE_DIR="$HOME/Documents/code"
OUTPUT_DIR="$HOME/Documents/code-html"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STYLE_FILE="$SCRIPT_DIR/style.html"

# Directories to skip
EXCLUDE_PATTERN='/(node_modules|\.git|vendor|__pycache__|\.venv|\.next|dist|\.cache|\.terraform)/'

# Subdirectory names to scan for .md files (in addition to project root)
DOC_DIRS="docs docks doc"

# Build system docs and dashboard
BUILD_SYSTEM_MD="$SCRIPT_DIR/build-system.md"
BUILD_SYSTEM_HTML="$OUTPUT_DIR/_build-system.html"
DASHBOARD_HTML="$OUTPUT_DIR/dashboard.html"

find_md_files() {
    {
        # Root-level .md files in each project (depth 2 = code/project/file.md)
        find "$CODE_DIR" -maxdepth 2 -mindepth 2 -name "*.md" -type f 2>/dev/null

        # .md files inside doc directories (any depth within them)
        for dir in $DOC_DIRS; do
            find "$CODE_DIR" -path "*/$dir/*.md" -type f 2>/dev/null
        done
    } | grep -Ev "$EXCLUDE_PATTERN" || true | sort -u
}

build_file() {
    local md_file="$1"
    local rel_path="${md_file#"$CODE_DIR"/}"
    local html_path="$OUTPUT_DIR/${rel_path%.md}.html"
    local html_dir
    html_dir="$(dirname "$html_path")"

    # Skip if HTML is newer than both the MD file and the style
    if [[ -f "$html_path" && "$html_path" -nt "$md_file" && "$html_path" -nt "$STYLE_FILE" ]]; then
        return 0
    fi

    mkdir -p "$html_dir"

    # Compute relative path back to output root for the index link
    local depth
    depth=$(echo "$rel_path" | tr -cd '/' | wc -c | tr -d ' ')
    local back=""
    for ((i = 0; i < depth; i++)); do back="../$back"; done

    # Extract title from first H1, falling back to filename
    local title
    title=$(grep -m1 '^#[^#]' "$md_file" 2>/dev/null | sed 's/^#\s*//' || true)
    if [[ -z "$title" ]]; then
        title="$(basename "$md_file" .md)"
    fi

    # Convert markdown to HTML
    pandoc "$md_file" \
        --standalone \
        --include-in-header="$STYLE_FILE" \
        --metadata title="$title" \
        -f markdown -t html5 \
        -o "$html_path"
    echo "  Built: $rel_path"
}

build_system_docs() {
    mkdir -p "$OUTPUT_DIR"
    if [[ ! -f "$BUILD_SYSTEM_MD" ]]; then
        echo "  Warning: $BUILD_SYSTEM_MD not found, skipping"
        return 0
    fi
    pandoc "$BUILD_SYSTEM_MD" \
        --standalone \
        --include-in-header="$STYLE_FILE" \
        --metadata title="Build System" \
        -f markdown -t html5 \
        -o "$BUILD_SYSTEM_HTML"
    echo "  Built: _build-system.html"
}

collect_metadata() {
    local meta_dir
    meta_dir=$(mktemp -d)
    METADATA_DIR="$meta_dir"

    # Per-file metadata: project|rel_path|mtime|words
    local file_list="$meta_dir/files.tsv"
    : > "$file_list"

    find "$OUTPUT_DIR" -name "*.html" ! -name "index.html" ! -name "dashboard.html" ! -name "_build-system.html" -type f | sort | while IFS= read -r html_file; do
        local rel="${html_file#"$OUTPUT_DIR"/}"
        local project="${rel%%/*}"
        local md_file="$CODE_DIR/${rel%.html}.md"
        local mtime=0
        local words=0

        if [[ -f "$md_file" ]]; then
            mtime=$(stat -f "%m" "$md_file" 2>/dev/null || echo 0)
            words=$(wc -w < "$md_file" 2>/dev/null | tr -d ' ')
        fi

        printf '%s\t%s\t%s\t%s\n' "$project" "$rel" "$mtime" "$words" >> "$file_list"
    done

    # Per-project aggregates: project|doc_count|total_words|last_mtime
    local project_stats="$meta_dir/projects.tsv"
    awk -F'\t' '{
        p = $1; mt = $3+0; w = $4+0
        count[p]++
        total_words[p] += w
        if (mt > last_mt[p]) last_mt[p] = mt
    }
    END {
        for (p in count) {
            printf "%s\t%d\t%d\t%d\n", p, count[p], total_words[p], last_mt[p]
        }
    }' "$file_list" | sort -t$'\t' -k4 -rn > "$project_stats"

    echo "  Collected metadata for $(wc -l < "$file_list" | tr -d ' ') files"
}

build_dashboard() {
    local now
    now=$(date +%s)
    local build_date
    build_date=$(date "+%Y-%m-%d %H:%M")

    local file_list="$METADATA_DIR/files.tsv"
    local project_stats="$METADATA_DIR/projects.tsv"

    # Totals
    local total_projects
    total_projects=$(wc -l < "$project_stats" | tr -d ' ')
    local total_docs
    total_docs=$(wc -l < "$file_list" | tr -d ' ')
    local total_words
    total_words=$(awk -F'\t' '{s+=$4} END{print s+0}' "$file_list")

    # Freshness buckets
    local fresh=0 aging=0 stale=0 very_stale=0
    while IFS=$'\t' read -r _proj _rel mtime _words; do
        local age_days=$(( (now - mtime) / 86400 ))
        if [[ $age_days -lt 30 ]]; then
            fresh=$((fresh + 1))
        elif [[ $age_days -lt 180 ]]; then
            aging=$((aging + 1))
        elif [[ $age_days -lt 365 ]]; then
            stale=$((stale + 1))
        else
            very_stale=$((very_stale + 1))
        fi
    done < "$file_list"

    cat > "$DASHBOARD_HTML" << 'DASH_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Dashboard</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: #f8fafc;
    color: #334155;
    line-height: 1.5;
    padding: 32px 48px;
  }
  h1 { font-size: 24px; font-weight: 700; color: #0f172a; margin-bottom: 4px; }
  .subtitle { font-size: 13px; color: #94a3b8; margin-bottom: 24px; }
  h2 { font-size: 16px; font-weight: 600; color: #0f172a; margin: 32px 0 12px; }

  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 32px; }
  .card {
    background: white;
    border: 1px solid #e2e8f0;
    border-radius: 8px;
    padding: 16px;
  }
  .card .label { font-size: 11px; font-weight: 500; text-transform: uppercase; color: #94a3b8; margin-bottom: 4px; }
  .card .value { font-size: 28px; font-weight: 700; color: #0f172a; }
  .card .detail { font-size: 11px; color: #94a3b8; margin-top: 2px; }

  table { width: 100%; border-collapse: collapse; background: white; border: 1px solid #e2e8f0; border-radius: 8px; overflow: hidden; margin-bottom: 24px; }
  thead th { background: #f1f5f9; font-weight: 600; color: #0f172a; text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
  th, td { padding: 10px 16px; border-bottom: 1px solid #e2e8f0; font-size: 13px; }
  tbody tr:last-child td { border-bottom: none; }
  tbody tr:hover { background: #f8fafc; }

  a { color: #2563eb; text-decoration: none; cursor: pointer; }
  a:hover { text-decoration: underline; }

  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 11px;
    font-weight: 500;
  }
  .badge-green { background: #dcfce7; color: #166534; }
  .badge-yellow { background: #fef9c3; color: #854d0e; }
  .badge-orange { background: #ffedd5; color: #9a3412; }
  .badge-red { background: #fecaca; color: #991b1b; }

  .freshness-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 32px; }
  .freshness-card {
    border-radius: 8px;
    padding: 14px;
    text-align: center;
  }
  .freshness-card .f-value { font-size: 24px; font-weight: 700; }
  .freshness-card .f-label { font-size: 11px; font-weight: 500; margin-top: 2px; }
  .fc-green { background: #dcfce7; color: #166534; }
  .fc-yellow { background: #fef9c3; color: #854d0e; }
  .fc-orange { background: #ffedd5; color: #9a3412; }
  .fc-red { background: #fecaca; color: #991b1b; }
</style>
</head>
<body>
<h1>Documentation Dashboard</h1>
DASH_HEAD

    # Subtitle with build date
    echo "<div class=\"subtitle\">Last built: $build_date</div>" >> "$DASHBOARD_HTML"

    # Summary cards
    cat >> "$DASHBOARD_HTML" << CARDS
<div class="cards">
  <div class="card"><div class="label">Projects</div><div class="value">$total_projects</div></div>
  <div class="card"><div class="label">Documents</div><div class="value">$total_docs</div></div>
  <div class="card"><div class="label">Total Words</div><div class="value">$(printf "%'d" "$total_words")</div></div>
</div>
CARDS

    # Recently Modified Documents (top 10)
    echo '<h2>Recently Modified Documents</h2>' >> "$DASHBOARD_HTML"
    echo '<table><thead><tr><th>Document</th><th>Project</th><th>Modified</th><th>Age</th><th>Words</th></tr></thead><tbody>' >> "$DASHBOARD_HTML"

    sort -t$'\t' -k3 -rn "$file_list" | head -10 | while IFS=$'\t' read -r project rel mtime words; do
        local name="${rel#"$project"/}"
        local html_rel="$rel"
        local mod_date
        mod_date=$(date -r "$mtime" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
        local age_days=$(( (now - mtime) / 86400 ))
        local age_str
        if [[ $age_days -eq 0 ]]; then
            age_str="today"
        elif [[ $age_days -eq 1 ]]; then
            age_str="1 day"
        elif [[ $age_days -lt 30 ]]; then
            age_str="${age_days} days"
        elif [[ $age_days -lt 365 ]]; then
            age_str="$(( age_days / 30 )) months"
        else
            age_str="$(( age_days / 365 ))y $(( (age_days % 365) / 30 ))m"
        fi
        local badge_class="badge-green"
        if [[ $age_days -ge 365 ]]; then badge_class="badge-red"
        elif [[ $age_days -ge 180 ]]; then badge_class="badge-orange"
        elif [[ $age_days -ge 30 ]]; then badge_class="badge-yellow"
        fi
        echo "<tr><td><a onclick=\"parent.loadDoc(null, '$html_rel')\">$name</a></td><td>$project</td><td>$mod_date</td><td><span class=\"badge $badge_class\">$age_str</span></td><td>$words</td></tr>" >> "$DASHBOARD_HTML"
    done
    echo '</tbody></table>' >> "$DASHBOARD_HTML"

    # Projects by Recent Activity
    echo '<h2>Projects by Recent Activity</h2>' >> "$DASHBOARD_HTML"
    echo '<table><thead><tr><th>Project</th><th>Documents</th><th>Words</th><th>Last Modified</th><th>Status</th></tr></thead><tbody>' >> "$DASHBOARD_HTML"

    while IFS=$'\t' read -r project doc_count proj_words last_mtime; do
        local mod_date
        mod_date=$(date -r "$last_mtime" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
        local age_days=$(( (now - last_mtime) / 86400 ))
        local badge_class="badge-green" badge_label="Fresh"
        if [[ $age_days -ge 365 ]]; then
            badge_class="badge-red"; badge_label="Very Stale"
        elif [[ $age_days -ge 180 ]]; then
            badge_class="badge-orange"; badge_label="Stale"
        elif [[ $age_days -ge 30 ]]; then
            badge_class="badge-yellow"; badge_label="Aging"
        fi
        echo "<tr><td><strong>$project</strong></td><td>$doc_count</td><td>$(printf "%'d" "$proj_words")</td><td>$mod_date</td><td><span class=\"badge $badge_class\">$badge_label</span></td></tr>" >> "$DASHBOARD_HTML"
    done < "$project_stats"
    echo '</tbody></table>' >> "$DASHBOARD_HTML"

    # Document Freshness distribution
    cat >> "$DASHBOARD_HTML" << FRESHNESS
<h2>Document Freshness</h2>
<div class="freshness-cards">
  <div class="freshness-card fc-green"><div class="f-value">$fresh</div><div class="f-label">Fresh (&lt;30 days)</div></div>
  <div class="freshness-card fc-yellow"><div class="f-value">$aging</div><div class="f-label">Aging (30-180 days)</div></div>
  <div class="freshness-card fc-orange"><div class="f-value">$stale</div><div class="f-label">Stale (180-365 days)</div></div>
  <div class="freshness-card fc-red"><div class="f-value">$very_stale</div><div class="f-label">Very Stale (&gt;1 year)</div></div>
</div>
FRESHNESS

    echo '</body></html>' >> "$DASHBOARD_HTML"

    # Clean up metadata temp files
    rm -rf "$METADATA_DIR"
    echo "  Built: dashboard.html"
}

build_index() {
    local index="$OUTPUT_DIR/index.html"
    local tmp
    tmp=$(mktemp)

    # Collect all html files grouped by project (exclude generated files)
    find "$OUTPUT_DIR" -name "*.html" ! -name "index.html" ! -name "dashboard.html" ! -name "_build-system.html" -type f | sort > "$tmp"
    # Also exclude _heartbeat.js from any processing (not HTML, but good hygiene)

    cat > "$index" << 'HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Code Documentation</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: #f8fafc;
    color: #334155;
    line-height: 1.5;
    height: 100vh;
    overflow: hidden;
    display: flex;
  }
  .sidebar {
    width: 280px;
    min-width: 280px;
    height: 100vh;
    background: white;
    border-right: 1px solid #e2e8f0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .sidebar-header {
    padding: 20px 16px 12px;
    border-bottom: 1px solid #e2e8f0;
    flex-shrink: 0;
  }
  .sidebar-header h1 {
    font-size: 15px;
    font-weight: 700;
    color: #0f172a;
  }
  .sidebar-header .subtitle {
    font-size: 11px;
    color: #94a3b8;
    margin-top: 2px;
  }
  .watcher-status {
    font-size: 11px;
    color: #94a3b8;
    margin-top: 4px;
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .watcher-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .watcher-dot.active { background: #22c55e; }
  .watcher-dot.inactive { background: #ef4444; }
  .sidebar-search {
    padding: 8px 12px;
    border-bottom: 1px solid #e2e8f0;
    flex-shrink: 0;
  }
  .sidebar-search input {
    width: 100%;
    padding: 6px 10px;
    border: 1px solid #e2e8f0;
    border-radius: 6px;
    font-size: 12px;
    font-family: inherit;
    color: #334155;
    background: #f8fafc;
    outline: none;
  }
  .sidebar-search input:focus { border-color: #2563eb; background: white; }
  .sidebar-search input::placeholder { color: #94a3b8; }
  .sidebar-tools {
    padding: 8px 12px;
    border-bottom: 1px solid #e2e8f0;
    flex-shrink: 0;
    display: flex;
    gap: 8px;
  }
  .sidebar-tools a {
    flex: 1;
    display: block;
    padding: 6px 0;
    text-align: center;
    font-size: 11px;
    font-weight: 600;
    color: #2563eb;
    background: #eff6ff;
    border: 1px solid #bfdbfe;
    border-radius: 6px;
    cursor: pointer;
    text-decoration: none;
    transition: all 0.1s;
  }
  .sidebar-tools a:hover { background: #dbeafe; }
  .sidebar-tools a.active { background: #2563eb; color: white; border-color: #2563eb; }
  .project-list {
    flex: 1;
    overflow-y: auto;
    padding: 4px 0;
  }
  .project {
    user-select: none;
  }
  .project-name {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 16px;
    font-size: 13px;
    font-weight: 600;
    color: #0f172a;
    cursor: pointer;
    transition: background 0.1s;
  }
  .project-name:hover { background: #f1f5f9; }
  .project-name.active { background: #eff6ff; color: #2563eb; }
  .project-name .arrow {
    font-size: 10px;
    color: #94a3b8;
    transition: transform 0.15s;
    flex-shrink: 0;
    width: 12px;
  }
  .project-name.open .arrow { transform: rotate(90deg); }
  .project-name .count {
    margin-left: auto;
    font-size: 10px;
    font-weight: 500;
    color: #94a3b8;
    background: #f1f5f9;
    padding: 1px 6px;
    border-radius: 8px;
  }
  .doc-list {
    display: none;
    padding: 2px 0 4px 0;
  }
  .doc-list.open { display: block; }
  .doc-item {
    display: block;
    padding: 4px 16px 4px 34px;
    font-size: 12px;
    color: #64748b;
    text-decoration: none;
    cursor: pointer;
    transition: all 0.1s;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .doc-item:hover { background: #f1f5f9; color: #334155; }
  .doc-item.active { background: #eff6ff; color: #2563eb; font-weight: 500; }
  .content {
    flex: 1;
    height: 100vh;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .content-placeholder {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    color: #94a3b8;
    font-size: 14px;
  }
  .content iframe {
    flex: 1;
    width: 100%;
    border: none;
    display: none;
  }
  .content iframe.visible { display: block; }
  .project.hidden { display: none; }
</style>
</head>
<body>
<nav class="sidebar">
  <div class="sidebar-header">
    <h1>Code Docs</h1>
    <div class="subtitle">PROJECTCOUNT projects</div>
    <div class="watcher-status" id="watcherStatus"></div>
  </div>
  <div class="sidebar-search">
    <input type="text" id="search" placeholder="Filter projects..." autocomplete="off">
  </div>
  <div class="sidebar-tools">
    <a class="active" id="toolDashboard" onclick="loadTool(this, 'dashboard.html')">Dashboard</a>
    <a id="toolBuildSystem" onclick="loadTool(this, '_build-system.html')">Build System</a>
  </div>
  <div class="project-list" id="projectList">
HEADER

    local current_project=""
    local project_count=0

    while IFS= read -r html_file; do
        local rel="${html_file#"$OUTPUT_DIR"/}"
        local project="${rel%%/*}"

        if [[ "$project" != "$current_project" ]]; then
            if [[ -n "$current_project" ]]; then
                echo "    </div>" >> "$index"
                echo "  </div>" >> "$index"
            fi
            project_count=$((project_count + 1))
            # Count docs for this project
            local doc_count
            doc_count=$(grep -c "^$OUTPUT_DIR/$project/" "$tmp" || true)
            echo "  <div class=\"project\" data-name=\"$project\">" >> "$index"
            echo "    <div class=\"project-name\" onclick=\"toggleProject(this)\"><span class=\"arrow\">&#9654;</span>$project<span class=\"count\">$doc_count</span></div>" >> "$index"
            echo "    <div class=\"doc-list\">" >> "$index"
            current_project="$project"
        fi

        local name="${rel#"$project"/}"
        echo "      <a class=\"doc-item\" onclick=\"loadDoc(this, '$rel')\" title=\"$name\">$name</a>" >> "$index"
    done < "$tmp"

    # Close last project if we had any
    if [[ -n "$current_project" ]]; then
        echo "    </div>" >> "$index"
        echo "  </div>" >> "$index"
    fi

    cat >> "$index" << 'FOOTER'
  </div>
</nav>
<main class="content">
  <div class="content-placeholder" id="placeholder" style="display:none">Select a document from the sidebar</div>
  <iframe id="docFrame" src="dashboard.html" class="visible"></iframe>
</main>
<script>
function toggleProject(el) {
  const docList = el.nextElementSibling;
  const wasOpen = el.classList.contains('open');
  el.classList.toggle('open');
  docList.classList.toggle('open');
}
function loadTool(el, path) {
  document.querySelectorAll('.sidebar-tools a.active').forEach(a => a.classList.remove('active'));
  document.querySelectorAll('.doc-item.active').forEach(d => d.classList.remove('active'));
  if (el) el.classList.add('active');
  const frame = document.getElementById('docFrame');
  const placeholder = document.getElementById('placeholder');
  frame.src = path;
  frame.classList.add('visible');
  placeholder.style.display = 'none';
}
function loadDoc(el, path) {
  document.querySelectorAll('.doc-item.active').forEach(d => d.classList.remove('active'));
  document.querySelectorAll('.sidebar-tools a.active').forEach(a => a.classList.remove('active'));
  if (el) el.classList.add('active');
  const frame = document.getElementById('docFrame');
  const placeholder = document.getElementById('placeholder');
  frame.src = path;
  frame.classList.add('visible');
  placeholder.style.display = 'none';
}
document.getElementById('search').addEventListener('input', function() {
  const q = this.value.toLowerCase();
  document.querySelectorAll('.project').forEach(p => {
    const name = p.dataset.name.toLowerCase();
    const docs = p.querySelectorAll('.doc-item');
    let hasMatch = name.includes(q);
    docs.forEach(d => {
      if (d.textContent.toLowerCase().includes(q)) hasMatch = true;
    });
    p.classList.toggle('hidden', !hasMatch);
  });
});
function timeAgo(seconds) {
  if (seconds < 60) return 'just now';
  var m = Math.floor(seconds / 60);
  if (m < 60) return m + (m === 1 ? ' minute ago' : ' minutes ago');
  var h = Math.floor(m / 60);
  var rm = m % 60;
  if (h < 24) {
    var s = h + (h === 1 ? ' hour' : ' hours');
    if (rm > 0) s += ' and ' + rm + (rm === 1 ? ' minute' : ' minutes');
    return s + ' ago';
  }
  var d = Math.floor(h / 24);
  return d + (d === 1 ? ' day ago' : ' days ago');
}
function checkHeartbeat() {
  var el = document.getElementById('watcherStatus');
  delete window.__watcherHeartbeat;
  var s = document.createElement('script');
  s.src = '_heartbeat.js?_=' + Date.now();
  s.onload = function() {
    s.remove();
    var ts = window.__watcherHeartbeat;
    if (!ts) { showInactive(el); return; }
    var age = Math.floor(Date.now() / 1000) - ts;
    if (age < 120) {
      el.innerHTML = '<span class="watcher-dot active"></span>Watcher active &middot; last rebuild ' + timeAgo(age);
    } else {
      showInactive(el);
    }
  };
  s.onerror = function() { s.remove(); showInactive(el); };
  document.head.appendChild(s);
}
function showInactive(el) {
  el.innerHTML = '<span class="watcher-dot inactive"></span>Watcher inactive';
}
checkHeartbeat();
setInterval(checkHeartbeat, 10000);
</script>
</body>
</html>
FOOTER

    # Replace the project count placeholder
    if command -v sed &>/dev/null; then
        sed -i '' "s/PROJECTCOUNT/$project_count/" "$index"
    fi

    rm -f "$tmp"
    echo "  Built: index.html"
}

write_heartbeat() {
    mkdir -p "$OUTPUT_DIR"
    echo "window.__watcherHeartbeat = $(date +%s);" > "$OUTPUT_DIR/_heartbeat.js"
}

# --- Main ---

if [[ "${1:-}" == "--clean" ]]; then
    echo "Cleaning $OUTPUT_DIR..."
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    echo "Running full build..."
    find_md_files | while IFS= read -r f; do
        build_file "$f"
    done
    build_system_docs
    collect_metadata
    build_dashboard
    build_index
    write_heartbeat
    echo "Done."

elif [[ "${1:-}" == "--file" && -n "${2:-}" ]]; then
    md_file="$2"
    # Only build if it's a .md file under CODE_DIR
    if [[ "$md_file" == "$CODE_DIR"/* && "$md_file" == *.md ]]; then
        build_file "$md_file"
        build_system_docs
        collect_metadata
        build_dashboard
        build_index
        write_heartbeat
    fi

else
    echo "Building all docs..."
    find_md_files | while IFS= read -r f; do
        build_file "$f"
    done
    build_system_docs
    collect_metadata
    build_dashboard
    build_index
    write_heartbeat
    echo "Done."
fi
