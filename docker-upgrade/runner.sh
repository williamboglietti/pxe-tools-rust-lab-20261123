#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
set -euo pipefail

case "$PXE_ARCH" in amd64) test "$(uname -m)" = x86_64 ;; arm64) test "$(uname -m)" = aarch64 ;; *) exit 2 ;; esac
work=$(mktemp -d "${RUNNER_TEMP:?}/pxe-docker-upgrade.XXXXXXXX")
prefix=$(basename "$work")
legacy="${prefix}-beta12"
candidate="${prefix}-rust"
volumes=()
cleanup() {
    docker rm -fv "$legacy" "$candidate" >/dev/null 2>&1 || true
    if (( ${#volumes[@]} )); then docker volume rm "${volumes[@]}" >/dev/null 2>&1 || true; fi
    rm -rf -- "$work"
}
trap cleanup EXIT

published=ghcr.io/williamboglietti/pxe-tools-appliance:v0.1.0-beta12
offer="$work/docker-sources.json"
curl -fsSL --retry 2 --proto '=https' --proto-redir '=https' \
    "https://github.com/williamboglietti/pxe-tools/releases/download/v0.1.0-beta12/docker-sources-$PXE_ARCH.json" -o "$offer"
printf '%s  %s\n' "$PXE_OFFER_SHA" "$offer" | sha256sum -c --status
docker pull --platform "linux/$PXE_ARCH" "$published"
test "$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$published")" = "linux/$PXE_ARCH"
test "$(docker image inspect -f '{{.Id}}' "$published")" = "$(jq -er .image_id "$offer")"
test "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$published")" \
    = "$(jq -er .pxe_tools_source "$offer")"
printf 'Verified published beta 12 image for %s\n' "$PXE_ARCH"

mounts=()
for mapping in data:/var/lib/pxe-tools config:/etc/pxe-tools mok:/etc/pxe-tools/mok http:/srv/http tftp:/srv/tftp; do
    name="$prefix-${mapping%%:*}"
    docker volume create "$name" >/dev/null
    volumes+=("$name")
    mounts+=(--mount "type=volume,src=$name,dst=${mapping#*:}")
done
tls_volume="$prefix-tls"
docker volume create "$tls_volume" >/dev/null
volumes+=("$tls_volume")
tls_mount=(--mount "type=volume,src=$tls_volume,dst=/var/lib/pxe-tools-tls")

docker run --rm -i --network none "${mounts[@]}" --entrypoint /bin/bash "$published" -s <<'BASH'
set -euo pipefail
root=/var/lib/pxe-tools
db="$root/pxe-tools.sqlite"
umask 077
openssl rand -out /etc/pxe-tools/master.key 32
printf '{"driver":"sqlite","path":"%s"}\n' "$db" > /etc/pxe-tools/db.conf
sqlite3 -bail "$db" < /app/db/schema.sqlite.sql
php -r '
require "/app/src/Util/Crypto.php";
$db = new PDO("sqlite:/var/lib/pxe-tools/pxe-tools.sqlite");
$db->prepare("INSERT INTO users(username,password_hash) VALUES(?,?)")
    ->execute(["upgrade-fixture", password_hash("disposable-test-password", PASSWORD_BCRYPT)]);
$db->prepare("INSERT INTO settings(key,value) VALUES(?,?)")
    ->execute(["fixture_cipher", Admin\Util\Crypto::encrypt("fixture-legacy-cipher")]);
'
sqlite3 -bail "$db" <<'SQL'
INSERT OR REPLACE INTO settings(key,value) VALUES
  ('db_init_done','1'), ('admin_created','1'), ('wizard_completed','1'),
  ('pxe_enabled','off'), ('https_enabled','on'), ('ansible_enabled','off'), ('ui_device_term','ordinateur');
INSERT INTO machines(mac,hostname,status) VALUES('02:00:00:00:47:01','migration-fixture','installed');
SQL
chown www-data:www-data "$db" /etc/pxe-tools/db.conf
chmod 0640 "$db" /etc/pxe-tools/db.conf
BASH

await_https() {
    local container=$1 credentials=$2 port=$3
    for ((attempt = 1; attempt <= 40; attempt++)); do
        if docker exec "$container" curl -fsS --max-time 2 --cacert "$credentials/cert.pem" \
            "https://127.0.0.1:$port/healthz" >/dev/null 2>&1; then return 0; fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$container") != true ]]; then break; fi
        sleep 3
    done
    docker logs --tail 70 "$container" >&2
    return 1
}

digest() {
    docker exec "$1" sha256sum "$2" | cut -d ' ' -f 1
}

docker run -d --name "$legacy" --network none "${mounts[@]}" "$published" >/dev/null
old_tls=/var/lib/pxe-tools/tls
await_https "$legacy" "$old_tls" 8443
legacy_cert=$(digest "$legacy" "$old_tls/cert.pem")
legacy_key=$(digest "$legacy" "$old_tls/key.pem")
master_key=$(digest "$legacy" /etc/pxe-tools/master.key)
docker stop "$legacy" >/dev/null

docker run -d --name "$candidate" --network none "${mounts[@]}" "${tls_mount[@]}" pxe-guided-upgrade:local >/dev/null
new_tls=/var/lib/pxe-tools-tls
await_https "$candidate" "$new_tls" 443
test "$(digest "$candidate" "$new_tls/cert.pem")" = "$legacy_cert"
test "$(digest "$candidate" "$new_tls/key.pem")" = "$legacy_key"
test "$(digest "$candidate" /etc/pxe-tools/master.key)" = "$master_key"
test "$(digest "$candidate" "$old_tls/cert.pem")" = "$legacy_cert"
docker exec "$candidate" curl -fsS --cacert "$new_tls/cert.pem" \
    --user 'upgrade-fixture:disposable-test-password' https://127.0.0.1/admin/devices > "$work/console.html"
grep -F 'migration-fixture' "$work/console.html" >/dev/null
grep -F '<h1>Ordinateurs</h1>' "$work/console.html" >/dev/null
docker exec "$candidate" sh -ec '! command -v php && ! command -v nginx'
docker exec -i "$candidate" python3 - <<'PY'
from contextlib import closing
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, '/app')
from crypto import decrypt

with closing(sqlite3.connect('/var/lib/pxe-tools/pxe-tools.sqlite')) as db:
    assert db.execute('PRAGMA quick_check').fetchone() == ('ok',)
    value, = db.execute("SELECT value FROM settings WHERE key='fixture_cipher'").fetchone()
    assert decrypt(value) == 'fixture-legacy-cipher'
for pid in Path('/proc').glob('[0-9]*/cmdline'):
    try:
        command = pid.read_bytes().split(b'\0')
    except FileNotFoundError:
        continue
    if command[:2] == [b'/usr/lib/pxe-tools/pxe-tools-rust', b'--work-guided']:
        break
else:
    raise RuntimeError('Rust worker process missing after the volume migration')
PY
docker restart "$candidate" >/dev/null
await_https "$candidate" "$new_tls" 443
test "$(digest "$candidate" "$new_tls/cert.pem")" = "$legacy_cert"
test "$(digest "$candidate" "$new_tls/key.pem")" = "$legacy_key"
printf 'PXE_DOCKER_UPGRADE_PASS=%s\n' "$PXE_ARCH"
