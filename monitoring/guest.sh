#!/usr/bin/env bash
set -euo pipefail
exec </dev/null >/dev/ttyS1 2>&1

finish() {
    local status=$?
    if [ "$status" -ne 0 ] && [ -f /run/pxe-bench-apt.log ]; then
        tail -n 25 /run/pxe-bench-apt.log
    fi
    printf 'PXE_BENCH_EXIT=%s\n' "$status"
    sync
    systemctl poweroff --no-block
}
trap finish EXIT

. /etc/os-release
test "$ID" = debian
test "$VERSION_ID" = 13
test "$(uname -m)" = x86_64
test "$(getconf _NPROCESSORS_ONLN)" -eq 2
test "$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)" -ge 921600
test "$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)" -le 1048576
test "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)" -eq 0
test -r /proc/pressure/memory
umask 022
mkdir -p /mnt/pxe-bench /srv/pxe-bench
mount -o ro /dev/sr0 /mnt/pxe-bench
seed=/mnt/pxe-bench
test -f "$seed/source.tar.gz"
printf '%s\n' 'Provisioning Debian 13 benchmark packages'
systemctl mask --now nginx.service php8.4-fpm.service
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive
printf '%s\n' 'deb https://deb.debian.org/debian trixie main' > /run/pxe-bench.list
apt_options=(-o Dir::Etc::sourcelist=/run/pxe-bench.list -o Dir::Etc::sourceparts=- -o Acquire::Retries=3)
apt-get "${apt_options[@]}" -qq update >/run/pxe-bench-apt.log 2>&1
apt-get "${apt_options[@]}" -y --no-install-recommends install git nginx php8.4-cli php8.4-fpm \
    php8.4-opcache php8.4-sqlite3 python3 >>/run/pxe-bench-apt.log 2>&1
apt-get clean
useradd --system --create-home pxe-bench
tar --no-same-owner -xzf "$seed/source.tar.gz" -C /srv/pxe-bench
install -m 0755 "$seed/pxe-tools-rust" /srv/pxe-bench/pxe-tools-rust
chown -R pxe-bench:pxe-bench /srv/pxe-bench
cd /srv/pxe-bench/pxe-tools
guest_rust=/srv/pxe-bench/pxe-tools-rust

# Provisioning uses NAT. Measurement uses only guest loopback and Unix sockets.
for entry in /sys/class/net/*; do
    nic=$(basename "$entry")
    if [ "$nic" != lo ]; then ip link set dev "$nic" down; fi
done
ip link set dev lo up
test -z "$(ip -4 route show default)"
test -z "$(ip -6 route show default)"
test "$(systemctl show php8.4-fpm -p ActiveState --value)" = inactive
test "$(systemctl show nginx -p ActiveState --value)" = inactive

printf 'PXE_CONTEXT_BEGIN\n'
printf '%s\n' "$PRETTY_NAME"
uname -srm
awk '/^(MemTotal|MemAvailable|SwapTotal):/' /proc/meminfo
printf 'vCPUs=%s\n' "$(getconf _NPROCESSORS_ONLN)"
dpkg-query -W -f='${Package}=${Version}\n' nginx php8.4-fpm php8.4-opcache php8.4-sqlite3
php-fpm8.4 -i > /run/pxe-bench-fpm-info
grep -E '^opcache\.(enable|memory_consumption) =>' /run/pxe-bench-fpm-info
grep -q '^opcache.enable => On' /run/pxe-bench-fpm-info
sha256sum "$guest_rust"
printf 'PXE_CONTEXT_END\n'

runuser -u pxe-bench -- python3 tests/benchmarks/rust-monitor/parity.py --fpm /usr/sbin/php-fpm8.4 --rust "$guest_rust"
printf '%s\n' 'Starting six rotated rounds with four clients and twelve seconds of load'
runuser -u pxe-bench -- python3 tests/benchmarks/rust-monitor/benchmark.py \
    --fpm /usr/sbin/php-fpm8.4 --rust "$guest_rust" --clients 4 --rounds 6 --seconds 12 \
    > /run/pxe-monitor-result.json
printf 'PXE_METRICS_BEGIN\n'
cat /run/pxe-monitor-result.json
printf 'PXE_METRICS_END\n'
