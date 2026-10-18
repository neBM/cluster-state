#!/usr/bin/env python3
"""Bounded command-double fixtures for the REAL shell script, not DB/restore proof."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "apps/gitlab-helm/files/upgrade-admission.sh"

# Only native client commands are doubled. Files, permissions, hashes, rename,
# timeout, version policy and shell control flow run for real.
DOUBLE = r'''#!/usr/bin/env python3
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
mode = os.environ.get("FIXTURE_MODE", "ok")
work = pathlib.Path(os.environ["FIXTURE_STATE"])
with (work / "calls").open("a") as f:
    f.write(name + " " + " ".join(sys.argv[1:]) + "\n")
if "--version" in sys.argv:
    print(name + " (PostgreSQL) " + ("18.0" if mode == "client" else "17.10"))
    sys.exit(0)
if name == "psql":
    sql = sys.stdin.read()
    assert "status IS NULL OR status NOT IN (3, 6)" in sql
    assert "public.schema_migrations" in sql
    assert "ON_ERROR_STOP=1" in sys.argv
    assert os.environ["PGOPTIONS"].find("default_transaction_read_only=on") >= 0
    assert "statement_timeout=30000" in os.environ["PGOPTIONS"]
    assert pathlib.Path(os.environ["PGPASSFILE"]).stat().st_mode & 0o777 == 0o600
    n = int((work / "queries").read_text()) + 1 if (work / "queries").exists() else 1
    (work / "queries").write_text(str(n))
    if mode == "query" or (mode == "recheck-query" and n > 2):
        print("fixture diagnostic should not escape", file=sys.stderr)
        sys.exit(2)
    fields = ["on", "170010", "gitlabhq_production", "gitlab", "192.0.2.10", "5432", "public", "native", "a"*32, "131", "0"]
    # PostgreSQL17 inet::text includes mask bits; host(inet) is the plain address.
    # IPv4 form was observed in the independent actual native TCP qualification.
    if mode == "tcp-inet":
        fields[4] = "10.244.0.10" if "host(inet_server_addr())" in sql else "10.244.0.10/32"
    if mode == "tcp-inet6":
        fields[4] = "2001:db8::10" if "host(inet_server_addr())" in sql else "2001:db8::10/128"
    if mode == "readwrite": fields[0] = "off"
    if mode == "server": fields[1] = "180001"
    if mode == "schema": fields[7] = "unknown"
    if mode == "malformed": fields[9] = "not-a-count"
    if mode == "null": fields[10] = "1"
    if mode.startswith("status-"): fields[10] = "1"
    if mode == "identity" and n % 2 == 0: fields[4] = "192.0.2.11"
    if mode == "recheck" and n > 2: fields[8] = "b"*32
    if mode == "empty-query": sys.exit(0)
    print("|".join(fields))
    if mode == "extra-output": print("unexpected")
elif name == "pg_dump":
    if mode in ("dump", "interrupted", "full"): sys.exit(1)
    target = pathlib.Path(sys.argv[sys.argv.index("--file") + 1])
    target.write_bytes(b"" if mode == "empty-dump" else b"PGDMP-fixture-not-a-real-archive")
    if mode == "rename":
        # Force final publication collision without replacing another archive.
        final = target.parent.parent / target.parent.name.removeprefix(".")
        final.mkdir()
elif name == "pg_restore":
    if mode in ("restore-list", "malformed-dump"): sys.exit(1)
    if mode == "readback": pathlib.Path(sys.argv[-1]).write_bytes(b"tampered")
    print("; fixture archive listing")
'''


class AdmissionFixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        for directory in ("bin", "chart", "recovery", "work", "state"):
            (self.base / directory).mkdir()
        (self.base / "chart/gitlabVersion").write_text("v19.5.0\n")
        (self.base / "chart/gitlabChartVersion").write_text("10.5.0\n")
        (self.base / "password").write_text("fixture:private\\value\n")
        for command in ("psql", "pg_dump", "pg_restore"):
            p = self.base / "bin" / command
            p.write_text(DOUBLE)
            p.chmod(0o755)
        # CI's toolchain may be root. Exercise the actual UID/GID1000 contract
        # by dropping privileges, never by faking id(1) or weakening the script.
        self.child_identity = {}
        if os.geteuid() == 0:
            for p in [self.base, *self.base.rglob("*")]:
                os.chown(p, 1000, 1000)
            self.child_identity = {"user": 1000, "group": 1000, "extra_groups": []}
        elif (os.geteuid(), os.getegid()) != (1000, 1000):
            self.skipTest("fixtures require UID/GID1000 or root for a real privilege drop")
        self.env = dict(os.environ, PATH=f"{self.base / 'bin'}:{os.environ['PATH']}",
                        CHART_INFO_DIR=str(self.base / "chart"), RECOVERY_DIR=str(self.base / "recovery"),
                        WORK_DIR=str(self.base / "work"), DB_PASSWORD_FILE=str(self.base / "password"),
                        GITLAB_VERSION="v19.5.0", CHART_VERSION="10.5.0", PGHOST="192.0.2.10", PGPORT="5433",
                        PGDATABASE="gitlabhq_production", PGUSER="gitlab", CI_DB_HOST="192.0.2.10",
                        CI_DB_PORT="5433", CI_DB_NAME="gitlabhq_production", CI_DATABASE_TASKS="false",
                        FIXTURE_STATE=str(self.base / "state"))

    def run_script(self, mode="ok", allowed=False):
        self.assertTrue(SCRIPT.is_file(), "admission script is missing")
        result = subprocess.run(["bash", str(SCRIPT)], env=dict(self.env, FIXTURE_MODE=mode),
                                capture_output=True, text=True, timeout=15, **self.child_identity)
        self.assertEqual(result.returncode == 0, allowed, result.stdout + result.stderr)
        self.assertNotIn("fixture:private", result.stdout + result.stderr)
        self.assertNotIn("fixture diagnostic", result.stdout + result.stderr)
        calls = self.base / "state/calls"
        if calls.exists():
            self.assertNotIn("fixture:private", calls.read_text())
        self.assertEqual(list((self.base / "work").iterdir()), [], "private pgpass left behind")
        return result

    def test_success_private_verified_publication(self):
        self.run_script(allowed=True)
        archives = self.base / "recovery/db-archives"
        published = list(archives.iterdir())
        self.assertEqual(len(published), 1)
        archive = published[0]
        self.assertFalse(archive.name.startswith("."))
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
        self.assertEqual(archives.stat().st_mode & 0o777, 0o700)
        for file in archive.iterdir():
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        subprocess.run(["sha256sum", "--check", "database.sha256"], cwd=archive, check=True, capture_output=True)
        self.assertEqual((self.base / "state/queries").read_text(), "4")

    def test_patch_and_chart_only_maintenance(self):
        for version, chart in (("19.5.1", "10.5.1"), ("19.5.0", "10.5.1")):
            with self.subTest(version=version):
                self.env.update(GITLAB_VERSION=version, CHART_VERSION=chart)
                self.run_script(allowed=True)

    def test_tcp_inet_addresses_use_canonical_host(self):
        # Fixture evaluates the selected SQL representation, not a live DB query.
        # Do not admit CIDR by broadening the observation regex.
        self.assertIn("[0-9a-fA-F:.]+", SCRIPT.read_text())
        for mode in ("tcp-inet", "tcp-inet6"):
            with self.subTest(mode=mode):
                self.run_script(mode, allowed=True)

    def test_strict_versions_and_unsupported_paths(self):
        for version in ("", "19.5", "19.5.0-rc1", "19.5.0junk", "019.5.0", "19.4.9", "19.6.0", "19.8.0", "20.0.0", "18.11.9"):
            with self.subTest(version=version):
                self.env["GITLAB_VERSION"] = version
                self.run_script()

    def test_previous_versions_missing_and_unknown(self):
        for version in ("", "19.5.0-pre", "19.4.9", "20.5.0", "19.5.1"):
            with self.subTest(version=version):
                (self.base / "chart/gitlabVersion").write_text(version)
                self.run_script()
        (self.base / "chart/gitlabVersion").unlink()
        self.run_script()

    def test_chart_downgrade_malformed_or_incompatible(self):
        for chart in ("10.4.9", "10.5.0-rc1", "11.5.0", "10.6.0", "10.05.0"):
            with self.subTest(chart=chart):
                self.env["CHART_VERSION"] = chart
                self.run_script()
        self.env["CHART_VERSION"] = "10.5.0"
        (self.base / "chart/gitlabChartVersion").write_text("10.5.1")
        self.run_script()

    def test_denied_database_and_dump_observations(self):
        for mode in ("query", "empty-query", "extra-output", "readwrite", "server", "client", "schema", "malformed", "null",
                     "status-0", "status-1", "status-2", "status-4", "status-5", "status-7", "status-unknown",
                     "identity", "recheck", "recheck-query", "dump", "interrupted", "full", "empty-dump",
                     "restore-list", "malformed-dump", "rename", "readback"):
            with self.subTest(mode=mode):
                self.run_script(mode)
                (self.base / "state/queries").unlink(missing_ok=True)
        # No failed attempt published a dump; collision directory is empty.
        self.assertFalse(list((self.base / "recovery").rglob("database.dump")))

    def test_future_split_database_denied_before_connection(self):
        for field, value in (("CI_DB_NAME", "gitlab_ci"), ("CI_DB_HOST", "192.0.2.11"),
                             ("CI_DB_PORT", "5432"), ("CI_DATABASE_TASKS", "true")):
            with self.subTest(field=field):
                original = self.env[field]
                self.env[field] = value
                self.run_script()
                self.env[field] = original
        self.assertFalse((self.base / "state/calls").exists())

    def test_missing_password_and_unwritable_destination(self):
        (self.base / "password").unlink()
        self.run_script()
        (self.base / "password").write_text("fixture-private")
        if os.geteuid() == 0:
            os.chown(self.base / "password", 1000, 1000)
        recovery = self.base / "recovery"
        recovery.chmod(0o500)
        self.addCleanup(recovery.chmod, 0o700)
        self.run_script()
        self.assertFalse(list(recovery.iterdir()))

    def test_missing_and_insecure_destination_not_repaired(self):
        self.env["RECOVERY_DIR"] = str(self.base / "absent")
        self.run_script()
        self.env["RECOVERY_DIR"] = str(self.base / "recovery")
        archives = self.base / "recovery/db-archives"
        archives.mkdir(mode=0o755)
        self.run_script()
        self.assertEqual(archives.stat().st_mode & 0o777, 0o755)
        archives.rmdir()
        archives.symlink_to(self.base / "work", target_is_directory=True)
        self.run_script()


if __name__ == "__main__":
    unittest.main()
