#!/usr/bin/env bash
set -euo pipefail

case "$SCENARIO" in base|ansible-proxy) ;; *) exit 2 ;; esac
[[ "$BUILD_RUN" =~ ^[1-9][0-9]+$ && "$SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]]
test "$(cat candidate/source-commit.txt)" = "$SOURCE_COMMIT"
lab=$(mktemp -d "$RUNNER_TEMP/pxe-upgrade.XXXXXXXX")
seed="$lab/seed"
mkdir -p "$seed/beta10" "$seed/beta11" upgrade-proof
printf 'source=%s\ncandidate_run=%s\nscenario=%s\n' "$SOURCE_COMMIT" "$BUILD_RUN" "$SCENARIO" \
    | tee upgrade-proof/provenance.txt

sudo apt-get -qq update
sudo apt-get -qq -y install --no-install-recommends apt-utils gnupg qemu-system-x86 qemu-utils xorriso
cloud=https://cloud.debian.org/images/cloud/trixie/20261116-2664/debian-13-genericcloud-amd64-20261116-2664.qcow2
curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5 --retry 3 "$cloud" -o "$lab/debian.qcow2"
printf '%s  %s\n' 37cb32b320820417eb04b335afcf489bfb4cecce4a957190d09cb2bffbe02b56a1cadd62d78c6ead92aa7839d5ea65e4260f994bbb4b54490df59fdf11ee1d97 \
    "$lab/debian.qcow2" | sha512sum --check

stage_beta10() {
    local name=$1 architecture=$2 digest=$3
    local file="$seed/beta10/${name}_0.1.0-beta10_${architecture}.deb"
    curl --proto '=https' -fsS --retry 3 \
        "https://packages.pxetools.com/apt/pool/main/p/pxe-tools/pxe-tools-$digest.deb" -o "$file"
    printf '%s  %s\n' "$digest" "$file" | sha256sum --check
    test "$(dpkg-deb -f "$file" Package)" = "$name"
    test "$(dpkg-deb -f "$file" Version)" = '0.1.0~beta10'
    test "$(dpkg-deb -f "$file" Architecture)" = "$architecture"
    printf '%s  %s\n' "$digest" "$(basename "$file")" | tee -a upgrade-proof/provenance.txt
}

stage_beta11() {
    local name=$1 architecture=$2 checksum_file=$3
    local asset="${name}_0.1.0-beta11_${architecture}.deb"
    local file="candidate/$asset"
    local digest
    digest=$(cat "candidate/$checksum_file")
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]]
    printf '%s  %s\n' "$digest" "$file" | sha256sum --check
    test "$(dpkg-deb -f "$file" Package)" = "$name"
    test "$(dpkg-deb -f "$file" Version)" = '0.1.0~beta11'
    test "$(dpkg-deb -f "$file" Architecture)" = "$architecture"
    test "$(stat -c %s "$file")" -le 26214400
    install -m 0644 "$file" "$seed/beta11/$asset"
    printf '%s  %s\n' "$digest" "$asset" | tee -a upgrade-proof/provenance.txt
}

stage_beta10 pxe-tools amd64 0aca46396b5a98d8798790e1fa6fe2126f93e5edfc9d168dcb6dfdbec5187e14
stage_beta10 pxe-tools-ansible all dfc09bb232d3496a60631abb6bf72b9acff57a3411d88b56d80251d5b06ba887
stage_beta11 pxe-tools amd64 package.sha256
stage_beta11 pxe-tools-ansible all ansible-package.sha256

# Sign two flat APT repositories with an ephemeral key used only inside this VM.
export GNUPGHOME="$lab/gnupg"
install -d -m 0700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
    'PXE Tools Upgrade Fixture <apt-lab@example.invalid>' rsa2048 sign 1d
gpg --batch --export > "$seed/fixture-keyring.gpg"
for tier in beta10 beta11; do
    (
        cd "$seed/$tier"
        apt-ftparchive packages . > Packages
        apt-ftparchive release . > Release
        gpg --batch --pinentry-mode loopback --passphrase '' --clearsign -o InRelease Release
    )
done
printf '%s\n' "$SCENARIO" > "$seed/scenario"
printf 'instance-id: pxe-apt-upgrade-fixture\nlocal-hostname: pxe-apt-upgrade-fixture\n' > "$seed/meta-data"
bash -n apt-upgrade/guest.sh
install -m 0755 apt-upgrade/guest.sh "$seed/user-data"
install -m 0644 apt-upgrade/fixture.py "$seed/fixture.py"
xorriso -as mkisofs -quiet -volid cidata -joliet -rock -o "$lab/seed.iso" "$seed"
qemu-img create -q -f qcow2 -F qcow2 -b "$lab/debian.qcow2" "$lab/guest.qcow2" 8G

launcher=()
accel=(-accel tcg)
if [ -c /dev/kvm ]; then
    kvm_gid=$(stat -c '%g' /dev/kvm)
    kvm=(sudo -n -- setpriv --reuid "$(id -u)" --regid "$kvm_gid" --init-groups --)
    if "${kvm[@]}" python3 -c 'import os,fcntl; fd=os.open("/dev/kvm",os.O_RDWR); os.close(fcntl.ioctl(fd,0xAE01,0)); os.close(fd)'; then
        launcher=("${kvm[@]}")
        accel=(-accel kvm -cpu host)
    fi
fi
printf 'QEMU mode %s\n' "${accel[*]}" | tee -a upgrade-proof/provenance.txt
status=0
timeout 19m "${launcher[@]}" qemu-system-x86_64 -machine pc "${accel[@]}" -m 2048 -smp 2 \
    -display none -monitor none -no-reboot -boot c \
    -serial "file:$lab/kernel.log" -serial stdio \
    -drive "file=$lab/guest.qcow2,if=virtio,format=qcow2" \
    -drive "file=$lab/seed.iso,format=raw,media=cdrom,readonly=on" \
    -netdev user,id=bootstrap -device virtio-net-pci,netdev=bootstrap \
    </dev/null | tr -d '\r' | tee upgrade-proof/guest.txt || status=$?
if [ "$status" -ne 0 ] || ! grep -qx "PXE_UPGRADE_PASS=$SCENARIO" upgrade-proof/guest.txt; then
    tail -n 45 "$lab/kernel.log"
    exit 1
fi
grep -qx 'PXE_UPGRADE_EXIT=0' upgrade-proof/guest.txt
