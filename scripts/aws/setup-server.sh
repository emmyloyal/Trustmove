#!/usr/bin/env bash
# Sets up (or updates) the Trustmove server on an Ubuntu 24.04 Lightsail instance. Safe to run again. It can share a
# server with other apps: its own user, folder, database, port, service and Caddy site file; it never edits theirs.
# Usage on the server:  sudo bash setup-server.sh <api hostname> [more hostnames]   e.g. trustmove-api.duckdns.org
# Expects the settings file at /opt/trustmove/.env (copied over SSH, never committed). The web app itself is hosted on
# Vercel; this server answers /api for it (ALLOWED_ORIGINS must name the Vercel address).
set -euo pipefail
HOST="${1:?usage: setup-server.sh <hostname> [more hostnames]}"
HOSTS=$(printf "%s, " "$@"); HOSTS=${HOSTS%, }   # Caddy serves (and gets a certificate for) every name given
NODE_VERSION=26.13.0
NAME=trustmove
REPO=https://github.com/emmyloyal/Trustmove.git
APP_DIR=/opt/$NAME
DATA_DIR=/var/lib/$NAME             # the database lives here, outside the repo, so updates never touch it
PORT=8081                           # 8080 is taken by another app on the shared server

# 1 GB of RAM is tight for the app build; a swap file keeps it from running out of memory.
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git caddy curl xz-utils libatomic1 >/dev/null   # Node's official build needs libatomic

if [ "$(node -v 2>/dev/null)" != "v$NODE_VERSION" ]; then
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" | tar -xJ -C /usr/local --strip-components=1
fi

id $NAME >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin $NAME
mkdir -p "$DATA_DIR" && chown $NAME:$NAME "$DATA_DIR" && chmod 700 "$DATA_DIR"

if [ -d "$APP_DIR/.git" ]; then
  sudo -u $NAME -H git -C "$APP_DIR" fetch -q origin main
  sudo -u $NAME -H git -C "$APP_DIR" reset -q --hard origin/main
else
  mkdir -p "$APP_DIR"
  tmp=$(mktemp -d) && git clone -q --branch main "$REPO" "$tmp" && cp -a "$tmp/." "$APP_DIR/"
fi
[ -f "$APP_DIR/.env" ] || { echo "Missing $APP_DIR/.env - copy the settings first."; exit 1; }
chown -R $NAME:$NAME "$APP_DIR" && chmod 600 "$APP_DIR/.env"

sudo -u $NAME -H bash -c "cd $APP_DIR/app && npm ci --no-audit --no-fund --loglevel=error && npm run build >/dev/null"
sudo -u $NAME -H bash -c "cd $APP_DIR/agent && npm ci --omit=dev --no-audit --no-fund --loglevel=error"

cat > /etc/systemd/system/$NAME.service <<EOF
[Unit]
Description=Trustmove server (naira, decided by TapeOut circuits on X Layer)
After=network-online.target
Wants=network-online.target

[Service]
User=$NAME
WorkingDirectory=$APP_DIR/agent
Environment=PORT=$PORT
ExecStart=/usr/local/bin/node src/server/main.ts --network=xlayer
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Caddy: each app owns one file in /etc/caddy/sites; the main Caddyfile only imports them.
mkdir -p /etc/caddy/sites
cat > /etc/caddy/sites/$NAME.caddy <<EOF
$HOSTS {
  encode gzip
  reverse_proxy 127.0.0.1:$PORT
}
EOF
grep -q 'import /etc/caddy/sites/\*.caddy' /etc/caddy/Caddyfile 2>/dev/null || {
  echo "The main Caddyfile does not import /etc/caddy/sites yet. Run the other app's updated setup script first,"
  echo "or add the line:  import /etc/caddy/sites/*.caddy"
  exit 1
}
caddy validate --config /etc/caddy/Caddyfile >/dev/null

systemctl daemon-reload
systemctl enable -q $NAME caddy
systemctl restart $NAME
systemctl reload caddy
echo "Trustmove API is starting at https://$HOST"
