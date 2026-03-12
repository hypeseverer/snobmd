#!/usr/bin/env node
/**
 * SnobMD Web UI — Express backend
 * Serves the admin dashboard and provides REST API endpoints.
 */

const express = require('express');
const fs = require('fs');
const path = require('path');
const { execSync, exec } = require('child_process');
const https = require('https');

const app = express();
const PORT = process.env.WEBUI_PORT || 8090;

// State file for persistent stats + config overrides
const STATE_FILE = '/config/webui_state.json';
const ENV_OVERRIDE_FILE = '/config/env_overrides.json';
const STATS_FILE = '/config/stats.json';

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── Helpers ─────────────────────────────────────────────────────────────────

function readJSON(file, fallback = {}) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJSON(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function getEnv() {
  return {
    OLLAMA_BASE_URL:          process.env.OLLAMA_BASE_URL || 'http://ollama:11434',
    OLLAMA_MODEL:             process.env.OLLAMA_MODEL || 'qwen2.5vl:7b',
    INPUT_DIR:                process.env.INPUT_DIR || '/input',
    OUTPUT_DIR:               process.env.OUTPUT_DIR || '/output',
    SCAN_EXISTING:            process.env.SCAN_EXISTING || 'true',
    FORCE_RECONVERT:          process.env.FORCE_RECONVERT || 'false',
    POLL_INTERVAL:            process.env.POLL_INTERVAL || '60',
    OUTPUT_FILENAME_TEMPLATE: process.env.OUTPUT_FILENAME_TEMPLATE || '{{file_basename}}.md',
    OUTPUT_PATH_TEMPLATE:     process.env.OUTPUT_PATH_TEMPLATE || '{{file_basename}}',
    SN2MD_PROMPT:             process.env.SN2MD_PROMPT || '',
    // Notifiarr
    NOTIFIARR_URL:            process.env.NOTIFIARR_URL || '',
    NOTIFIARR_ENABLED:        process.env.NOTIFIARR_ENABLED || 'false',
    // Supernote source
    SUPERNOTE_SOURCE_TYPE:    process.env.SUPERNOTE_SOURCE_TYPE || 'local',
    SUPERNOTE_PRIVATE_CLOUD_URL: process.env.SUPERNOTE_PRIVATE_CLOUD_URL || '',
    SUPERNOTE_PRIVATE_CLOUD_USER: process.env.SUPERNOTE_PRIVATE_CLOUD_USER || '',
    SUPERNOTE_PRIVATE_CLOUD_PASS: process.env.SUPERNOTE_PRIVATE_CLOUD_PASS || '',
    SUPERNOTE_CLOUD_USER:     process.env.SUPERNOTE_CLOUD_USER || '',
    SUPERNOTE_CLOUD_PASS:     process.env.SUPERNOTE_CLOUD_PASS || '',
    SUPERNOTE_SYNC_FOLDER:    process.env.SUPERNOTE_SYNC_FOLDER || '/Note',
    SUPERNOTE_SYNC_INTERVAL:  process.env.SUPERNOTE_SYNC_INTERVAL || '300',
  };
}

function getSn2mdVersion() {
  try {
    const result = execSync('pip show sn2md 2>/dev/null | grep Version', { encoding: 'utf8' });
    return result.replace('Version:', '').trim();
  } catch {
    return 'unknown';
  }
}

function fetchPypiVersion(callback) {
  const req = https.get('https://pypi.org/pypi/sn2md/json', (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => {
      try {
        const json = JSON.parse(data);
        callback(null, json.info.version);
      } catch (e) {
        callback(e, null);
      }
    });
  });
  req.on('error', (e) => callback(e, null));
  req.setTimeout(5000, () => { req.destroy(); callback(new Error('timeout'), null); });
}

function readLogs(logFile, lines = 200) {
  try {
    const result = execSync(`tail -n ${lines} "${logFile}" 2>/dev/null || echo ""`, { encoding: 'utf8' });
    return result;
  } catch {
    return '';
  }
}

function getStats() {
  const defaults = {
    total_converted: 0,
    total_pages: 0,
    total_errors: 0,
    total_words: 0,
    total_words_estimated: 0,
    last_converted: null,
    last_error: null,
    conversion_history: [],
    error_history: [],
  };
  return readJSON(STATS_FILE, defaults);
}

function listNoteFiles() {
  const inputDir = process.env.INPUT_DIR || '/input';
  const outputDir = process.env.OUTPUT_DIR || '/output';
  try {
    const result = execSync(`find "${inputDir}" -type f -name "*.note" 2>/dev/null || echo ""`, { encoding: 'utf8' });
    const files = result.trim().split('\n').filter(Boolean);
    return files.map(f => {
      const basename = path.basename(f, '.note');
      const mdPath = path.join(outputDir, basename, `${basename}.md`);
      const exists = fs.existsSync(mdPath);
      let size = 0;
      let mtime = null;
      try {
        const stat = fs.statSync(f);
        size = stat.size;
        mtime = stat.mtime.toISOString();
      } catch {}
      return { path: f, basename, converted: exists, size, mtime };
    });
  } catch {
    return [];
  }
}

function listConflicts() {
  const outputDir = process.env.OUTPUT_DIR || '/output';
  const conflicts = [];
  try {
    // Look for .md files with conflict indicators (obsidian livesync style)
    const result = execSync(`find "${outputDir}" -name "*.md" 2>/dev/null | xargs grep -l "<<<<<<\\|CONFLICT\\|=====" 2>/dev/null || echo ""`, { encoding: 'utf8' });
    const files = result.trim().split('\n').filter(Boolean);
    files.forEach(f => {
      conflicts.push({ path: f, type: 'merge_conflict' });
    });
    // Also look for duplicate/sync conflict filenames
    const dupes = execSync(`find "${outputDir}" -name "* (conflicted copy *" -o -name "*_conflict_*" 2>/dev/null || echo ""`, { encoding: 'utf8' });
    dupes.trim().split('\n').filter(Boolean).forEach(f => {
      conflicts.push({ path: f, type: 'duplicate_file' });
    });
  } catch {}
  return conflicts;
}

function readErrorLog() {
  // Parse main log for ERROR lines
  const logFile = '/config/watcher.log';
  try {
    const result = execSync(`grep -i "ERROR\\|WARN\\|failed\\|exception" "${logFile}" 2>/dev/null | tail -100 || echo ""`, { encoding: 'utf8' });
    return result.trim().split('\n').filter(Boolean);
  } catch {
    return [];
  }
}

// ── API Routes ───────────────────────────────────────────────────────────────

// GET /api/env — current environment config
app.get('/api/env', (req, res) => {
  const env = getEnv();
  const overrides = readJSON(ENV_OVERRIDE_FILE);
  res.json({ env, overrides });
});

// POST /api/env — save env overrides to file (requires container restart to apply)
app.post('/api/env', (req, res) => {
  const overrides = readJSON(ENV_OVERRIDE_FILE);
  const updated = { ...overrides, ...req.body };
  writeJSON(ENV_OVERRIDE_FILE, updated);
  res.json({ ok: true, message: 'Saved. Restart the container to apply changes.', overrides: updated });
});

// GET /api/version — installed vs latest sn2md version
app.get('/api/version', (req, res) => {
  const installed = getSn2mdVersion();
  fetchPypiVersion((err, latest) => {
    res.json({
      installed,
      latest: err ? null : latest,
      up_to_date: err ? null : (installed === latest),
      changelog_url: 'https://pypi.org/project/sn2md/#history',
      error: err ? err.message : null,
    });
  });
});

// GET /api/stats — conversion statistics
app.get('/api/stats', (req, res) => {
  const stats = getStats();
  const files = listNoteFiles();
  const converted = files.filter(f => f.converted).length;
  const pending = files.filter(f => !f.converted).length;
  res.json({ ...stats, files_total: files.length, files_converted: converted, files_pending: pending });
});

// GET /api/files — list all .note files and their conversion status
app.get('/api/files', (req, res) => {
  res.json(listNoteFiles());
});

// GET /api/logs — watcher process logs
app.get('/api/logs', (req, res) => {
  const lines = parseInt(req.query.lines) || 200;
  const log = readLogs('/config/watcher.log', lines);
  res.json({ log, lines });
});

// GET /api/config — current sn2md.toml content
app.get('/api/config', (req, res) => {
  try {
    const content = fs.readFileSync('/config/sn2md.toml', 'utf8');
    res.json({ content });
  } catch {
    res.json({ content: '# Config not yet generated. Container may still be starting.' });
  }
});

// GET /api/errors — error log entries + conflicts
app.get('/api/errors', (req, res) => {
  const errors = readErrorLog();
  const conflicts = listConflicts();
  res.json({ errors, conflicts });
});

// GET /api/health — simple health check
app.get('/api/health', (req, res) => {
  const ollamaUrl = process.env.OLLAMA_BASE_URL || 'http://ollama:11434';
  exec(`curl -sf "${ollamaUrl}/api/tags" > /dev/null 2>&1 && echo ok || echo fail`, (err, stdout) => {
    res.json({
      webui: 'ok',
      ollama: stdout.trim() === 'ok' ? 'ok' : 'unreachable',
      ollama_url: ollamaUrl,
    });
  });
});

// POST /api/notifiarr/test — send a test notification
app.post('/api/notifiarr/test', (req, res) => {
  const url = req.body.url || process.env.NOTIFIARR_URL;
  if (!url) return res.status(400).json({ ok: false, error: 'No Notifiarr URL provided' });

  const payload = JSON.stringify({
    notification: { update: false, name: 'SnobMD', event: '0' },
    discord: {
      color: '0088FF',
      text: {
        title: '🔔 SnobMD test notification',
        content: 'Your Notifiarr integration is working correctly.\n\nThis was triggered from the SnobMD Web UI.',
      },
    },
  });

  exec(`curl -sf -X POST "${url}" -H "Content-Type: application/json" -d '${payload.replace(/'/g, "'\\''")}' 2>&1`, (err, stdout, stderr) => {
    if (err) return res.json({ ok: false, error: stderr || err.message });
    res.json({ ok: true, response: stdout });
  });
});

// Fallback — serve the SPA
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[SnobMD] Admin UI listening on port ${PORT}`);
});
