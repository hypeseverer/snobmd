# SnobMD

> **A huge thank you to [Dane Summers (dsummersl)](https://github.com/dsummersl) for creating [sn2md](https://github.com/dsummersl/sn2md) — without his work, none of this would be possible. This container is simply a wrapper that makes sn2md easy to self-host as a persistent background service. All the hard work — Supernote file parsing, LLM integration, OCR prompt engineering, and markdown output — is entirely his. Please star his repo and follow his work.**

---

A Docker container that watches a directory for Supernote `.note` files and converts them to Markdown using a locally hosted [Ollama](https://ollama.com) vision model. Output lands directly in your Obsidian vault (or any folder), ready for LiveSync to propagate to all your devices.

---

## How it works

1. Mounts your Supernote Private Cloud `supernote_data` directory as `/input` (read-only)
2. Watches for new or modified `.note` files using `inotifywait` (with a polling fallback for NFS/CIFS mounts)
3. Sends each page as a PNG image to your Ollama vision model for OCR transcription
4. Writes a `.md` file per note into `/output` (your Obsidian vault subfolder)

---

## Quick start

### 1. Pull a vision model into Ollama

```bash
ollama pull qwen2.5vl:7b
```

### 2. Create a `docker-compose.yml`

```yaml
services:
  sn2md:
    image: hypeseverer/snobmd:latest
    container_name: SnobMD
    restart: unless-stopped
    environment:
      OLLAMA_BASE_URL: "http://10.0.0.10:11434"   # your Ollama host
      OLLAMA_MODEL: "qwen2.5vl:7b"
    volumes:
      - /data/supernote/supernote_data:/input:ro
      - /path/to/obsidian/vault/Supernote:/output
```

### 3. Run it

```bash
docker compose up -d
docker compose logs -f sn2md
```

---

## Versioning

This image tracks upstream `sn2md` PyPI releases. Tags on Docker Hub correspond directly to the version of `sn2md` bundled inside:

| Docker Hub tag | sn2md version |
|---|---|
| `hypeseverer/snobmd:latest` | Most recent build |
| `hypeseverer/snobmd:sn2md-2.6.0` | sn2md 2.6.0 |

### Keeping up with upstream updates

When [dsummersl releases a new version of sn2md on PyPI](https://pypi.org/project/sn2md/#history):

1. Check the new version number (e.g. `2.7.0`)
2. Push a new Git tag to this repo:
   ```bash
   git tag sn2md-2.7.0
   git push origin sn2md-2.7.0
   ```
3. GitHub Actions automatically builds a multi-arch image (`amd64` + `arm64`) and pushes both the pinned tag and `:latest` to Docker Hub

You are in control of when you adopt upstream changes — no automatic rebuilds from upstream commits.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_BASE_URL` | `http://ollama:11434` | URL of your Ollama instance |
| `OLLAMA_MODEL` | `qwen2.5vl:7b` | Vision model to use for OCR |
| `INPUT_DIR` | `/input` | Directory to watch for `.note` files |
| `OUTPUT_DIR` | `/output` | Directory to write `.md` files into |
| `SCAN_EXISTING` | `true` | Process existing `.note` files on startup |
| `FORCE_RECONVERT` | `false` | Re-convert even if `.md` already exists |
| `POLL_INTERVAL` | `60` | Polling interval in seconds (backup to inotify) |
| `OUTPUT_FILENAME_TEMPLATE` | `{{file_basename}}.md` | sn2md output filename template |
| `OUTPUT_PATH_TEMPLATE` | `{{file_basename}}` | sn2md output subdirectory template |
| `SN2MD_PROMPT` | *(see below)* | Custom OCR prompt (must include `{context}`) |

### Default OCR prompt

Adapted from the [local model configuration contributed by Dane Summers (dsummersl)](https://github.com/dsummersl/sn2md):

```
### Context (the last few lines of markdown from the previous page):
{context}

### You are an OCR program. The image is a handwritten note page from an e-ink device.
Extract all text. Preserve headings, bullet points, and structure as markdown.
Do not add commentary or preamble. Output only the markdown.
```

> **Note:** The default prompt does not work well with `llama3.2-vision`. If using that model, override `SN2MD_PROMPT` with the simpler prompt from the sn2md README.

---

## Volume mounts

| Container path | Purpose |
|---|---|
| `/input` | Source `.note` files (mount as `:ro`) |
| `/output` | Destination for generated `.md` files |
| `/config` | Optional: mount a custom `sn2md.toml` here to fully override config |

---

## Recommended Ollama models

| Model | Notes |
|---|---|
| `qwen2.5vl:7b` | Best accuracy for handwriting OCR (~5% WER), recommended |
| `llama3.2-vision:11b` | Good alternative, well tested with sn2md |

---

## Connecting to Ollama

**Ollama in another Docker container on the same host:**
```yaml
OLLAMA_BASE_URL: "http://ollama:11434"
# Add both containers to a shared Docker network
```

**Ollama running directly on the Docker host:**
```yaml
OLLAMA_BASE_URL: "http://host.docker.internal:11434"
# or use the host's LAN IP:
OLLAMA_BASE_URL: "http://10.17.52.5:11434"
```

**Ollama on a separate machine:**
```yaml
OLLAMA_BASE_URL: "http://192.168.1.50:11434"
```

---

## Building locally

```bash
# Build with default sn2md version
docker build -t hypeseverer/snobmd:latest .

# Build with a specific sn2md version
docker build --build-arg SN2MD_VERSION=2.6.0 -t hypeseverer/snobmd:sn2md-2.6.0 .

# Multi-arch build and push (requires buildx)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg SN2MD_VERSION=2.6.0 \
  -t hypeseverer/snobmd:sn2md-2.6.0 \
  -t hypeseverer/snobmd:latest \
  --push .
```

---

## Setting up GitHub Actions (first time)

1. Create a Docker Hub access token at [hub.docker.com/settings/security](https://hub.docker.com/settings/security)
2. Add it to your GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `DOCKERHUB_TOKEN`
   - Value: your Docker Hub token
3. Push your first tag:
   ```bash
   git tag sn2md-2.6.0
   git push origin sn2md-2.6.0
   ```

---

## Output structure

For a note file at `/input/MyNotes/Meeting.note`, the container produces:

```
/output/
  Meeting/
    Meeting.md       ← the markdown transcript
    Meeting_p1.png   ← page images (referenced in the .md)
    Meeting_p2.png
```

---

## LiveSync integration

Once `.md` files land in your Obsidian vault folder, Obsidian LiveSync propagates them to all your devices automatically. To avoid syncing the raw binary `.note` files, add `*.note` to your LiveSync exclusion patterns.

---

## Credits

- [sn2md](https://github.com/dsummersl/sn2md) by [Dane Summers (dsummersl)](https://github.com/dsummersl) — core conversion tool and OCR prompt configuration
- [Ollama](https://ollama.com) — local LLM runtime
- [Supernote by Ratta](https://supernote.com) — the device
