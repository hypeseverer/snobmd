#!/bin/bash
set -euo pipefail

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { echo "[SnobMD] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a /config/watcher.log; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*" >&2; echo "[SnobMD] $(date '+%Y-%m-%d %H:%M:%S') ERROR $*" >> /config/watcher.log; }

# ── Validate required env vars ────────────────────────────────────────────────
: "${OLLAMA_BASE_URL:?OLLAMA_BASE_URL must be set}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL must be set}"
: "${INPUT_DIR:?INPUT_DIR must be set}"
: "${OUTPUT_DIR:?OUTPUT_DIR must be set}"

# ── Generate sn2md config from env vars ───────────────────────────────────────
CONFIG_FILE="/config/sn2md.toml"
info "Writing sn2md config to ${CONFIG_FILE}"

# Escape double quotes in the prompt for TOML multi-line string
ESCAPED_PROMPT=$(printf '%s' "${SN2MD_PROMPT}" | sed 's/"""/\"\"\"/g')

cat > "${CONFIG_FILE}" <<TOML
model = "${OLLAMA_MODEL}"
output_filename_template = "${OUTPUT_FILENAME_TEMPLATE}"
output_path_template = "${OUTPUT_PATH_TEMPLATE}"

prompt = """${ESCAPED_PROMPT}"""
TOML

info "Config written:"
cat "${CONFIG_FILE}"

# ── Start Web UI ──────────────────────────────────────────────────────────
if [[ "${WEBUI_ENABLED:-true}" == "true" ]]; then
    info "Starting admin Web UI on port ${WEBUI_PORT:-8090}..."
    node /webui/server.js >> /config/webui.log 2>&1 &
    WEBUI_PID=$!
    info "Web UI PID: ${WEBUI_PID}"
fi

# ── Point llm-ollama at the correct Ollama instance ──────────────────────────
export OLLAMA_HOST="${OLLAMA_BASE_URL}"
info "Ollama base URL: ${OLLAMA_BASE_URL}"
info "Ollama model:    ${OLLAMA_MODEL}"

# ── Wait for Ollama to be reachable ──────────────────────────────────────────
info "Waiting for Ollama to be available..."
until curl -sf "${OLLAMA_BASE_URL}/api/tags" > /dev/null 2>&1; do
    warn "Ollama not yet reachable at ${OLLAMA_BASE_URL}, retrying in 5s..."
    sleep 5
done
info "Ollama is up."

# ── Tag generation function ───────────────────────────────────────────────────
tag_file() {
    local mdfile="$1"
    local tag_model="${TAG_MODEL:-qwen3:4b}"

    if [[ "${TAGGING_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    info "Generating tags for: ${mdfile}"

    # Use Python to safely build and send the JSON payload — avoids shell
    # escaping issues with quotes, newlines, and special characters in content
    local response
    response=$(python3 - <<PYEOF
import json, urllib.request, sys

with open("${mdfile}", "r") as f:
    content = f.read()

payload = json.dumps({
    "model": "${tag_model}",
    "prompt": (
        "Read the following markdown note and return a list of relevant Obsidian tags "
        "based on the content. Return ONLY tags, one per line, in lowercase with hyphens "
        "instead of spaces, prefixed with #. No explanation, no preamble, no other text.\n\n"
        "Note content:\n" + content
    ),
    "stream": False
}).encode("utf-8")

req = urllib.request.Request(
    "${OLLAMA_BASE_URL}/api/generate",
    data=payload,
    headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.loads(resp.read().decode("utf-8"))
        print(result.get("response", ""))
except Exception as e:
    print("", file=sys.stderr)
    sys.exit(1)
PYEOF
)

    if [[ -z "${response}" ]]; then
        warn "No response from Ollama for tagging, skipping."
        return 0
    fi

    # Build YAML frontmatter from tag lines
    local frontmatter
    frontmatter="---\ntags:"
    while IFS= read -r line; do
        local tag
        tag=$(echo "${line}" | sed 's/^#*//' | tr -d '[:space:]')
        if [[ -n "${tag}" ]]; then
            frontmatter="${frontmatter}\n  - ${tag}"
        fi
    done <<< "${response}"
    frontmatter="${frontmatter}\n---\n"

    # Prepend frontmatter to the markdown file
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s' "${frontmatter}" > "${tmpfile}"
    cat "${mdfile}" >> "${tmpfile}"
    mv "${tmpfile}" "${mdfile}"

    info "Tags added to: ${mdfile}"
}

# ── Clean up MD file after conversion ────────────────────────────────────────
clean_md() {
    local mdfile="$1"
    python3 - <<PYEOF
import re

path = """${mdfile}"""
with open(path, 'r') as f:
    content = f.read()

# Remove duplicate YAML frontmatter blocks — keep only the last one
# sn2md adds its own frontmatter, and tag_file prepends another
frontmatter_blocks = list(re.finditer(r'^---\n.*?^---\n', content, re.DOTALL | re.MULTILINE))
if len(frontmatter_blocks) > 1:
    last = frontmatter_blocks[-1]
    content = content[last.start():]

# Remove the # Images section (stops at next # heading or end of file)
content = re.sub(r'\n# Images\n.*?(?=\n# |\Z)', '', content, flags=re.DOTALL)

with open(path, 'w') as f:
    f.write(content)
PYEOF
}

# ── Conversion function ───────────────────────────────────────────────────────
convert_file() {
    local filepath="$1"
    local basename
    basename=$(basename "${filepath}" .note)

    # Strip INPUT_DIR prefix, then strip everything up to and including
    # the last occurrence of /Supernote/Note/ to get clean relative path
    local rel_dir
    rel_dir=$(dirname "${filepath#${INPUT_DIR}/}")
    # Use sed to strip everything up to and including Supernote/Note/
    rel_dir=$(echo "${rel_dir}" | sed 's|.*Supernote/Note/||')

    local output_subdir="${OUTPUT_DIR}/${rel_dir}"
    local lockfile="/tmp/.snobmd_lock_${basename}"

    # Per-file lock — prevents inotify + poll loop from double-triggering same file
    if [[ -f "${lockfile}" ]]; then
        return 0
    fi

    if [[ "${FORCE_RECONVERT}" != "true" ]] && [[ -f "${output_subdir}/${basename}/${basename}.md" ]]; then
        if [[ ! "${filepath}" -nt "${output_subdir}/${basename}/${basename}.md" ]]; then
            info "Skipping already-converted: ${filepath}"
            return 0
        fi
        info "Note updated since last conversion, reconverting: ${filepath}"
    fi

    touch "${lockfile}"

    # Use a per-note isolated staging directory in /tmp so concurrent conversions
    # never collide on sn2md's internal UUID temp folders
    local staging_dir="/tmp/.snobmd_staging_${basename}"
    rm -rf "${staging_dir}"
    mkdir -p "${staging_dir}"

    info "Converting: ${filepath}"
    if sn2md \
        --config "${CONFIG_FILE}" \
        --output "${staging_dir}" \
        file "${filepath}"; then
        # Clean up intermediate image files from staging
        find "${staging_dir}" -name "*.png" -delete
        find "${staging_dir}" -name "*.jpg" -delete
        # Move staged output into final output location
        mkdir -p "${output_subdir}"
        # Remove existing output folder if reconverting
        rm -rf "${output_subdir:?}/${basename}"
        mv "${staging_dir}/${basename}" "${output_subdir}/${basename}"
        # Chown output files if OUTPUT_UID is set in environment
        if [[ -n "${OUTPUT_UID:-}" ]]; then
            chown -R "${OUTPUT_UID}:${OUTPUT_GID:-${OUTPUT_UID}}" "${output_subdir}"
        fi
        info "Done: ${rel_dir}/${basename}.md"
        tag_file "${output_subdir}/${basename}/${basename}.md"
        clean_md "${output_subdir}/${basename}/${basename}.md"
    else
        err "Failed to convert: ${filepath}"
    fi

    rm -rf "${staging_dir}"
    rm -f "${lockfile}"
}

# ── Scan existing files on startup ───────────────────────────────────────────
if [[ "${SCAN_EXISTING}" == "true" ]]; then
    info "Scanning ${INPUT_DIR} for existing .note files..."
    while IFS= read -r -d '' file; do
        convert_file "${file}"
    done < <(find "${INPUT_DIR}" -type f -name "*.note" -print0)
    info "Initial scan complete."
fi

# ── Watch for new/modified files ─────────────────────────────────────────────
info "Watching ${INPUT_DIR} for new .note files (poll interval: ${POLL_INTERVAL}s)..."

inotifywait_available=true
if ! command -v inotifywait &> /dev/null; then
    warn "inotifywait not available, falling back to polling only"
    inotifywait_available=false
fi

# Polling loop (runs always - catches events inotify may miss on network mounts)
poll_loop() {
    local seen_file="/tmp/.sn2md_seen"
    touch "${seen_file}"
    while true; do
        sleep "${POLL_INTERVAL}"
        while IFS= read -r -d '' file; do
            if [[ "${file}" -nt "${seen_file}" ]]; then
                convert_file "${file}"
            fi
        done < <(find "${INPUT_DIR}" -type f -name "*.note" -print0)
        touch "${seen_file}"
    done
}
poll_loop &

# inotify loop (real-time, works on local/bind mounts)
if [[ "${inotifywait_available}" == "true" ]]; then
    inotifywait -m -r \
        -e close_write \
        -e moved_to \
        --format '%w%f' \
        --include '\.note$' \
        "${INPUT_DIR}" 2>/dev/null |
    while IFS= read -r filepath; do
        convert_file "${filepath}"
    done
else
    wait
fi
