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

# ── Conversion function ───────────────────────────────────────────────────────
convert_file() {
    local filepath="$1"
    local basename
    basename=$(basename "${filepath}" .note)

    local rel_dir
    rel_dir=$(dirname "${filepath#${INPUT_DIR}/}")
    rel_dir="${rel_dir#*/Supernote/Note/}"

    local output_subdir="${OUTPUT_DIR}/${rel_dir}"
    local lockfile="/tmp/.snobmd_lock_${basename}"

    if [[ -f "${lockfile}" ]]; then
        return 0
    fi

    if [[ "${FORCE_RECONVERT}" != "true" ]] && [[ -f "${output_subdir}/${basename}.md" ]]; then
        info "Skipping already-converted: ${filepath}"
        return 0
    fi

    touch "${lockfile}"
    mkdir -p "${output_subdir}"
    info "Converting: ${filepath}"
    if sn2md \
        --config "${CONFIG_FILE}" \
        --output "${output_subdir}" \
        file "${filepath}"; then
        info "Done: ${rel_dir}/${basename}.md"
    else
        err "Failed to convert: ${filepath}"
    fi
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
