"""Adapt the signed beta upgrade fixture to the beta 12 and Rust pair."""
from pathlib import Path
import json
import re


root = Path(__file__).resolve().parent
published = json.loads(Path('pxe-tools/packaging/ci/release-manifest.json').read_text())
assert published['version'] == '0.1.0~beta12'
assert published['ansible_version'] == '0.1.0~beta12'
for name in ('runner.sh', 'guest.sh', 'fixture.py'):
    path = root / name
    text = re.sub(r'beta1[01]', lambda match:
                  {'beta10': 'beta12', 'beta11': 'rust1'}[match[0]], path.read_text())
    if name == 'runner.sh':
        for old, digest in (
            ('0aca46396b5a98d8798790e1fa6fe2126f93e5edfc9d168dcb6dfdbec5187e14', published['package_sha256']),
            ('dfc09bb232d3496a60631abb6bf72b9acff57a3411d88b56d80251d5b06ba887', published['ansible_package_sha256']),
        ):
            assert text.count(old) == 1 and re.fullmatch(r'[0-9a-f]{64}', digest)
            text = text.replace(old, digest)
    if name == 'guest.sh':
        previous = '''wait_runtime
check_services
record_units >/run/pxe-units.after
diff -u /run/pxe-units.before /run/pxe-units.after'''
        guided = r'''wait_runtime
systemctl is-active --quiet pxe-tools-admin.target
systemctl is-active --quiet pxe-tools-pxe-http.service
systemctl is-active --quiet pxe-tools-worker.service
test "$(systemctl show -p ActiveState --value pxe-tools-nginx.service)" = inactive
test "$(systemctl show -p ActiveState --value pxe-tools-php.service)" = inactive
pid=$(systemctl show -p MainPID --value pxe-tools-pxe-http.service)
test "$(readlink "/proc/$pid/exe")" = /usr/lib/pxe-tools/pxe-tools-rust
test "$(curl -fsS --max-time 10 http://127.0.0.1/healthz)" = ok
fingerprint=$(openssl x509 -in /run/pxe-tools-rust-guided/cert.pem -pubkey -noout |
    openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A)
curl -fsSk --max-time 10 --pinnedpubkey "sha256//$fingerprint" \
    -u fixture-admin:fixture-admin-password https://127.0.0.1/admin/devices |
    grep -F fixture-existing
if [ "$scenario" = ansible-proxy ]; then
    systemctl is-active --quiet pxe-tools-dnsmasq.service
    grep -qx 'dhcp-range=192.0.2.0,proxy,255.255.255.0' /var/lib/pxe-tools-native/rendered/dnsmasq.conf
    test "$(curl -fsS --max-time 10 http://192.0.2.1/healthz)" = ok
else
    test "$(systemctl show -p ActiveState --value pxe-tools-dnsmasq.service)" = inactive
fi
record_units >/run/pxe-units.after
python3 - <<'PY'
from pathlib import Path
def states(path):
    chunks = Path(path).read_text().splitlines()
    return {chunks[i]:dict(line.split('=',1) for line in chunks[i+1:i+3])
            for i in range(0,len(chunks),3)}
expected = states('/run/pxe-units.before')
expected['pxe-tools-nginx.service']['ActiveState'] = 'inactive'
expected['pxe-tools-php.service']['ActiveState'] = 'inactive'
expected['pxe-tools-pxe-http.service']['ActiveState'] = 'active'
assert states('/run/pxe-units.after') == expected
PY'''
        assert text.count(previous) == 1
        text = text.replace(previous, guided)
        before, after = text.split('# Only the signed local repository is in the upgrade transaction.', 1)
        verification = '''test "$(runuser -u www-data -- php -r 'require $argv[1]; echo \\Admin\\Util\\Crypto::decrypt($argv[2]);' "$crypto" "$cipher")" = upgrade-fixture'''
        replacement = '''test "$(runuser -u www-data -- /usr/bin/python3 -c 'import sys; sys.path.insert(0,"/usr/lib/pxe-tools/app"); from crypto import decrypt; print(decrypt(sys.argv[1]))' "$cipher")" = upgrade-fixture'''
        assert after.count(verification) == 1
        text = before + '# Only the signed local repository is in the upgrade transaction.' + after.replace(
            verification,replacement,
        )
    path.write_text(text)
