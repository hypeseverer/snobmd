FROM python:3.12-slim

# SN2MD_VERSION controls which PyPI release of sn2md is installed.
# To pick up a new upstream release, bump this build arg and rebuild/push.
# Find latest versions at: https://pypi.org/project/sn2md/#history
ARG SN2MD_VERSION=2.6.0

LABEL org.opencontainers.image.title="SnobMD" \
      org.opencontainers.image.description="Watches a directory for Supernote .note files and converts them to Markdown using a local Ollama vision model. SN (Supernote) + OB (Obsidian) + MD (Markdown/Doctor)." \
      org.opencontainers.image.source="https://github.com/hypeseverer/snobmd" \
      org.opencontainers.image.vendor="hypeseverer" \
      sn2md.upstream.version="${SN2MD_VERSION}" \
      sn2md.upstream.source="https://github.com/dsummersl/sn2md"

# Install inotify-tools for filesystem watching and curl for Ollama healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    inotify-tools \
    curl \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install pinned sn2md version and the Ollama LLM plugin
RUN pip install --no-cache-dir sn2md==${SN2MD_VERSION}
RUN pip install --no-cache-dir llm-ollama

# Create standard directories
RUN mkdir -p /input /output /config

# Install web UI
COPY webui/ /webui/
RUN cd /webui && npm install --omit=dev

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Environment variable defaults ────────────────────────────────────────────
# Ollama connection
ENV OLLAMA_BASE_URL="http://ollama:11434"
ENV OLLAMA_MODEL="qwen2.5vl:7b"

# Conversion behaviour
ENV INPUT_DIR="/input"
ENV OUTPUT_DIR="/output"
ENV SCAN_EXISTING="true"
ENV FORCE_RECONVERT="false"
ENV POLL_INTERVAL="60"

# sn2md prompt (override to tune for your handwriting)
ENV SN2MD_PROMPT="### Context (the last few lines of markdown from the previous page):\n{context}\n\n### You are an OCR program. The image is a handwritten note page from an e-ink device.\nExtract all text. Preserve headings, bullet points, and structure as markdown.\nDo not add commentary or preamble. Output only the markdown."

# sn2md output filename/path templates
ENV OUTPUT_FILENAME_TEMPLATE="{{file_basename}}.md"
ENV OUTPUT_PATH_TEMPLATE="{{file_basename}}"

# Web UI
ENV WEBUI_PORT="8090"
ENV WEBUI_ENABLED="true"

# Notifiarr (optional)
ENV NOTIFIARR_URL=""
ENV NOTIFIARR_ENABLED="false"

# Supernote source type: local | private_cloud | supernote_cloud | webdav | smb
ENV SUPERNOTE_SOURCE_TYPE="local"
ENV SUPERNOTE_PRIVATE_CLOUD_URL=""
ENV SUPERNOTE_PRIVATE_CLOUD_USER=""
ENV SUPERNOTE_PRIVATE_CLOUD_PASS=""
ENV SUPERNOTE_CLOUD_USER=""
ENV SUPERNOTE_CLOUD_PASS=""
ENV SUPERNOTE_SYNC_FOLDER="/Note"
ENV SUPERNOTE_SYNC_INTERVAL="300"
# ─────────────────────────────────────────────────────────────────────────────

EXPOSE 8090
ENTRYPOINT ["/entrypoint.sh"]
