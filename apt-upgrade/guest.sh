#!/usr/bin/env bash
set -Eeuo pipefail
exec </dev/null >/dev/ttyS1 2>&1

finish() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        for log in /run/pxe-beta10.log /run/pxe-beta11.log; do
            if [ -f "$log" ]; then tail -n 32 "$log"; fi
        done
        journalctl -b --no-pager -n 42 -u pxe-tools-worker -u pxe-tools-nginx \
            -u pxe-tools-php -u pxe-tools-dnsmasq -u pxe-tools-pxe-http -u pxe-tools-init || true
    fi
    printf 'PXE_UPGRADE_EXIT=%s\n' "$status"
    sync
    systemctl poweroff --no-block
}
trap finish EXIT
trap 'printf "PXE_UPGRADE_ERROR_LINE=%s\n" "$LINENO"' ERR

. /etc/os-release
test "$ID:$VERSION_ID:$(dpkg --print-architecture)" = debian:13:amd64
printf 'Platform %s amd64, systemd %s\n' "$PRETTY_NAME" "$(systemctl --version | awk 'NR==1 {print $2}')"
export DEBIAN_FRONTEND=noninteractive
umask 022
seed=/mnt/pxe-apt-upgrade
install -d -m 0755 "$seed"
mount -o ro /dev/sr0 "$seed"
scenario=$(cat "$seed/scenario")
case "$scenario" in base|ansible-proxy) ;; *) exit 2 ;; esac
packages=(pxe-tools)
if [ "$scenario" = ansible-proxy ]; then packages+=(pxe-tools-ansible); fi
install -m 0644 "$seed/fixture-keyring.gpg" /usr/share/keyrings/pxe-upgrade-fixture.gpg
source_line='deb [signed-by=/usr/share/keyrings/pxe-upgrade-fixture.gpg]'
printf '%s\n' "$source_line file:$seed/beta10 ./" 'deb https://deb.debian.org/debian trixie main' >/run/pxe-beta10.list
printf '%s\n' "$source_line file:$seed/beta11 ./" >/run/pxe-beta11.list
install -d -m 0755 /var/lib/apt/pxe-beta10-lists /var/lib/apt/pxe-beta11-lists
opts=(-o Dir::Etc::sourceparts=- -o APT::Update::Error-Mode=any -o Dpkg::Use-Pty=0 -o Acquire::Retries=3)
old=("${opts[@]}" -o Dir::Etc::sourcelist=/run/pxe-beta10.list -o Dir::State::lists=/var/lib/apt/pxe-beta10-lists)
new=("${opts[@]}" -o Dir::Etc::sourcelist=/run/pxe-beta11.list -o Dir::State::lists=/var/lib/apt/pxe-beta11-lists)

versions() {
    local expected=$1 name
    for name in "${packages[@]}"; do
        test "$(dpkg-query -W -f='${Status}|${Version}' "$name")" = "install ok installed|$expected"
        printf 'Installed %s %s\n' "$name" "$expected"
    done
    if [ "$scenario" = base ]; then
        if dpkg-query -W -f='${Status}' pxe-tools-ansible 2>/dev/null; then
            return 1
        fi
    fi
}

apt-get "${old[@]}" -q update >/run/pxe-beta10.log 2>&1
beta10=()
for name in "${packages[@]}"; do beta10+=("$name=0.1.0~beta10"); done
apt-get "${old[@]}" -q -y --no-install-recommends install "${beta10[@]}" >>/run/pxe-beta10.log 2>&1
versions '0.1.0~beta10'

# Configure the beta 10 instance from synthetic state, then put it into service.
# The actual upgrade below starts with these roles active and the worker idle.
units=(pxe-tools.target pxe-tools-admin.target pxe-tools-worker.service pxe-tools-dnsmasq-tail.service
       pxe-tools-nginx.service pxe-tools-pxe-http.service pxe-tools-php.service
       pxe-tools-dnsmasq.service pxe-tools-init.service)
systemctl stop "${units[@]}"
for entry in /sys/class/net/*; do
    nic=$(basename "$entry")
    if [ "$nic" != lo ]; then ip link set dev "$nic" down; fi
done
test -z "$(ip -4 route show default)"
test -z "$(ip -6 route show default)"
ip link add br-apt-lab type bridge
ip addr add 192.0.2.1/24 dev br-apt-lab
ip link set br-apt-lab up
ip link add pxe-lab-a type veth peer name pxe-lab-b
ip link set pxe-lab-a master br-apt-lab
ip link set pxe-lab-a up
ip link set pxe-lab-b up

crypto=/usr/lib/pxe-tools/app/src/Util/Crypto.php
cipher=$(runuser -u www-data -- php -r 'require $argv[1]; echo \Admin\Util\Crypto::encrypt("upgrade-fixture");' "$crypto")
admin_hash=$(php -r 'echo password_hash("fixture-admin-password", PASSWORD_DEFAULT);')
python3 "$seed/fixture.py" seed "$scenario" "$cipher" "$admin_hash"
db=/var/lib/pxe-tools/upgrade-lab.sqlite
. /usr/lib/pxe-tools/native/default.env
. /var/lib/pxe-tools-native/runtime.env
printf '%s\n' 'PXE media fixture' > "$HTTP_ROOT/upgrade-sentinel.txt"
sha256sum /etc/pxe-tools/master.key /etc/pxe-tools/db.conf "$HTTP_ROOT/upgrade-sentinel.txt" >/run/pxe-state.sha256

if [ "$scenario" = ansible-proxy ]; then
    account=pxe-tools-ansible
    account_before=$(id "$account")
    runuser -u "$account" -- sh -c 'printf "%s\n" "Ansible workspace fixture" > "$1"' \
        sh /var/lib/pxe-tools-ansible/workspace/upgrade-sentinel.txt
    sha256sum /var/lib/pxe-tools-ansible/workspace/upgrade-sentinel.txt >>/run/pxe-state.sha256
    systemctl enable --now pxe-tools.target
    runtime=ready
else
    runtime=not_configured
fi
systemctl start pxe-tools-admin.target

wait_runtime() {
    local attempt state
    for attempt in $(seq 1 100); do
        state=$(sqlite3 -cmd '.timeout 5000' "$db" \
            "SELECT json_extract(value,'$.state') FROM settings WHERE key='ansible_runtime_status'")
        if [ "$state" = "$runtime" ]; then return; fi
        sleep 1
    done
    printf 'Runtime state was %s, expected %s\n' "$state" "$runtime"
    return 1
}

check_services() {
    systemctl is-active --quiet pxe-tools-admin.target
    systemctl is-active --quiet pxe-tools-nginx.service
    systemctl is-active --quiet pxe-tools-worker.service
    test "$(curl -fsS --max-time 10 http://127.0.0.1:8080/healthz)" = ok
    curl -fsS --max-time 10 http://127.0.0.1:8080/login >/dev/null
    if [ "$scenario" = ansible-proxy ]; then
        systemctl is-active --quiet pxe-tools-dnsmasq.service
        systemctl is-active --quiet pxe-tools-pxe-http.service
        test "$(curl -fsS --max-time 10 http://192.0.2.1/healthz)" = ok
        grep -qx 'dhcp-range=192.0.2.0,proxy,255.255.255.0' /var/lib/pxe-tools-native/rendered/dnsmasq.conf
    else
        test "$(systemctl show -p ActiveState --value pxe-tools-dnsmasq.service)" = inactive
        test "$(systemctl show -p ActiveState --value pxe-tools-pxe-http.service)" = inactive
    fi
}

record_units() {
    local unit
    for unit in "${units[@]}"; do
        printf '%s\n' "$unit"
        systemctl show -p ActiveState -p UnitFileState "$unit"
    done
}

worker_idle() {
    local cgroup main_pid jobs
    cgroup=$(systemctl show -p ControlGroup --value pxe-tools-worker.service)
    main_pid=$(systemctl show -p MainPID --value pxe-tools-worker.service)
    jobs=$(sqlite3 -cmd '.timeout 5000' "$db" "SELECT COUNT(*) FROM init_jobs WHERE status IN ('pending', 'running')")
    [[ "$cgroup" == /system.slice/* && "$main_pid" =~ ^[1-9][0-9]*$ ]] &&
        [ "$jobs" = 0 ] &&
        [ "$(cat "/sys/fs/cgroup$cgroup/cgroup.procs")" = "$main_pid" ]
}

wait_idle() {
    local seconds
    for seconds in $(seq 1 100); do
        if worker_idle; then
            sleep 1
            if worker_idle; then return; fi
        fi
        sleep 1
    done
    printf '%s\n' 'The configured worker did not finish its initial jobs.'
    return 1
}

wait_runtime
apt-get "${new[@]}" -q update >/run/pxe-beta11.log 2>&1
wait_idle
check_services
record_units >/run/pxe-units.before
worker_before=$(systemctl show -p MainPID --value pxe-tools-worker.service)
test "$worker_before" -gt 0
printf 'PXE_UPGRADE_BEGIN=%s with active worker, Ansible state %s\n' "$scenario" "$runtime"

# Only the signed local repository is in the upgrade transaction.
apt-get "${new[@]}" -q -y upgrade >>/run/pxe-beta11.log 2>&1
grep -F 'PXE Tools: upgrade configured;' /run/pxe-beta11.log
versions '0.1.0~beta11'
test -z "$(dpkg --audit)"
test -z "$(dpkg --verify "${packages[@]}")"
sha256sum --check /run/pxe-state.sha256
python3 "$seed/fixture.py" verify
test "$(sqlite3 "$db" "SELECT value FROM settings WHERE key='upgrade_fixture_ciphertext'")" = "$cipher"
test "$(runuser -u www-data -- php -r 'require $argv[1]; echo \Admin\Util\Crypto::decrypt($argv[2]);' "$crypto" "$cipher")" = upgrade-fixture
test "$(python3 /usr/lib/pxe-tools/app/database_selection.py)" = "$db"
test "$(systemctl show -p FreezerState --value pxe-tools-worker.service)" = running
worker_after=$(systemctl show -p MainPID --value pxe-tools-worker.service)
test "$worker_after" -gt 0 && test "$worker_after" -ne "$worker_before"
wait_runtime
check_services
record_units >/run/pxe-units.after
diff -u /run/pxe-units.before /run/pxe-units.after
if [ "$scenario" = ansible-proxy ]; then
    test "$(id "$account")" = "$account_before"
    runuser -u "$account" -- ansible-playbook --version | head -1
fi
printf 'États des neuf unités, accès HTTP, clé maître, contenu chiffré et fichiers de fixture préservés.\n'
printf 'PXE_UPGRADE_PASS=%s\n' "$scenario"
