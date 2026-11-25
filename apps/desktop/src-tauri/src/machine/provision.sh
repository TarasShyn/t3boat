#!/usr/bin/env bash
# Runs on a Boat sandbox, as `user`. Idempotent; also used to upgrade a machine.
#   T3BOAT_SECRET=<watchdog-secret> provision.sh <t3-version> <sleep-after-secs> <snapshot-name> <mint-upstream-token:0|1> <name>
# Expects watchdog.mjs next to it. Prints one JSON line: {"environmentId", "upstreamToken"?}.
set -euo pipefail

version="$1" sleep_after="$2" snapshot="$3" mint_upstream="$4" name="$5"
secret="$T3BOAT_SECRET"
here="$(cd "$(dirname "$0")" && pwd)"
t3="$HOME/.local/bin/t3"
boat_dir="$HOME/.t3boat"
units="$HOME/.config/systemd/user"
mkdir -p "$boat_dir" "$units" "$HOME/.t3/userdata"
chmod 700 "$boat_dir"

# T3 server pinned to the desktop app's version, as a systemd service that survives resumes.
# It is restarted only when something it runs on changed: a restart drops every T3 Code
# connection, and most upgrades only touch the watchdog.
restart_t3=0
if [ "$("$t3" --version 2>/dev/null || true)" != "t3 v$version" ]; then
  if ! curl -fsSL https://t3.codes/install.sh | T3CODE_VERSION="$version" sh >"$boat_dir/install.log" 2>&1; then
    echo "T3 install failed" >&2
    tail -n 40 "$boat_dir/install.log" >&2
    exit 1
  fi
  restart_t3=1
fi
settings="$HOME/.t3/userdata/settings.json"
before="$(cat "$settings" 2>/dev/null || true)"
node -e '
  const fs = require("fs"), f = process.argv[1];
  const s = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {};
  s.linkedEnvironmentsEnabled = true;
  fs.writeFileSync(f, JSON.stringify(s, null, 2));
' "$settings"
[ "$before" = "$(cat "$settings")" ] || restart_t3=1
# The machine's name, as other devices show it (T3 Connect, linked environments). T3 reads it
# from here as it starts; without it, they show the sandbox's hostname.
machine_info="PRETTY_HOSTNAME=$name"
if [ "$(cat /etc/machine-info 2>/dev/null || true)" != "$machine_info" ]; then
  echo "$machine_info" | sudo tee /etc/machine-info >/dev/null
  restart_t3=1
fi
"$t3" service install --allow-downgrade >/dev/null
# Boat writes its Claude and GitHub tokens to /run/ascii-secrets/env.sh after the user services start.
# Claude Code re-reads its login file but never its environment, so the Claude token goes into the file.
cat >"$boat_dir/claude-login" <<'SCRIPT'
#!/bin/sh
set -eu
token=$(. /run/ascii-secrets/env.sh >/dev/null 2>&1; printf %s "${CLAUDE_CODE_OAUTH_TOKEN:-}")
[ -n "$token" ] || exit 0
TOKEN="$token" exec node -e '
  const fs = require("fs"), path = require("path"), os = require("os");
  const file = path.join(os.homedir(), ".claude", ".credentials.json");
  let current = null;
  try { current = JSON.parse(fs.readFileSync(file, "utf8")).claudeAiOauth; } catch {}
  if (current && (current.refreshToken || current.accessToken === process.env.TOKEN)) process.exit(0);
  const login = { claudeAiOauth: { accessToken: process.env.TOKEN, refreshToken: null, expiresAt: 4102444800000, scopes: ["user:inference"] } };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file + ".tmp", JSON.stringify(login), { mode: 0o600 });
  fs.renameSync(file + ".tmp", file);
'
SCRIPT
chmod 700 "$boat_dir/claude-login"
cat >"$units/t3boat-claude-login.service" <<'UNIT'
[Unit]
Description=t3boat: write Boat's active Claude account to Claude's login file

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'exec %h/.t3boat/claude-login'
UNIT
cat >"$units/t3boat-claude-login.path" <<'UNIT'
[Unit]
Description=t3boat: follow Boat's Claude account switches

[Path]
PathChanged=/run/ascii-secrets/env.sh

[Install]
WantedBy=default.target
UNIT
mkdir -p "$units/t3code.service.d"
cat >"$units/t3code.service.d/t3boat-boat-credentials.conf" <<'UNIT'
[Service]
TimeoutStartSec=300
EnvironmentFile=-%t/t3boat-boat-credentials.env
ExecStartPre=/bin/sh -c 'for _ in $$(seq 240); do [ -s /run/ascii-secrets/env.sh ] && break; sleep 1; done; umask 077; sed -n "s/^export \\(GITHUB_TOKEN\\)=/\\1=/p" /run/ascii-secrets/env.sh >%t/t3boat-boat-credentials.env 2>/dev/null || true'
ExecStartPre=-/bin/bash -lc 'exec %h/.t3boat/claude-login'
UNIT
# Boat renews a login by issuing a new token, and the old one stops working before every machine
# has the new one. A turn that dies in that gap is continued once the login works again.
cat >"$boat_dir/claude-auth-recover.mjs" <<'SCRIPT'
import { DatabaseSync } from "node:sqlite";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const HOME = homedir();
const DB_PATH = join(HOME, ".t3", "userdata", "statev2.sqlite");
const CREDENTIALS = join(HOME, ".claude", ".credentials.json");
const T3 = join(HOME, ".local", "bin", "t3");
const TICK_MS = 20_000;
const WINDOW_MS = 60 * 60_000;
const MAX_CONTINUES_PER_WINDOW = 3;
const AUTH_FAILURE = /^(Failed to authenticate|Not logged in)|OAuth token (revoked|has expired)/;
const CONTINUE =
  "Your last turn stopped because Claude's login had expired. The login works again, so carry on where you stopped.";

const log = (...args) => console.log(new Date().toISOString(), ...args);
/** threadId -> times this watcher continued it, within the window. */
const continued = new Map();

/** Threads whose latest turn ended on a failed Claude login, with nothing sent to them since. */
function stalledThreads() {
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  const db = new DatabaseSync(DB_PATH, { readOnly: true });
  try {
    const rows = db
      .prepare(
        `SELECT item.thread_id AS threadId, json_extract(item.payload_json, '$.text') AS text
         FROM orchestration_v2_projection_turn_items AS item
         WHERE item.thread_id IN (SELECT thread_id FROM orchestration_v2_projection_threads WHERE updated_at > ?)
           AND item.type = 'assistant_message' AND item.updated_at > ?
           AND NOT EXISTS (
             SELECT 1 FROM orchestration_v2_projection_messages AS message
             WHERE message.thread_id = item.thread_id AND message.role = 'user'
               AND message.created_at > item.updated_at
           )`,
      )
      .all(since, since);
    return [...new Set(rows.filter((r) => AUTH_FAILURE.test(r.text ?? "")).map((r) => r.threadId))];
  } finally {
    db.close();
  }
}

async function loginWorks() {
  await run("bash", ["-lc", 'exec "$HOME/.t3boat/claude-login"']).catch(() => {});
  let token;
  try {
    token = JSON.parse(readFileSync(CREDENTIALS, "utf8")).claudeAiOauth?.accessToken;
  } catch {
    return false;
  }
  if (!token) return false;
  const res = await fetch("https://api.anthropic.com/api/oauth/profile", {
    headers: { authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  return res?.ok === true;
}

async function tick() {
  const now = Date.now();
  for (const [threadId, times] of continued) {
    const recent = times.filter((t) => now - t < WINDOW_MS);
    recent.length > 0 ? continued.set(threadId, recent) : continued.delete(threadId);
  }
  const stalled = stalledThreads().filter((id) => (continued.get(id)?.length ?? 0) < MAX_CONTINUES_PER_WINDOW);
  if (stalled.length === 0 || !(await loginWorks())) return;
  for (const threadId of stalled) {
    await run(T3, ["thread", "send", threadId, CONTINUE]);
    continued.set(threadId, [...(continued.get(threadId) ?? []), now]);
    log("continued", threadId);
  }
}

log("watching for turns that died on an expired Claude login");
async function loop() {
  await tick().catch((e) => log("tick failed", e.message));
  setTimeout(loop, TICK_MS);
}
loop();
SCRIPT
chmod 600 "$boat_dir/claude-auth-recover.mjs"
cat >"$units/t3boat-claude-auth-recover.service" <<'UNIT'
[Unit]
Description=t3boat: continue threads whose turn died on an expired Claude login
After=t3code.service

[Service]
ExecStart=/bin/bash -lc 'exec node --no-warnings %h/.t3boat/claude-auth-recover.mjs'
Restart=always
RestartSec=10
StandardOutput=append:%h/.t3boat/claude-auth-recover.log
StandardError=append:%h/.t3boat/claude-auth-recover.log

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now t3boat-claude-login.path >/dev/null 2>&1
systemctl --user enable t3boat-claude-auth-recover.service >/dev/null 2>&1
systemctl --user restart t3boat-claude-auth-recover.service
systemctl --user is-active --quiet t3code.service || restart_t3=1
[ "$restart_t3" = 0 ] || systemctl --user restart t3code.service

ready=0
for _ in $(seq 1 120); do
  if curl -sf -o /dev/null http://127.0.0.1:3773/.well-known/t3/environment; then ready=1; break; fi
  sleep 0.5
done
if [ "$ready" != 1 ]; then
  echo "T3 server did not start" >&2
  tail -n 40 "$HOME/.t3/userdata/logs/boot-service.log" >&2 || true
  exit 1
fi

# Watchdog: its own read-only T3 token, kept across upgrades.
config="$boat_dir/config.json"
watchdog_token="$(node -e 'try{process.stdout.write(require(process.argv[1]).t3Token||"")}catch{}' "$config")"
if [ -z "$watchdog_token" ]; then
  watchdog_token="$("$t3" auth session issue --token-only --ttl 3650d --label t3boat-watchdog --scope orchestration:read)"
fi
SECRET="$secret" TOKEN="$watchdog_token" SLEEP="$sleep_after" SNAPSHOT="$snapshot" node -e '
  const e = process.env;
  require("fs").writeFileSync(process.argv[1], JSON.stringify({
    secret: e.SECRET, t3Token: e.TOKEN, sleepAfterSecs: Number(e.SLEEP), snapshot: e.SNAPSHOT
  }, null, 2), { mode: 0o600 });
' "$config"
install -m 600 "$here/watchdog.mjs" "$boat_dir/watchdog.mjs"
cat >"$units/t3boat-watchdog.service" <<'UNIT'
[Unit]
Description=t3boat watchdog: stops this sandbox when idle
After=t3code.service

[Service]
ExecStart=/bin/bash -lc 'exec node --no-warnings %h/.t3boat/watchdog.mjs'
Restart=always
RestartSec=5
StandardOutput=append:%h/.t3boat/watchdog.log
StandardError=append:%h/.t3boat/watchdog.log

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable t3boat-watchdog.service >/dev/null 2>&1
systemctl --user restart t3boat-watchdog.service

upstream_token=""
if [ "$mint_upstream" = 1 ]; then
  upstream_token="$("$t3" auth session issue --token-only --ttl 3650d --label t3boat)"
fi
environment_id="$(curl -sf http://127.0.0.1:3773/.well-known/t3/environment | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).environmentId))')"
ENV_ID="$environment_id" TOK="$upstream_token" node -e '
  const o = { environmentId: process.env.ENV_ID };
  if (process.env.TOK) o.upstreamToken = process.env.TOK;
  console.log(JSON.stringify(o));
'
