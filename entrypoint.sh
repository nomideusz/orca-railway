#!/bin/bash
set -e
: "${ORCA_SETUP_PASSWORD:?ORCA_SETUP_PASSWORD is required - it gates the pairing page}"

# /home/orca is the Railway volume: empty (bar lost+found) and root-owned on first boot.
H=/home/orca
S=$H/.config/orca-railway   # pairing offers for the /railway-pair page (credentials: 0700)
[ -f "$H/.bashrc" ] || cp -a --update=none /etc/skel/. "$H/"
mkdir -p "$H/projects" "$S"
[ "$(stat -c %u "$H")" = 1000 ] && [ "$(stat -c %u "$H/projects")" = 1000 ] || chown -R orca:orca "$H"
chown orca:orca "$S" && chmod 700 "$S"

as_orca() { setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=orca LOGNAME=orca SHELL=/bin/bash "$@"; }

# Optional keys, applied once so a login done in Orca is never overwritten.
if [ -n "${OPENAI_API_KEY:-}" ] && [ ! -f "$H/.codex/auth.json" ]; then
  printenv OPENAI_API_KEY | as_orca codex login --with-api-key >/dev/null 2>&1 || echo "codex: API-key login failed"
fi
[ -n "${GH_TOKEN:-}" ] && { as_orca gh auth setup-git >/dev/null 2>&1 || true; }
# Orca will not create a worktree without a commit identity; set a placeholder once.
as_orca git config --global user.name >/dev/null || as_orca git config --global user.name "Orca on Railway"
as_orca git config --global user.email >/dev/null || as_orca git config --global user.email "orca@railway.invalid"

# nginx on $PORT. /railway-pair (password page) hands out pairing links; everything else
# is Orca: the web client's static files and the WebSocket, which needs a paired device token.
cat > /etc/nginx/conf.d/orca.conf <<CFG
server {
  listen ${PORT} default_server;
  listen [::]:${PORT} default_server;
  client_max_body_size 200m;
  location = /healthcheck { proxy_pass http://127.0.0.1:6768/web-index.html; }
  location = /railway-pair { proxy_pass http://127.0.0.1:6769; proxy_set_header Host \$http_host; }
  location / {
    proxy_pass http://127.0.0.1:6768;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host \$http_host;
    proxy_buffering off;
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
  }
}
CFG
nginx

as_orca env ORCA_RAILWAY_STATE="$S" node /opt/railway-pair.mjs &
unset ORCA_SETUP_PASSWORD

# Railway counts the kernel cache of files this container touched as its memory and
# never frees it without pressure (one npm install = hundreds of MB). Drop it every 15 min.
( while sleep 900; do nice -n 19 drop-file-cache "$H" /tmp || true; done ) &

ADDR="${ORCA_PAIRING_ADDRESS:-https://${RAILWAY_PUBLIC_DOMAIN:-localhost}}"
echo "== Orca ${ORCA_VERSION} on :${PORT}. Pair a device at ${ADDR}/railway-pair"
cd "$H/projects"
# Orca prints its pairing offer (a credential) as one JSON line at startup: keep it out of
# the logs and hand it to the pairing page. The page restarts Orca through this loop.
while :; do
  args=(--password-store=basic --serve --serve-json --serve-port 6768 --serve-pairing-address "$ADDR")
  mode=$(cat "$S/next" 2>/dev/null || true); rm -f "$S/next"
  [ "$mode" = reset ] && rm -f "$H/.config/orca/orca-devices.json" "$S"/*.json
  [ "$mode" = mobile ] && args+=(--serve-mobile-pairing)
  # Chromium's profile lock names the old container's hostname; nothing else runs Orca here.
  rm -f "$H/.config/orca"/Singleton*
  # Orca's terminal daemon outlives the main process (so agents survive restarts) and
  # inherits stdout, so wait on Orca itself, never on the pipe reaching EOF.
  # ponytail: each restart leaves the old filter attached to the daemon (~2 MB bash).
  as_orca /opt/orca/orca-ide --no-sandbox "${args[@]}" > >(while IFS= read -r line; do
    case $line in
      '{"type":"orca_server_ready"'*)
        scope=$(printf '%s' "$line" | jq -r '.pairing.scope // "runtime"')
        printf '%s\n' "$line" | as_orca tee "$S/$scope.json.tmp" >/dev/null && mv "$S/$scope.json.tmp" "$S/$scope.json"
        echo "Orca server ready ($(printf '%s' "$line" | jq -r '.advertisedEndpoint')). Pairing links: ${ADDR}/railway-pair" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done) 2>&1 &
  wait $!
  echo "orca exited; restarting"
  sleep 2
done
