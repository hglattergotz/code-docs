#!/bin/bash
# build-docs.sh - Convert markdown files from source code projects to HTML
#
# Usage:
#   build-docs.sh              Full rebuild of all docs + index
#   build-docs.sh --file X.md  Rebuild a single file + index
#   build-docs.sh --clean      Remove all output and rebuild

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Load configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
else
    echo "Error: $SCRIPT_DIR/.env not found. Copy .env.example to .env and configure." >&2
    exit 1
fi

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH"
_STYLE_SRC="$SCRIPT_DIR/style.html"
# Copy style to /tmp to avoid macOS Full Disk Access restrictions when
# pandoc is invoked by launchd (which lacks FDA for ~/Documents/).
STYLE_FILE="${TMPDIR:-/tmp}/code-docs-style.html"
cp "$_STYLE_SRC" "$STYLE_FILE" 2>/dev/null || STYLE_FILE="$_STYLE_SRC"

# Directories to skip
EXCLUDE_PATTERN='/(node_modules|\.git|vendor|__pycache__|\.venv|\.next|dist|\.cache|\.terraform)/'

# Sidebar display style: "flat" (file paths as flat links) or "tree" (nested folders)
SIDEBAR_STYLE="${SIDEBAR_STYLE:-tree}"

# Build system docs and dashboard
BUILD_SYSTEM_MD="$SCRIPT_DIR/build-system.md"
BUILD_SYSTEM_HTML="$OUTPUT_DIR/_build-system.html"
DASHBOARD_HTML="$OUTPUT_DIR/dashboard.html"

# --- Theme helpers (shared between dashboard and index) ---

# Emit CSS custom properties for light/dark theme.
# Usage: emit_theme_css_vars >> "$file"
emit_theme_css_vars() {
    cat << 'THEMEVARS'
  :root {
    --bg-body: #f8fafc;
    --bg-surface: white;
    --bg-code: #f1f5f9;
    --bg-thead: #f1f5f9;
    --bg-row-even: #f8fafc;
    --bg-blockquote: #eff6ff;
    --border-color: #e2e8f0;
    --border-blockquote: #bfdbfe;
    --border-blockquote-left: #2563eb;
    --text-primary: #0f172a;
    --text-body: #334155;
    --text-paragraph: #475569;
    --text-muted: #94a3b8;
    --text-code: #334155;
    --text-blockquote: #1e40af;
    --link-color: #2563eb;
    --hr-color: #e2e8f0;
    --img-border: #e2e8f0;
    --badge-green-bg: #dcfce7; --badge-green-fg: #166534;
    --badge-yellow-bg: #fef9c3; --badge-yellow-fg: #854d0e;
    --badge-orange-bg: #ffedd5; --badge-orange-fg: #9a3412;
    --badge-red-bg: #fecaca; --badge-red-fg: #991b1b;
    --fc-green-bg: #dcfce7; --fc-green-fg: #166534;
    --fc-yellow-bg: #fef9c3; --fc-yellow-fg: #854d0e;
    --fc-orange-bg: #ffedd5; --fc-orange-fg: #9a3412;
    --fc-red-bg: #fecaca; --fc-red-fg: #991b1b;
  }
  [data-theme="dark"] {
    --bg-body: #0f172a;
    --bg-surface: #1e293b;
    --bg-code: #1e293b;
    --bg-thead: #1e293b;
    --bg-row-even: #162032;
    --bg-blockquote: #1e293b;
    --border-color: #334155;
    --border-blockquote: #334155;
    --border-blockquote-left: #60a5fa;
    --text-primary: #e2e8f0;
    --text-body: #cbd5e1;
    --text-paragraph: #94a3b8;
    --text-muted: #64748b;
    --text-code: #cbd5e1;
    --text-blockquote: #93c5fd;
    --link-color: #60a5fa;
    --hr-color: #334155;
    --img-border: #334155;
    --badge-green-bg: #052e16; --badge-green-fg: #86efac;
    --badge-yellow-bg: #422006; --badge-yellow-fg: #fde047;
    --badge-orange-bg: #431407; --badge-orange-fg: #fdba74;
    --badge-red-bg: #450a0a; --badge-red-fg: #fca5a5;
    --fc-green-bg: #052e16; --fc-green-fg: #86efac;
    --fc-yellow-bg: #422006; --fc-yellow-fg: #fde047;
    --fc-orange-bg: #431407; --fc-orange-fg: #fdba74;
    --fc-red-bg: #450a0a; --fc-red-fg: #fca5a5;
  }
THEMEVARS
}

# Emit JS that reads theme from parent iframe and listens for changes.
# Usage: emit_theme_listener_script >> "$file"
emit_theme_listener_script() {
    cat << 'THEMESCRIPT'
<script>
(function() {
  var theme = 'light';
  try {
    var parentTheme = window.parent.document.documentElement.getAttribute('data-theme');
    if (parentTheme) theme = parentTheme;
  } catch(e) {}
  document.documentElement.setAttribute('data-theme', theme);
  window.addEventListener('message', function(e) {
    if (e.data && e.data.type === 'theme-change') {
      document.documentElement.setAttribute('data-theme', e.data.theme);
    }
  });
})();
</script>
THEMESCRIPT
}

find_md_files() {
    local exclude_projects_pattern=""
    if [[ -n "${EXCLUDE_PROJECTS:-}" ]]; then
        local joined
        joined=$(echo "$EXCLUDE_PROJECTS" | tr ' ' '|')
        exclude_projects_pattern="^${CODE_DIR}/(${joined})/"
    fi

    find "$CODE_DIR" -mindepth 2 -name "*.md" -type f 2>/dev/null \
      | grep -Ev "$EXCLUDE_PATTERN" \
      | if [[ -n "$exclude_projects_pattern" ]]; then grep -Ev "$exclude_projects_pattern"; else cat; fi \
      | sort -u
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
        -f markdown-tex_math_dollars -t html5 \
        -o "$html_path"
    echo "  Built: $rel_path"
}

cleanup_orphans() {
    local removed=0
    while IFS= read -r html_file; do
        local rel="${html_file#"$OUTPUT_DIR"/}"
        local md_file="$CODE_DIR/${rel%.html}.md"
        if [[ ! -f "$md_file" ]]; then
            rm -f "$html_file"
            removed=$((removed + 1))
            echo "  Removed orphan: $rel"
        fi
    done < <(find "$OUTPUT_DIR" -name "*.html" ! -name "index.html" ! -name "dashboard.html" ! -name "_build-system.html" -type f 2>/dev/null)

    # Remove empty directories (excluding output root)
    if [[ -d "$OUTPUT_DIR" ]]; then
        find "$OUTPUT_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi

    if [[ $removed -gt 0 ]]; then
        echo "  Cleaned up $removed orphan(s)"
    fi
}

cleanup_excluded_projects() {
    [[ -z "${EXCLUDE_PROJECTS:-}" ]] && return 0
    for project in $EXCLUDE_PROJECTS; do
        local project_dir="$OUTPUT_DIR/$project"
        if [[ -d "$project_dir" ]]; then
            rm -rf "$project_dir"
            echo "  Removed excluded project output: $project"
        fi
    done
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
        -f markdown-tex_math_dollars -t html5 \
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

    # Write dashboard HTML header with theme-aware CSS
    cat > "$DASHBOARD_HTML" << 'DASH_HEAD_TOP'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Dashboard</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cpath d='M6 2h12l8 8v18a2 2 0 01-2 2H6a2 2 0 01-2-2V4a2 2 0 012-2z' fill='%23e2e8f0' stroke='%2394a3b8' stroke-width='1.5'/%3E%3Cpath d='M18 2v6a2 2 0 002 2h6' fill='%23cbd5e1' stroke='%2394a3b8' stroke-width='1.5' stroke-linejoin='round'/%3E%3Cline x1='8' y1='15' x2='16' y2='15' stroke='%2394a3b8' stroke-width='1.5' stroke-linecap='round'/%3E%3Cline x1='8' y1='19' x2='14' y2='19' stroke='%2394a3b8' stroke-width='1.5' stroke-linecap='round'/%3E%3Cline x1='8' y1='23' x2='12' y2='23' stroke='%2394a3b8' stroke-width='1.5' stroke-linecap='round'/%3E%3Ccircle cx='22' cy='22' r='5' fill='white' stroke='%232563eb' stroke-width='2'/%3E%3Cline x1='25.5' y1='25.5' x2='30' y2='30' stroke='%232563eb' stroke-width='2.5' stroke-linecap='round'/%3E%3C/svg%3E">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
DASH_HEAD_TOP
    emit_theme_css_vars >> "$DASHBOARD_HTML"
    cat >> "$DASHBOARD_HTML" << 'DASH_HEAD_STYLE'
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: var(--bg-body);
    color: var(--text-body);
    line-height: 1.5;
    padding: 32px 48px;
  }
  h1 { font-size: 24px; font-weight: 700; color: var(--text-primary); margin-bottom: 4px; }
  .subtitle { font-size: 13px; color: var(--text-muted); margin-bottom: 24px; }
  h2 { font-size: 16px; font-weight: 600; color: var(--text-primary); margin: 32px 0 12px; }

  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 32px; }
  .card {
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    border-radius: 8px;
    padding: 16px;
  }
  .card .label { font-size: 11px; font-weight: 500; text-transform: uppercase; color: var(--text-muted); margin-bottom: 4px; }
  .card .value { font-size: 28px; font-weight: 700; color: var(--text-primary); }
  .card .detail { font-size: 11px; color: var(--text-muted); margin-top: 2px; }

  table { width: 100%; border-collapse: collapse; background: var(--bg-surface); border: 1px solid var(--border-color); border-radius: 8px; overflow: hidden; margin-bottom: 24px; }
  thead th { background: var(--bg-thead); font-weight: 600; color: var(--text-primary); text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
  th, td { padding: 10px 16px; border-bottom: 1px solid var(--border-color); font-size: 13px; }
  tbody tr:last-child td { border-bottom: none; }
  tbody tr:hover { background: var(--bg-row-even); }

  a { color: var(--link-color); text-decoration: none; cursor: pointer; }
  a:hover { text-decoration: underline; }

  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 11px;
    font-weight: 500;
  }
  .badge-green { background: var(--badge-green-bg); color: var(--badge-green-fg); }
  .badge-yellow { background: var(--badge-yellow-bg); color: var(--badge-yellow-fg); }
  .badge-orange { background: var(--badge-orange-bg); color: var(--badge-orange-fg); }
  .badge-red { background: var(--badge-red-bg); color: var(--badge-red-fg); }

  .freshness-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 32px; }
  .freshness-card {
    border-radius: 8px;
    padding: 14px;
    text-align: center;
  }
  .freshness-card .f-value { font-size: 24px; font-weight: 700; }
  .freshness-card .f-label { font-size: 11px; font-weight: 500; margin-top: 2px; }
  .fc-green { background: var(--fc-green-bg); color: var(--fc-green-fg); }
  .fc-yellow { background: var(--fc-yellow-bg); color: var(--fc-yellow-fg); }
  .fc-orange { background: var(--fc-orange-bg); color: var(--fc-orange-fg); }
  .fc-red { background: var(--fc-red-bg); color: var(--fc-red-fg); }
</style>
</head>
<body>
<h1>Documentation Dashboard</h1>
DASH_HEAD_STYLE

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

    emit_theme_listener_script >> "$DASHBOARD_HTML"
    echo '</body></html>' >> "$DASHBOARD_HTML"

    # Clean up metadata temp files
    rm -rf "$METADATA_DIR"
    echo "  Built: dashboard.html"
}

emit_sidebar_flat() {
    local index="$1"
    local tmp="$2"
    local current_project=""

    while IFS= read -r html_file; do
        local rel="${html_file#"$OUTPUT_DIR"/}"
        local project="${rel%%/*}"

        if [[ "$project" != "$current_project" ]]; then
            if [[ -n "$current_project" ]]; then
                echo "    </div>" >> "$index"
                echo "  </div>" >> "$index"
            fi
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

    if [[ -n "$current_project" ]]; then
        echo "    </div>" >> "$index"
        echo "  </div>" >> "$index"
    fi
}

emit_sidebar_tree() {
    local index="$1"
    local tmp="$2"
    local current_project=""
    # Directory stack tracks open folder names at each nesting level
    local dir_stack=()

    while IFS= read -r html_file; do
        local rel="${html_file#"$OUTPUT_DIR"/}"
        local project="${rel%%/*}"
        local within="${rel#"$project"/}"

        # New project — close previous project (all open folders + doc-list + project div)
        if [[ "$project" != "$current_project" ]]; then
            if [[ -n "$current_project" ]]; then
                # Close all open folders
                local k=${#dir_stack[@]}
                while [[ $k -gt 0 ]]; do
                    k=$((k - 1))
                    echo "      </div>" >> "$index"   # folder-list
                    echo "      </div>" >> "$index"   # folder
                done
                echo "    </div>" >> "$index"   # doc-list
                echo "  </div>" >> "$index"     # project
            fi
            dir_stack=()
            local doc_count
            doc_count=$(grep -c "^$OUTPUT_DIR/$project/" "$tmp" || true)
            echo "  <div class=\"project\" data-name=\"$project\">" >> "$index"
            echo "    <div class=\"project-name\" onclick=\"toggleProject(this)\"><span class=\"arrow\">&#9654;</span>$project<span class=\"count\">$doc_count</span></div>" >> "$index"
            echo "    <div class=\"doc-list\">" >> "$index"
            current_project="$project"
        fi

        # Split the within-project path into directory components and filename
        local file_dir=""
        local file_name="$within"
        if [[ "$within" == */* ]]; then
            file_dir="${within%/*}"
            file_name="${within##*/}"
        fi

        # Build array of directory components for this file
        local target_dirs=()
        if [[ -n "$file_dir" ]]; then
            IFS='/' read -ra target_dirs <<< "$file_dir"
        fi

        # Find common prefix length between dir_stack and target_dirs
        local common=0
        local stack_len=${#dir_stack[@]}
        local target_len=${#target_dirs[@]}
        while [[ $common -lt $stack_len && $common -lt $target_len ]]; do
            if [[ "${dir_stack[$common]}" == "${target_dirs[$common]}" ]]; then
                common=$((common + 1))
            else
                break
            fi
        done

        # Close folders that diverged (from deepest back to the divergence point)
        local close_from=$((stack_len - 1))
        while [[ $close_from -ge $common ]]; do
            echo "      </div>" >> "$index"   # folder-list
            echo "      </div>" >> "$index"   # folder
            close_from=$((close_from - 1))
        done

        # Trim the stack to the common prefix
        if [[ $common -eq 0 ]]; then
            dir_stack=()
        else
            dir_stack=("${dir_stack[@]:0:$common}")
        fi

        # Open new folders from the common prefix to the target
        local open_from=$common
        while [[ $open_from -lt $target_len ]]; do
            local folder_name="${target_dirs[$open_from]}"
            # Count files in this folder subtree
            local folder_prefix="$OUTPUT_DIR/$project/"
            local j=0
            while [[ $j -le $open_from ]]; do
                folder_prefix="${folder_prefix}${target_dirs[$j]}/"
                j=$((j + 1))
            done
            local folder_count
            folder_count=$(grep -c "^${folder_prefix}" "$tmp" || true)
            local pad_depth=$((open_from + 1))
            local pad_px=$(( pad_depth * 16 + 18 ))
            echo "      <div class=\"folder\" data-name=\"$folder_name\">" >> "$index"
            echo "        <div class=\"folder-name\" onclick=\"toggleFolder(this)\" style=\"padding-left: ${pad_px}px\"><span class=\"arrow\">&#9654;</span>$folder_name<span class=\"count\">$folder_count</span></div>" >> "$index"
            echo "        <div class=\"folder-list\">" >> "$index"
            dir_stack+=("$folder_name")
            open_from=$((open_from + 1))
        done

        # Emit the file link
        local depth=${#dir_stack[@]}
        local file_pad=$(( (depth + 1) * 16 + 18 ))
        echo "      <a class=\"doc-item\" onclick=\"loadDoc(this, '$rel')\" title=\"$within\" style=\"padding-left: ${file_pad}px\">$file_name</a>" >> "$index"
    done < "$tmp"

    # Close remaining open folders and last project
    if [[ -n "$current_project" ]]; then
        local k=${#dir_stack[@]}
        while [[ $k -gt 0 ]]; do
            k=$((k - 1))
            echo "      </div>" >> "$index"   # folder-list
            echo "      </div>" >> "$index"   # folder
        done
        echo "    </div>" >> "$index"   # doc-list
        echo "  </div>" >> "$index"     # project
    fi
}

build_index() {
    local index="$OUTPUT_DIR/index.html"
    local tmp
    tmp=$(mktemp)

    # Collect all html files grouped by project (exclude generated files)
    find "$OUTPUT_DIR" -name "*.html" ! -name "index.html" ! -name "dashboard.html" ! -name "_build-system.html" -type f | sort > "$tmp"
    # Also exclude _heartbeat.js from any processing (not HTML, but good hygiene)

    # Write index HTML header — split into parts to inject theme vars
    cat > "$index" << 'INDEX_HEAD_TOP'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Code Documentation</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cpath d='M6 2h12l8 8v18a2 2 0 01-2 2H6a2 2 0 01-2-2V4a2 2 0 012-2z' fill='%23e2e8f0' stroke='%2394a3b8' stroke-width='1.5'/%3E%3Cpath d='M18 2v6a2 2 0 002 2h6' fill='%23cbd5e1' stroke='%2394a3b8' stroke-width='1.5' stroke-linejoin='round'/%3E%3Cline x1='8' y1='15' x2='16' y2='15' stroke='%2394a3b8' stroke-width='1.5' stroke-linecap='round'/%3E%3Cline x1='8' y1='19' x2='14' y2='19' stroke='%2394a3b8' stroke-width='1.5' stroke-linecap='round'/%3E%3Cline x1='8' y1='23' x2='12' y2='23' stroke='%2394a3b8' stroke-width='1.5' stroke-linecap='round'/%3E%3Ccircle cx='22' cy='22' r='5' fill='white' stroke='%232563eb' stroke-width='2'/%3E%3Cline x1='25.5' y1='25.5' x2='30' y2='30' stroke='%232563eb' stroke-width='2.5' stroke-linecap='round'/%3E%3C/svg%3E">
<script>
// Set theme before first paint to prevent flash
(function() {
  var t = localStorage.getItem('code-docs-theme');
  if (!t) t = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', t);
})();
</script>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
INDEX_HEAD_TOP
    emit_theme_css_vars >> "$index"
    cat >> "$index" << 'INDEX_HEAD_STYLE'
  :root {
    --sidebar-bg: white;
    --sidebar-hover: #f1f5f9;
    --sidebar-active-bg: #eff6ff;
    --sidebar-active-color: #2563eb;
    --tool-bg: #eff6ff;
    --tool-border: #bfdbfe;
    --tool-color: #2563eb;
    --tool-hover-bg: #dbeafe;
    --search-bg: #f8fafc;
    --search-focus-bg: white;
    --count-bg: #f1f5f9;
    --doc-item-color: #64748b;
  }
  [data-theme="dark"] {
    --sidebar-bg: #1e293b;
    --sidebar-hover: #334155;
    --sidebar-active-bg: #1e3a5f;
    --sidebar-active-color: #60a5fa;
    --tool-bg: #1e293b;
    --tool-border: #334155;
    --tool-color: #60a5fa;
    --tool-hover-bg: #334155;
    --search-bg: #0f172a;
    --search-focus-bg: #1e293b;
    --count-bg: #334155;
    --doc-item-color: #94a3b8;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: var(--bg-body);
    color: var(--text-body);
    line-height: 1.5;
    height: 100vh;
    overflow: hidden;
    display: flex;
  }
  .sidebar {
    width: 280px;
    min-width: 280px;
    height: 100vh;
    background: var(--sidebar-bg);
    border-right: 1px solid var(--border-color);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .sidebar-header {
    padding: 20px 16px 12px;
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
  }
  .sidebar-header-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .sidebar-header h1 {
    font-size: 15px;
    font-weight: 700;
    color: var(--text-primary);
  }
  .sidebar-header .subtitle {
    font-size: 11px;
    color: var(--text-muted);
    margin-top: 2px;
  }
  .theme-toggle {
    background: none;
    border: 1px solid var(--border-color);
    border-radius: 6px;
    padding: 4px;
    cursor: pointer;
    color: var(--text-muted);
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    transition: all 0.15s;
    flex-shrink: 0;
  }
  .theme-toggle:hover { background: var(--sidebar-hover); color: var(--text-primary); }
  .theme-toggle svg { width: 16px; height: 16px; }
  .watcher-status {
    font-size: 11px;
    color: var(--text-muted);
    margin-top: 4px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .watcher-status-line {
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
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
  }
  .sidebar-search input {
    width: 100%;
    padding: 6px 10px;
    border: 1px solid var(--border-color);
    border-radius: 6px;
    font-size: 12px;
    font-family: inherit;
    color: var(--text-body);
    background: var(--search-bg);
    outline: none;
  }
  .sidebar-search input:focus { border-color: var(--sidebar-active-color); background: var(--search-focus-bg); }
  .sidebar-search input::placeholder { color: var(--text-muted); }
  .sidebar-tools {
    padding: 8px 12px;
    border-bottom: 1px solid var(--border-color);
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
    color: var(--tool-color);
    background: var(--tool-bg);
    border: 1px solid var(--tool-border);
    border-radius: 6px;
    cursor: pointer;
    text-decoration: none;
    transition: all 0.1s;
  }
  .sidebar-tools a:hover { background: var(--tool-hover-bg); }
  .sidebar-tools a.active { background: #2563eb; color: white; border-color: #2563eb; }
  [data-theme="dark"] .sidebar-tools a.active { background: #2563eb; color: white; border-color: #2563eb; }
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
    color: var(--text-primary);
    cursor: pointer;
    transition: background 0.1s;
  }
  .project-name:hover { background: var(--sidebar-hover); }
  .project-name.active { background: var(--sidebar-active-bg); color: var(--sidebar-active-color); }
  .project-name .arrow {
    font-size: 10px;
    color: var(--text-muted);
    transition: transform 0.15s;
    flex-shrink: 0;
    width: 12px;
  }
  .project-name.open .arrow { transform: rotate(90deg); }
  .project-name .count {
    margin-left: auto;
    font-size: 10px;
    font-weight: 500;
    color: var(--text-muted);
    background: var(--count-bg);
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
    color: var(--doc-item-color);
    text-decoration: none;
    cursor: pointer;
    transition: all 0.1s;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .doc-item:hover { background: var(--sidebar-hover); color: var(--text-body); }
  .doc-item.active { background: var(--sidebar-active-bg); color: var(--sidebar-active-color); font-weight: 500; }
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
    color: var(--text-muted);
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
  .folder { }
  .folder-name {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 16px;
    font-size: 12px;
    font-weight: 500;
    color: var(--text-body);
    cursor: pointer;
    transition: background 0.1s;
  }
  .folder-name:hover { background: var(--sidebar-hover); }
  .folder-name .arrow {
    font-size: 9px;
    color: var(--text-muted);
    transition: transform 0.15s;
    flex-shrink: 0;
    width: 10px;
  }
  .folder-name.open .arrow { transform: rotate(90deg); }
  .folder-name .count {
    margin-left: auto;
    font-size: 10px;
    font-weight: 500;
    color: var(--text-muted);
    background: var(--count-bg);
    padding: 1px 6px;
    border-radius: 8px;
  }
  .folder-list {
    display: none;
  }
  .folder-list.open { display: block; }
  .folder.hidden { display: none; }
</style>
</head>
<body>
<nav class="sidebar">
  <div class="sidebar-header">
    <div class="sidebar-header-top">
      <h1>Code Docs</h1>
      <button class="theme-toggle" id="themeToggle" onclick="toggleTheme()" title="Toggle dark/light mode" aria-label="Toggle dark/light mode">
        <svg id="iconSun" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M12 3v1m0 16v1m8.66-13.66l-.71.71M4.05 19.95l-.71.71M21 12h-1M4 12H3m16.66 7.66l-.71-.71M4.05 4.05l-.71-.71M16 12a4 4 0 11-8 0 4 4 0 018 0z"/></svg>
        <svg id="iconMoon" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" style="display:none"><path stroke-linecap="round" stroke-linejoin="round" d="M21.752 15.002A9.718 9.718 0 0112.478 3.21a9.72 9.72 0 109.274 11.792z"/></svg>
      </button>
    </div>
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
INDEX_HEAD_STYLE

    local project_count=0
    project_count=$(awk -F/ '{print $1}' <<< "$(while IFS= read -r f; do echo "${f#"$OUTPUT_DIR"/}"; done < "$tmp")" | sort -u | wc -l | tr -d ' ')

    if [[ "$SIDEBAR_STYLE" == "tree" ]]; then
        emit_sidebar_tree "$index" "$tmp"
    else
        emit_sidebar_flat "$index" "$tmp"
    fi

    cat >> "$index" << 'FOOTER'
  </div>
</nav>
<main class="content">
  <div class="content-placeholder" id="placeholder" style="display:none">Select a document from the sidebar</div>
  <iframe id="docFrame" src="about:blank" class="visible"></iframe>
</main>
<script>
// --- Theme toggle ---
function updateThemeIcon() {
  var isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  document.getElementById('iconSun').style.display = isDark ? 'none' : 'block';
  document.getElementById('iconMoon').style.display = isDark ? 'block' : 'none';
}
function sendThemeToIframe(theme) {
  var frame = document.getElementById('docFrame');
  if (frame && frame.contentWindow) {
    frame.contentWindow.postMessage({ type: 'theme-change', theme: theme }, '*');
  }
}
function toggleTheme() {
  var current = document.documentElement.getAttribute('data-theme') || 'light';
  var next = current === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next);
  localStorage.setItem('code-docs-theme', next);
  updateThemeIcon();
  sendThemeToIframe(next);
}
// Init icon state on load
updateThemeIcon();
// When iframe loads a new page, propagate current theme
document.getElementById('docFrame').addEventListener('load', function() {
  var theme = document.documentElement.getAttribute('data-theme') || 'light';
  sendThemeToIframe(theme);
});

// --- Navigation ---
function toggleProject(el) {
  var docList = el.nextElementSibling;
  el.classList.toggle('open');
  docList.classList.toggle('open');
}
function toggleFolder(el) {
  var folderList = el.nextElementSibling;
  el.classList.toggle('open');
  folderList.classList.toggle('open');
}
function loadIframe(path) {
  var frame = document.getElementById('docFrame');
  var placeholder = document.getElementById('placeholder');
  frame.src = path + '?t=' + Date.now();
  frame.classList.add('visible');
  placeholder.style.display = 'none';
  window.__currentDocPath = path;
}
function loadTool(el, path) {
  window.location.hash = path;
}
function loadDoc(el, path) {
  window.location.hash = path;
}

// Highlight the matching sidebar link for a given doc path
function highlightSidebarLink(path) {
  document.querySelectorAll('.doc-item.active').forEach(function(d) { d.classList.remove('active'); });
  document.querySelectorAll('.sidebar-tools a.active').forEach(function(a) { a.classList.remove('active'); });
  // Check tool links (dashboard, build system)
  var toolLinks = document.querySelectorAll('.sidebar-tools a');
  for (var i = 0; i < toolLinks.length; i++) {
    var onclick = toolLinks[i].getAttribute('onclick') || '';
    if (onclick.indexOf("'" + path + "'") !== -1) {
      toolLinks[i].classList.add('active');
      return;
    }
  }
  // Check doc links
  var docLinks = document.querySelectorAll('.doc-item');
  for (var i = 0; i < docLinks.length; i++) {
    var onclick = docLinks[i].getAttribute('onclick') || '';
    if (onclick.indexOf("'" + path + "'") !== -1) {
      docLinks[i].classList.add('active');
      // Walk up the DOM expanding parent folders and the parent project
      var node = docLinks[i].parentElement;
      while (node && !node.classList.contains('project-list')) {
        if (node.classList.contains('folder-list')) {
          if (!node.classList.contains('open')) node.classList.add('open');
          var folderNameEl = node.previousElementSibling;
          if (folderNameEl && folderNameEl.classList.contains('folder-name') && !folderNameEl.classList.contains('open')) {
            folderNameEl.classList.add('open');
          }
        }
        if (node.classList.contains('doc-list')) {
          if (!node.classList.contains('open')) node.classList.add('open');
          var projNameEl = node.previousElementSibling;
          if (projNameEl && projNameEl.classList.contains('project-name') && !projNameEl.classList.contains('open')) {
            projNameEl.classList.add('open');
          }
        }
        node = node.parentElement;
      }
      return;
    }
  }
}

// Hash change handler — single source of truth for navigation
function onHashChange() {
  var hash = window.location.hash.replace(/^#/, '');
  if (hash) {
    loadIframe(hash);
    highlightSidebarLink(hash);
  } else {
    loadIframe('dashboard.html');
    highlightSidebarLink('dashboard.html');
  }
}
window.addEventListener('hashchange', onHashChange);

// Initial load: read hash or default to dashboard
onHashChange();
document.getElementById('search').addEventListener('input', function() {
  var q = this.value.toLowerCase();
  document.querySelectorAll('.project').forEach(function(p) {
    var name = p.dataset.name.toLowerCase();
    var docs = p.querySelectorAll('.doc-item');
    var folders = p.querySelectorAll('.folder');
    var hasMatch = name.indexOf(q) !== -1;
    docs.forEach(function(d) {
      if (d.textContent.toLowerCase().indexOf(q) !== -1) hasMatch = true;
    });
    folders.forEach(function(f) {
      if (f.dataset.name && f.dataset.name.toLowerCase().indexOf(q) !== -1) hasMatch = true;
    });
    p.classList.toggle('hidden', !hasMatch);
  });
});

// --- Heartbeat & last rebuild ---
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
function checkStatus() {
  var el = document.getElementById('watcherStatus');
  // Load heartbeat
  delete window.__watcherHeartbeat;
  var s1 = document.createElement('script');
  s1.src = '_heartbeat.js?_=' + Date.now();
  s1.onload = function() {
    s1.remove();
    var hbTs = window.__watcherHeartbeat;
    var watcherActive = hbTs && (Math.floor(Date.now() / 1000) - hbTs) < 120;
    // Load last build timestamp
    delete window.__lastBuildTs;
    var s2 = document.createElement('script');
    s2.src = '_lastbuild.js?_=' + Date.now();
    s2.onload = function() {
      s2.remove();
      var buildTs = window.__lastBuildTs;
      renderStatus(el, watcherActive, buildTs);
    };
    s2.onerror = function() {
      s2.remove();
      renderStatus(el, watcherActive, null);
    };
    document.head.appendChild(s2);
  };
  s1.onerror = function() {
    s1.remove();
    renderStatus(el, false, null);
  };
  document.head.appendChild(s1);
}
function renderStatus(el, watcherActive, buildTs) {
  var lines = '';
  if (watcherActive) {
    lines += '<div class="watcher-status-line"><span class="watcher-dot active"></span>Watcher active</div>';
  } else {
    lines += '<div class="watcher-status-line"><span class="watcher-dot inactive"></span>Watcher inactive</div>';
  }
  if (buildTs) {
    var buildAge = Math.floor(Date.now() / 1000) - buildTs;
    lines += '<div class="watcher-status-line">Last rebuild: ' + timeAgo(buildAge) + '</div>';
  }
  el.innerHTML = lines;
}
checkStatus();
setInterval(checkStatus, 10000);

// --- Auto-reload on build changes ---
var __lastKnownBuildTs = null;
function checkForReload() {
  delete window.__lastBuildTs;
  var s = document.createElement('script');
  s.src = '_lastbuild.js?_=' + Date.now();
  s.onload = function() {
    s.remove();
    var ts = window.__lastBuildTs;
    if (!ts) return;
    if (__lastKnownBuildTs === null) {
      // First poll — just record, don't reload
      __lastKnownBuildTs = ts;
      return;
    }
    if (ts !== __lastKnownBuildTs) {
      __lastKnownBuildTs = ts;
      // Reload current iframe content with cache buster
      var frame = document.getElementById('docFrame');
      var currentPath = window.__currentDocPath || 'dashboard.html';
      frame.src = currentPath + '?t=' + Date.now();
    }
  };
  s.onerror = function() { s.remove(); };
  document.head.appendChild(s);
}
setInterval(checkForReload, 5000);

// Initial load handled by onHashChange() above
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
    local ts
    ts=$(date +%s)
    echo "window.__watcherHeartbeat = $ts;" > "$OUTPUT_DIR/_heartbeat.js"
    echo "window.__lastBuildTs = $ts;" > "$OUTPUT_DIR/_lastbuild.js"
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
        # Skip excluded projects
        if [[ -n "${EXCLUDE_PROJECTS:-}" ]]; then
            rel="${md_file#"$CODE_DIR"/}"
            project="${rel%%/*}"
            for excluded in $EXCLUDE_PROJECTS; do
                [[ "$project" == "$excluded" ]] && exit 0
            done
        fi
        build_file "$md_file"
        cleanup_orphans
        cleanup_excluded_projects
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
    cleanup_orphans
    cleanup_excluded_projects
    build_system_docs
    collect_metadata
    build_dashboard
    build_index
    write_heartbeat
    echo "Done."
fi
