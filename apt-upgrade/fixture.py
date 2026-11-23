"""Seed synthetic beta 10 state and verify the real upgrade snapshot."""
from contextlib import closing
import json
import os
from pathlib import Path
import pwd
import sqlite3
import stat
import sys


APP = Path("/usr/lib/pxe-tools/app")
DATA = Path("/var/lib/pxe-tools")
CONF = Path("/etc/pxe-tools/db.conf")
DB = DATA / "upgrade-lab.sqlite"
UPGRADE = Path("/var/lib/pxe-tools-native/upgrade")
MAC = "02:00:00:00:00:42"
MACHINE = ("fixture-existing", "installed", "upgrade sentinel")


def seed(scenario, ciphertext, admin_hash):
    assert not (CONF.exists() or DB.exists())
    with closing(sqlite3.connect(DB)) as connection, connection:
        connection.executescript((APP / "db/schema.sqlite.sql").read_text())
        connection.execute("PRAGMA journal_mode=WAL")
        enable = "on" if scenario == "ansible-proxy" else "off"
        settings = {
            "pxe_ip": "192.0.2.1",
            "pxe_subnet": "192.0.2.0/24",
            "pxe_interface": "br-apt-lab",
            "pxe_enabled": enable,
            "dhcp_proxy_enabled": enable,
            "dhcp_proxy_network": "192.0.2.0",
            "dhcp_proxy_netmask": "255.255.255.0",
            "https_enabled": "off",
            "init_completed": "1",
            "db_init_done": "1",
            "admin_created": "1",
            "wizard_completed": "1",
            "catalog_auto_refresh_enabled": "off",
            "ansible_enabled": enable,
            "ansible_target_user": "ansible",
            "upgrade_fixture_ciphertext": ciphertext,
        }
        connection.executemany("INSERT INTO settings(key,value) VALUES(?,?)", settings.items())
        connection.execute("INSERT INTO machines(mac,hostname,status,notes) VALUES(?,?,?,?)", (MAC, *MACHINE))
        connection.execute("INSERT INTO users(username,password_hash) VALUES('fixture-admin',?)", (admin_hash,))
    account = pwd.getpwnam("www-data")
    os.chown(DB, account.pw_uid, account.pw_gid)
    os.chmod(DB, 0o660)
    with CONF.open("x") as config:
        json.dump({"driver": "sqlite", "path": str(DB)}, config)
    os.chown(CONF, 0, account.pw_gid)
    os.chmod(CONF, 0o640)


def verify_db(path):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as connection:
        assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert connection.execute(
            "SELECT hostname,status,notes FROM machines WHERE mac=?", (MAC,)
        ).fetchone() == MACHINE
        assert connection.execute("SELECT COUNT(*) FROM users WHERE username='fixture-admin'").fetchone() == (1,)
        assert connection.execute("SELECT value FROM settings WHERE key='ansible_target_user'").fetchone() == ("ansible",)
        return connection.execute("SELECT value FROM settings WHERE key='upgrade_fixture_ciphertext'").fetchone()[0]


def verify_snapshot():
    assert not (UPGRADE / "state.json").exists()
    (result,) = UPGRADE.glob("*/result.json")
    state = json.loads(result.read_text())
    assert state["phase"] == "complete" and state["version"] == "0.1.0~beta11"
    assert state["network_stayed_stopped"] == []
    assert state["units"]["pxe-tools-worker.service"]["active"] is True
    snapshot = result.parent / "database.sqlite"
    for path, expected_mode in ((UPGRADE, 0o700), (result.parent, 0o700), (result, 0o600), (snapshot, 0o600)):
        info = path.stat()
        assert info.st_uid == 0 and stat.S_IMODE(info.st_mode) == expected_mode
    assert verify_db(snapshot) == verify_db(DB)
    print("Snapshot privé terminé, avec intégrité SQLite et données de fixture préservées.")


if __name__ == "__main__":
    if sys.argv[1] == "seed":
        seed(*sys.argv[2:])
    elif sys.argv[1] == "verify":
        verify_snapshot()
    else:
        raise SystemExit("Expected seed or verify")
