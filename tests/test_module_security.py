"""Behavioral and static security regression tests for PG18, ntfy, tailscale, OS, and board modules."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import subprocess
import tarfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PG18_FORGE = REPO_ROOT / "postgresql" / "18-6-io_uring" / "forge.sh"
NTFY_FORGE = REPO_ROOT / "mods" / "ntfy" / "forge.sh"
TAILSCALE_FORGE = REPO_ROOT / "mods" / "tailscale" / "forge.sh"


def _find_bash() -> str:
    for candidate in (shutil.which("bash"), "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
        if not candidate or not Path(candidate).is_file():
            continue
        proc = subprocess.run(
            [candidate, "-c", "printf '%s' \"${BASH_VERSINFO[0]}\""],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.isdigit() and int(proc.stdout) >= 4:
            return candidate
    pytest.skip("Bash >= 4.0 is required for RVDK module security tests")
    raise AssertionError("unreachable")


BASH_BIN = _find_bash()


def _run_bash(script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [BASH_BIN, "-c", script],
        capture_output=True,
        text=True,
        env=merged_env,
        check=False,
    )


def _write_exe(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


def _extract_bash_function(file_path: Path, fn_name: str) -> str:
    text = file_path.read_text(encoding="utf-8")
    pattern = re.compile(rf"(?ms)^{re.escape(fn_name)}\(\)\s*\{{.*?^\}}")
    match = pattern.search(text)
    assert match is not None, f"Could not extract {fn_name}() from {file_path}"
    return match.group(0)


def _make_install_shim(bin_dir: Path, log_path: Path) -> Path:
    return _write_exe(
        bin_dir / "install",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{log_path}"
is_dir="false"
mode=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) is_dir="true"; shift ;;
        -m) mode="${{2:-}}"; shift 2 ;;
        -o|-g) shift 2 ;;
        --) shift; while [[ $# -gt 0 ]]; do args+=("$1"); shift; done ;;
        *) args+=("$1"); shift ;;
    esac
done
if [[ "$is_dir" == "true" ]]; then
    for d in "${{args[@]}}"; do
        mkdir -p "$d"
        [[ -n "$mode" ]] && chmod "$mode" "$d"
    done
else
    dst="${{args[-1]}}"
    src_count=$(( ${{#args[@]}} - 1 ))
    for (( i=0; i<src_count; i++ )); do
        s="${{args[$i]}}"
        if [[ -d "$dst" || "$dst" == */ ]]; then
            mkdir -p "$dst"
            out="${{dst%/}}/$(basename "$s")"
        else
            mkdir -p "$(dirname "$dst")"
            out="$dst"
        fi
        cp -f "$s" "$out"
        [[ -n "$mode" ]] && chmod "$mode" "$out"
    done
fi
""",
    )


def _make_chown_shim(bin_dir: Path, log_path: Path) -> Path:
    return _write_exe(
        bin_dir / "chown",
        f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{log_path}"
exit 0
""",
    )


def _make_chmod_spy(bin_dir: Path, log_path: Path) -> Path:
    real_chmod = shutil.which("chmod") or "/bin/chmod"
    return _write_exe(
        bin_dir / "chmod",
        f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{log_path}"
exec "{real_chmod}" "$@"
""",
    )


def _pg18_helpers_src() -> str:
    fns = [
        "_pg_purge_local_repo_cache",
        "_pg_verify_local_repo_debs",
        "_pg_write_debs_manifest",
        "_pg_verify_debs_manifest",
        "_pg_stage_built_debs",
        "update_local_repo",
        "_pg_reconcile_installed_local_repo",
    ]
    return "\n\n".join(_extract_bash_function(PG18_FORGE, fn) for fn in fns)


class TestPg18BuildUserSymlinkIsolation:
    def test_stage_built_debs_installs_regular_debs_without_chown(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        install_log = tmp_path / "install.log"
        chown_log = tmp_path / "chown.log"
        _make_install_shim(bin_dir, install_log)
        _make_chown_shim(bin_dir, chown_log)

        work_dir = tmp_path / "build" / "work"
        repo_dir = tmp_path / "debs"
        work_dir.mkdir(parents=True)
        repo_dir.mkdir(parents=True)

        deb_a = work_dir / "postgresql-18_18.6-1_riscv64.deb"
        deb_b = work_dir / "postgresql-client-18_18.6-1_riscv64.deb"
        deb_a.write_bytes(b"deb-a-payload")
        deb_b.write_bytes(b"deb-b-payload")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
BUILD_USER="_apt"
LOCAL_REPO_DIR="{repo_dir}"
{_pg18_helpers_src()}
_pg_stage_built_debs "{work_dir}" "{repo_dir}"
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert not chown_log.exists(), "chown must never be invoked on untrusted build output"

        install_lines = install_log.read_text(encoding="utf-8").splitlines()
        assert len(install_lines) == 2
        assert all("-m 0644 -o root -g root" in line for line in install_lines)
        assert (repo_dir / deb_a.name).read_bytes() == b"deb-a-payload"
        assert (repo_dir / deb_b.name).read_bytes() == b"deb-b-payload"
        assert stat.S_IMODE((repo_dir / deb_a.name).stat().st_mode) == 0o644

    @pytest.mark.parametrize(
        "mode",
        [
            "symlink_to_secret",
            "broken_symlink",
            "dir_named_deb",
            "empty_work_dir",
            "symlink_work_dir",
            "hidden_dot_deb",
        ],
    )
    def test_stage_built_debs_rejects_symlinks_and_non_regular_entries(
        self, tmp_path: Path, mode: str
    ) -> None:
        bin_dir = tmp_path / "bin"
        install_log = tmp_path / "install.log"
        chown_log = tmp_path / "chown.log"
        _make_install_shim(bin_dir, install_log)
        _make_chown_shim(bin_dir, chown_log)

        secret = tmp_path / "secret_target"
        secret.write_text("SECRET_CONTENT", encoding="utf-8")
        secret.chmod(0o600)

        repo_dir = tmp_path / "debs"
        repo_dir.mkdir()
        work_dir = tmp_path / "build" / "work"

        if mode == "symlink_work_dir":
            real_work = tmp_path / "outside_work"
            real_work.mkdir()
            (real_work / "evil_1.0_riscv64.deb").write_bytes(b"evil")
            work_dir.parent.mkdir(parents=True)
            work_dir.symlink_to(real_work)
        else:
            work_dir.mkdir(parents=True)
            if mode == "symlink_to_secret":
                (work_dir / "good_1.0_riscv64.deb").write_bytes(b"ok")
                (work_dir / "evil_1.0_riscv64.deb").symlink_to(secret)
            elif mode == "broken_symlink":
                (work_dir / "broken_1.0_riscv64.deb").symlink_to(tmp_path / "does_not_exist")
            elif mode == "dir_named_deb":
                (work_dir / "dir_1.0_riscv64.deb").mkdir()
            elif mode == "hidden_dot_deb":
                (work_dir / "good_1.0_riscv64.deb").write_bytes(b"ok")
                (work_dir / ".hidden_1.0_all.deb").write_bytes(b"evil")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
BUILD_USER="_apt"
LOCAL_REPO_DIR="{repo_dir}"
{_pg18_helpers_src()}
_pg_stage_built_debs "{work_dir}" "{repo_dir}"
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode != 0
        assert not install_log.exists()
        assert not chown_log.exists()
        assert list(repo_dir.glob("*.deb")) == []
        assert stat.S_IMODE(secret.stat().st_mode) == 0o600
        assert secret.read_text(encoding="utf-8") == "SECRET_CONTENT"

    @pytest.mark.parametrize(
        "mode",
        ["symlink_to_secret", "broken_symlink", "dir_named_deb", "hidden_dot_deb", "nested_subdir_deb"],
    )
    def test_update_local_repo_rejects_symlinks_and_non_regular_before_chmod(
        self, tmp_path: Path, mode: str
    ) -> None:
        bin_dir = tmp_path / "bin"
        chmod_log = tmp_path / "chmod.log"
        scan_log = tmp_path / "dpkg_scan.log"
        _make_chmod_spy(bin_dir, chmod_log)
        _make_chown_shim(bin_dir, tmp_path / "chown.log")
        _write_exe(
            bin_dir / "dpkg-scanpackages",
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{scan_log}"\nexit 0\n',
        )
        _write_exe(bin_dir / "apt-get", "#!/usr/bin/env bash\nexit 0\n")

        secret = tmp_path / "secret_target"
        secret.write_text("SECRET_CONTENT", encoding="utf-8")
        secret.chmod(0o600)

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)
        (repo_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"real-deb")

        if mode == "symlink_to_secret":
            (repo_dir / "evil.deb").symlink_to(secret)
        elif mode == "broken_symlink":
            (repo_dir / "evil.deb").symlink_to(tmp_path / "missing_target")
        elif mode == "dir_named_deb":
            (repo_dir / "evil.deb").mkdir()
        elif mode == "hidden_dot_deb":
            (repo_dir / ".evil.deb").write_bytes(b"hidden-rogue")
        elif mode == "nested_subdir_deb":
            (repo_dir / "pool").mkdir()
            (repo_dir / "pool" / "rogue.deb").write_bytes(b"nested-rogue")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
PG_LIB_ROOT="{pg_lib}"
LOCAL_REPO_DIR="{repo_dir}"
LOCAL_LIST="{tmp_path}/rvdk-local-pgdg.list"
WANT_LOCAL_LIST="deb [trusted=yes check-date=no lang=none] file://{repo_dir} ./"
rvdk_apt_has_lists() {{ return 0; }}
rvdk_apt_update() {{ return 0; }}
{_pg18_helpers_src()}
update_local_repo
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode != 0
        assert "[RVDK:FATAL]" in proc.stderr
        assert stat.S_IMODE(secret.stat().st_mode) == 0o600
        assert not scan_log.exists()
        if chmod_log.exists():
            assert "evil.deb" not in chmod_log.read_text(encoding="utf-8")

    def test_update_local_repo_indexes_regular_debs_and_avoids_unsafe_chown_mv(
        self, tmp_path: Path
    ) -> None:
        pg_text = PG18_FORGE.read_text(encoding="utf-8")
        assert 'chown 0:0 "${BUILD_DIR}/work"' not in pg_text
        assert "chmod 0644 Packages Packages.gz ./*.deb" not in pg_text

        bin_dir = tmp_path / "bin"
        _make_chown_shim(bin_dir, tmp_path / "chown.log")
        _write_exe(
            bin_dir / "dpkg-scanpackages",
            "#!/usr/bin/env bash\nprintf 'Package: postgresql-18\\nVersion: 18.6\\n'\n",
        )
        _write_exe(
            bin_dir / "apt-ftparchive",
            "#!/usr/bin/env bash\nprintf 'Origin: RVDK\\nLabel: RVDK-PGDG\\n'\n",
        )
        _write_exe(bin_dir / "apt-get", "#!/usr/bin/env bash\nexit 0\n")

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)
        deb_file = repo_dir / "postgresql-18_18.6-1_riscv64.deb"
        deb_file.write_bytes(b"real-deb-bytes")
        deb_file.chmod(0o600)

        local_list = tmp_path / "rvdk-local-pgdg.list"
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
PG_LIB_ROOT="{pg_lib}"
LOCAL_REPO_DIR="{repo_dir}"
LOCAL_LIST="{local_list}"
WANT_LOCAL_LIST="deb [trusted=yes check-date=no lang=none] file://{repo_dir} ./"
rvdk_apt_has_lists() {{ return 0; }}
rvdk_apt_update() {{ return 0; }}
{_pg18_helpers_src()}
shopt -s nullglob
_pg_write_debs_manifest "{repo_dir}"
update_local_repo
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert stat.S_IMODE(deb_file.stat().st_mode) == 0o644
        assert (repo_dir / "Packages").is_file()
        assert (repo_dir / "Packages.gz").is_file()
        assert (repo_dir / "Release").is_file()
        assert local_list.read_text(encoding="utf-8").strip().startswith("deb [trusted=yes")


class TestPg18LocalRepoManifestTamperDetection:
    def _seed_verified_repo(self, tmp_path: Path) -> tuple[Path, dict[str, str]]:
        bin_dir = tmp_path / "bin"
        chown_log = tmp_path / "chown.log"
        _make_chown_shim(bin_dir, chown_log)

        repo_dir = tmp_path / "debs"
        repo_dir.mkdir()
        (repo_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"pg18-server-bytes")
        (repo_dir / "postgresql-client-18_18.6-1_riscv64.deb").write_bytes(b"pg18-client-bytes")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
LOCAL_REPO_DIR="{repo_dir}"
{_pg18_helpers_src()}
_pg_write_debs_manifest "{repo_dir}"
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        proc = _run_bash(script, env=env)
        assert proc.returncode == 0, proc.stderr
        assert "root:root" in chown_log.read_text(encoding="utf-8")
        return repo_dir, env

    def test_write_and_verify_debs_manifest_happy_path(self, tmp_path: Path) -> None:
        repo_dir, env = self._seed_verified_repo(tmp_path)
        manifest = repo_dir / ".rvdk-debs.sha256"
        assert manifest.is_file()
        assert stat.S_IMODE(manifest.stat().st_mode) == 0o644

        expected_lines = [
            f"{hashlib.sha256(b'pg18-server-bytes').hexdigest()}  postgresql-18_18.6-1_riscv64.deb",
            f"{hashlib.sha256(b'pg18-client-bytes').hexdigest()}  postgresql-client-18_18.6-1_riscv64.deb",
        ]
        assert manifest.read_text(encoding="utf-8").splitlines() == expected_lines

        verify = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
LOCAL_REPO_DIR="{repo_dir}"
{_pg18_helpers_src()}
_pg_verify_debs_manifest "{repo_dir}"
""",
            env=env,
        )
        assert verify.returncode == 0, verify.stderr

    @pytest.mark.parametrize(
        "tamper_kind",
        [
            "modified_deb",
            "rogue_extra_deb",
            "hidden_dot_deb",
            "nested_subdir_deb",
            "missing_manifest",
            "missing_tracked_deb",
            "symlink_deb",
            "symlink_manifest",
            "malformed_manifest",
            "traversal_manifest",
            "duplicate_manifest_entry",
        ],
    )
    def test_verify_debs_manifest_rejects_tamper(self, tmp_path: Path, tamper_kind: str) -> None:
        repo_dir, env = self._seed_verified_repo(tmp_path)
        manifest = repo_dir / ".rvdk-debs.sha256"

        if tamper_kind == "modified_deb":
            (repo_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"TAMPERED-BYTES")
        elif tamper_kind == "rogue_extra_deb":
            (repo_dir / "rogue-backdoor_9.9_all.deb").write_bytes(b"ROGUE-DEB")
        elif tamper_kind == "hidden_dot_deb":
            (repo_dir / ".rogue_9.9_all.deb").write_bytes(b"HIDDEN-ROGUE")
        elif tamper_kind == "nested_subdir_deb":
            (repo_dir / "pool").mkdir()
            (repo_dir / "pool" / "rogue_9.9_all.deb").write_bytes(b"NESTED-ROGUE")
        elif tamper_kind == "missing_manifest":
            manifest.unlink()
        elif tamper_kind == "missing_tracked_deb":
            (repo_dir / "postgresql-client-18_18.6-1_riscv64.deb").unlink()
        elif tamper_kind == "symlink_deb":
            outside = tmp_path / "outside.deb"
            outside.write_bytes(b"pg18-client-bytes")
            target = repo_dir / "postgresql-client-18_18.6-1_riscv64.deb"
            target.unlink()
            target.symlink_to(outside)
        elif tamper_kind == "symlink_manifest":
            outside_man = tmp_path / "outside.sha256"
            outside_man.write_text(manifest.read_text(encoding="utf-8"), encoding="utf-8")
            manifest.unlink()
            manifest.symlink_to(outside_man)
        elif tamper_kind == "malformed_manifest":
            manifest.write_text("not-a-valid-sha256  postgresql-18_18.6-1_riscv64.deb\n", encoding="utf-8")
        elif tamper_kind == "traversal_manifest":
            fake_sha = hashlib.sha256(b"x").hexdigest()
            manifest.write_text(f"{fake_sha}  ../evil.deb\n", encoding="utf-8")
        elif tamper_kind == "duplicate_manifest_entry":
            first_line = manifest.read_text(encoding="utf-8").splitlines()[0]
            manifest.write_text(f"{first_line}\n{first_line}\n", encoding="utf-8")

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
LOCAL_REPO_DIR="{repo_dir}"
{_pg18_helpers_src()}
_pg_verify_debs_manifest "{repo_dir}"
""",
            env=env,
        )
        assert proc.returncode != 0

    @pytest.mark.parametrize("case", ["valid_cache", "modified_deb", "rogue_extra_deb", "missing_manifest"])
    def test_pg18_cache_check_behavior_on_rerun(self, tmp_path: Path, case: str) -> None:
        repo_dir, env = self._seed_verified_repo(tmp_path)
        manifest = repo_dir / ".rvdk-debs.sha256"
        if case == "modified_deb":
            (repo_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"TAMPERED")
        elif case == "rogue_extra_deb":
            (repo_dir / "rogue_1.0_all.deb").write_bytes(b"ROGUE")
        elif case == "missing_manifest":
            manifest.unlink()

        pg_text = PG18_FORGE.read_text(encoding="utf-8")
        match = re.search(
            r'(?ms)^\s*HAVE_VERIFIED_LOCAL_DEBS="false"\n.*?(?=^\s*if \[\[ "\$HAVE_VERIFIED_LOCAL_DEBS" == "false" \]\]; then)',
            pg_text,
        )
        assert match is not None, "Could not locate HAVE_VERIFIED_LOCAL_DEBS check block in PG18 forge.sh"
        cache_check_block = match.group(0)

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
PG_VERSION="18"
LOCAL_REPO_DIR="{repo_dir}"
{_pg18_helpers_src()}
{cache_check_block}
printf 'VERIFIED=%s\\n' "$HAVE_VERIFIED_LOCAL_DEBS"
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        if case == "valid_cache":
            assert "VERIFIED=true" in proc.stdout.splitlines()
            assert "[SKIP]" in proc.stdout
            assert (repo_dir / "postgresql-18_18.6-1_riscv64.deb").is_file()
            assert manifest.is_file()
        else:
            assert "VERIFIED=false" in proc.stdout.splitlines()
            assert "[WARN]" in proc.stdout
            assert list(repo_dir.glob("*.deb")) == []
            assert not manifest.exists()

    @pytest.mark.parametrize("failure_mode", ["manifest_mismatch", "missing_manifest"])
    def test_update_local_repo_fails_closed_when_manifest_tampered_or_missing(
        self, tmp_path: Path, failure_mode: str
    ) -> None:
        repo_dir, env = self._seed_verified_repo(tmp_path)
        bin_dir = tmp_path / "bin"
        scan_log = tmp_path / "scan.log"
        _write_exe(
            bin_dir / "dpkg-scanpackages",
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{scan_log}"\nexit 0\n',
        )
        _write_exe(bin_dir / "apt-get", "#!/usr/bin/env bash\nexit 0\n")

        if failure_mode == "manifest_mismatch":
            (repo_dir / "rogue-extra_1.0_all.deb").write_bytes(b"ROGUE")
        else:
            (repo_dir / ".rvdk-debs.sha256").unlink()

        local_list = tmp_path / "rvdk-local-pgdg.list"
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
PG_LIB_ROOT="{tmp_path}"
LOCAL_REPO_DIR="{repo_dir}"
LOCAL_LIST="{local_list}"
WANT_LOCAL_LIST="deb [trusted=yes check-date=no lang=none] file://{repo_dir} ./"
rvdk_apt_has_lists() {{ return 0; }}
rvdk_apt_update() {{ return 0; }}
{_pg18_helpers_src()}
update_local_repo
""",
            env=env,
        )
        assert proc.returncode != 0
        assert "failed .rvdk-debs.sha256 integrity verification" in proc.stderr
        assert not scan_log.exists()
        assert not local_list.exists()

    @pytest.mark.parametrize(
        "mode",
        ["valid_converged", "missing_manifest", "modified_deb", "rogue_extra_deb", "symlink_repo_dir"],
    )
    def test_installed_rerun_reconcile_enforces_manifest_and_disarms_local_list(
        self, tmp_path: Path, mode: str
    ) -> None:
        repo_dir, env = self._seed_verified_repo(tmp_path)
        bin_dir = tmp_path / "bin"
        scan_log = tmp_path / "scan.log"
        _write_exe(
            bin_dir / "dpkg-scanpackages",
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{scan_log}"\nexit 0\n',
        )
        _write_exe(bin_dir / "apt-get", "#!/usr/bin/env bash\nexit 0\n")

        local_list = tmp_path / "rvdk-local-pgdg.list"
        want_list = f"deb [trusted=yes check-date=no lang=none] file://{repo_dir} ./"
        local_list.write_text(f"{want_list}\n", encoding="utf-8")
        (repo_dir / "Release").write_text("Origin: RVDK\n", encoding="utf-8")

        if mode == "missing_manifest":
            (repo_dir / ".rvdk-debs.sha256").unlink()
        elif mode == "modified_deb":
            (repo_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"TAMPERED")
        elif mode == "rogue_extra_deb":
            (repo_dir / "rogue_1.0_all.deb").write_bytes(b"ROGUE")
        elif mode == "symlink_repo_dir":
            real_repo = tmp_path / "real_debs"
            repo_dir.rename(real_repo)
            repo_dir.symlink_to(real_repo)

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
PG_LIB_ROOT="{tmp_path}"
LOCAL_REPO_DIR="{repo_dir}"
LOCAL_LIST="{local_list}"
WANT_LOCAL_LIST="{want_list}"
rvdk_apt_has_lists() {{ return 0; }}
rvdk_apt_update() {{ return 0; }}
{_pg18_helpers_src()}
_pg_reconcile_installed_local_repo
""",
            env=env,
        )
        if mode == "symlink_repo_dir":
            assert proc.returncode != 0
            assert "must not be a symbolic link" in proc.stderr
        elif mode == "valid_converged":
            assert proc.returncode == 0, proc.stderr
            assert local_list.is_file()
            assert (repo_dir / "postgresql-18_18.6-1_riscv64.deb").is_file()
            assert not scan_log.exists()
        else:
            assert proc.returncode == 0, proc.stderr
            assert "[WARN]" in proc.stdout
            assert not local_list.exists()
            assert list(repo_dir.glob("*.deb")) == []
            assert not (repo_dir / ".rvdk-debs.sha256").exists()
            assert not scan_log.exists()


class TestNtfyAndTailscaleHardening:
    def test_ntfy_stage_built_binary_installs_regular_binary_without_chown(
        self, tmp_path: Path
    ) -> None:
        ntfy_text = NTFY_FORGE.read_text(encoding="utf-8")
        assert 'chown 0:0 "${STAGE_ROOT}/usr/bin/ntfy"' not in ntfy_text
        assert 'chown -R 0:0 "$STAGE_ROOT"' not in ntfy_text

        bin_dir = tmp_path / "bin"
        install_log = tmp_path / "install.log"
        chown_log = tmp_path / "chown.log"
        _make_install_shim(bin_dir, install_log)
        _make_chown_shim(bin_dir, chown_log)

        stage_root = tmp_path / "build" / "stage"
        (stage_root / "usr" / "bin").mkdir(parents=True)
        src_bin = stage_root / "usr" / "bin" / "ntfy"
        src_bin.write_bytes(b"#!/bin/sh\necho ntfy-test\n")

        dst_bin = tmp_path / "pkg" / "usr" / "bin" / "ntfy"
        fn_src = _extract_bash_function(NTFY_FORGE, "_ntfy_stage_built_binary")

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
{fn_src}
_ntfy_stage_built_binary "{stage_root}" "{dst_bin}"
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, proc.stderr
        assert not chown_log.exists()
        assert dst_bin.is_file()
        assert stat.S_IMODE(dst_bin.stat().st_mode) == 0o755
        assert f"-m 0755 -o root -g root {src_bin} {dst_bin}" in install_log.read_text(encoding="utf-8")

    @pytest.mark.parametrize(
        "mode",
        [
            "symlink_binary",
            "broken_symlink_binary",
            "directory_binary",
            "missing_binary",
            "symlink_usr_bin",
        ],
    )
    def test_ntfy_stage_built_binary_rejects_symlinks_and_non_regular(
        self, tmp_path: Path, mode: str
    ) -> None:
        bin_dir = tmp_path / "bin"
        install_log = tmp_path / "install.log"
        chown_log = tmp_path / "chown.log"
        _make_install_shim(bin_dir, install_log)
        _make_chown_shim(bin_dir, chown_log)

        secret = tmp_path / "secret_target"
        secret.write_text("SECRET_CONTENT", encoding="utf-8")
        secret.chmod(0o600)

        stage_root = tmp_path / "build" / "stage"
        dst_bin = tmp_path / "pkg" / "usr" / "bin" / "ntfy"

        if mode == "symlink_usr_bin":
            outside_bin = tmp_path / "outside_bin"
            outside_bin.mkdir()
            (outside_bin / "ntfy").write_bytes(b"evil")
            (stage_root / "usr").mkdir(parents=True)
            (stage_root / "usr" / "bin").symlink_to(outside_bin)
        else:
            (stage_root / "usr" / "bin").mkdir(parents=True)
            src_bin = stage_root / "usr" / "bin" / "ntfy"
            if mode == "symlink_binary":
                src_bin.symlink_to(secret)
            elif mode == "broken_symlink_binary":
                src_bin.symlink_to(tmp_path / "missing_ntfy")
            elif mode == "directory_binary":
                src_bin.mkdir()

        fn_src = _extract_bash_function(NTFY_FORGE, "_ntfy_stage_built_binary")
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
{fn_src}
_ntfy_stage_built_binary "{stage_root}" "{dst_bin}"
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode != 0
        assert not install_log.exists()
        assert not chown_log.exists()
        assert not dst_bin.exists()
        assert stat.S_IMODE(secret.stat().st_mode) == 0o600

    def test_ntfy_tar_extraction_enforces_no_same_owner_and_no_same_permissions(
        self, tmp_path: Path
    ) -> None:
        ntfy_text = NTFY_FORGE.read_text(encoding="utf-8")
        extract_lines = [
            line.strip()
            for line in ntfy_text.splitlines()
            if re.search(r"\btar\b", line) and ("-xf" in line or "-xzf" in line)
        ]
        assert len(extract_lines) == 2
        for line in extract_lines:
            assert "--no-same-owner" in line
            assert "--no-same-permissions" in line

        # Behavioral verification of bundle extraction + symlink-safe install
        real_tar = shutil.which("tar")
        assert real_tar is not None

        bin_dir = tmp_path / "bin"
        tar_log = tmp_path / "tar.log"
        install_log = tmp_path / "install.log"
        _make_install_shim(bin_dir, install_log)

        src_tree = tmp_path / "bundle_src"
        (src_tree / "usr" / "bin").mkdir(parents=True)
        (src_tree / "usr" / "bin" / "ntfy").write_bytes(b"#!/bin/sh\necho ntfy\n")
        (src_tree / "usr" / "bin" / "ntfy").chmod(0o755)
        bundle = tmp_path / "ntfy-bundle.tar.zst"

        zstd_bin = shutil.which("zstd")
        if zstd_bin:
            plain_tar = tmp_path / "ntfy-bundle.tar"
            mk_tar = subprocess.run(
                [real_tar, "-cf", str(plain_tar), "-C", str(src_tree), "."],
                capture_output=True,
                text=True,
                check=False,
            )
            assert mk_tar.returncode == 0, mk_tar.stderr
            mk_zst = subprocess.run(
                [zstd_bin, "-q", "-f", str(plain_tar), "-o", str(bundle)],
                capture_output=True,
                text=True,
                check=False,
            )
            assert mk_zst.returncode == 0, mk_zst.stderr
            # Spy logs exact args (including --no-same-owner --no-same-permissions -I zstd)
            # and translates `-I zstd` when running on bsdtar (macOS).
            _write_exe(
                bin_dir / "tar",
                f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{tar_log}"
if "{real_tar}" --version 2>/dev/null | grep -qi 'GNU tar'; then
    exec "{real_tar}" "$@"
fi
args=()
archive=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -I) shift 2 ;;
        -xf) archive="${{2:-}}"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
"{zstd_bin}" -dc "$archive" | "{real_tar}" "${{args[@]}}" -xf -
""",
            )
        else:
            mk = subprocess.run(
                [real_tar, "-cf", str(bundle), "-C", str(src_tree), "."],
                capture_output=True,
                text=True,
                check=False,
            )
            assert mk.returncode == 0, mk.stderr
            _write_exe(
                bin_dir / "tar",
                f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{tar_log}"
args=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-I" ]]; then shift 2; continue; fi
    args+=("$1"); shift
done
exec "{real_tar}" "${{args[@]}}"
""",
            )

        extract_cmd_match = re.search(
            r"^\s*(tar\b.*?-I zstd -xf \"\$LOCAL_BUNDLE\" -C \"\$_NTFY_TMP_EXTRACT\")$",
            ntfy_text,
            flags=re.MULTILINE,
        )
        assert extract_cmd_match is not None
        extract_cmd = extract_cmd_match.group(1)

        extract_dir = tmp_path / "extract"
        extract_dir.mkdir()
        dst_bin = tmp_path / "out_usr_bin" / "ntfy"
        fn_src = _extract_bash_function(NTFY_FORGE, "_ntfy_stage_built_binary")

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
LOCAL_BUNDLE="{bundle}"
_NTFY_TMP_EXTRACT="{extract_dir}"
{fn_src}
{extract_cmd}
_ntfy_stage_built_binary "$_NTFY_TMP_EXTRACT" "{dst_bin}"
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, proc.stderr
        tar_invocations = tar_log.read_text(encoding="utf-8")
        assert "--no-same-owner" in tar_invocations
        assert "--no-same-permissions" in tar_invocations
        assert dst_bin.is_file()
        assert stat.S_IMODE(dst_bin.stat().st_mode) == 0o755

    def test_tailscale_tar_extraction_enforces_no_same_owner_and_no_same_permissions(
        self, tmp_path: Path
    ) -> None:
        ts_text = TAILSCALE_FORGE.read_text(encoding="utf-8")
        extract_lines = [
            line.strip()
            for line in ts_text.splitlines()
            if re.search(r"\btar\b", line) and ("-xf" in line or "-xzf" in line)
        ]
        assert len(extract_lines) == 1
        assert "--no-same-owner" in extract_lines[0]
        assert "--no-same-permissions" in extract_lines[0]

        real_tar = shutil.which("tar")
        assert real_tar is not None

        bin_dir = tmp_path / "bin"
        tar_log = tmp_path / "tar.log"
        install_log = tmp_path / "install.log"
        _make_install_shim(bin_dir, install_log)
        _write_exe(
            bin_dir / "tar",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{tar_log}"
exec "{real_tar}" "$@"
""",
        )

        # Build a valid .tgz archive matching Tailscale layout
        pkg_src = tmp_path / "src" / "tailscale_1.80.0_riscv64"
        (pkg_src / "systemd").mkdir(parents=True)
        (pkg_src / "tailscale").write_bytes(b"#!/bin/sh\necho ts\n")
        (pkg_src / "tailscaled").write_bytes(b"#!/bin/sh\necho tsd\n")
        (pkg_src / "systemd" / "tailscaled.service").write_text("[Unit]\nDescription=ts\n", encoding="utf-8")

        tgz_path = tmp_path / "tailscale_1.80.0_riscv64.tgz"
        with tarfile.open(tgz_path, "w:gz") as tf:
            tf.add(pkg_src, arcname="tailscale_1.80.0_riscv64")

        extract_match = re.search(
            r"(?ms)^\s*tar --no-same-owner --no-same-permissions -xzf \"\$CACHED_TGZ\".*?^    done",
            ts_text,
        )
        assert extract_match is not None
        extract_block = extract_match.group(0)

        extract_dir = tmp_path / "extract"
        extract_dir.mkdir()
        root_out = tmp_path / "rootfs"
        # Redirect hardcoded /usr/bin, /usr/sbin, /etc paths in test block into tmp_path/rootfs
        localized_block = (
            extract_block.replace(" /usr/", f" {root_out}/usr/")
            .replace(" /etc/", f" {root_out}/etc/")
            .replace('"/etc/', f'"{root_out}/etc/')
        )

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
CACHED_TGZ="{tgz_path}"
_TS_TMP_EXTRACT="{extract_dir}"
{localized_block}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, proc.stderr
        tar_invocations = tar_log.read_text(encoding="utf-8")
        assert "--no-same-owner" in tar_invocations
        assert "--no-same-permissions" in tar_invocations
        assert (root_out / "usr" / "bin" / "tailscale").is_file()
        assert (root_out / "usr" / "sbin" / "tailscaled").is_file()
        assert (root_out / "etc" / "systemd" / "system" / "tailscaled.service").is_file()

        # Symlink inside archive must also be rejected fail-closed
        sym_src = tmp_path / "sym_src" / "tailscale_1.80.0_riscv64"
        sym_src.mkdir(parents=True)
        (sym_src / "tailscale").symlink_to("/etc/passwd")
        (sym_src / "tailscaled").write_bytes(b"#!/bin/sh\necho tsd\n")
        sym_tgz = tmp_path / "sym_tailscale.tgz"
        with tarfile.open(sym_tgz, "w:gz") as tf:
            tf.add(sym_src, arcname="tailscale_1.80.0_riscv64")

        sym_extract = tmp_path / "sym_extract"
        sym_extract.mkdir()
        sym_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
CACHED_TGZ="{sym_tgz}"
_TS_TMP_EXTRACT="{sym_extract}"
{localized_block}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert sym_proc.returncode != 0
        assert "Unexpected or symlinked archive layout" in sym_proc.stderr

        # Symlinked systemd directory and symlinked unit inside archive must fail closed
        sym_dir_src = tmp_path / "sym_dir_src" / "tailscale_1.80.0_riscv64"
        sym_dir_src.mkdir(parents=True)
        (sym_dir_src / "tailscale").write_bytes(b"#!/bin/sh\necho ts\n")
        (sym_dir_src / "tailscaled").write_bytes(b"#!/bin/sh\necho tsd\n")
        (sym_dir_src / "systemd").symlink_to("/etc")
        sym_dir_tgz = tmp_path / "sym_dir_tailscale.tgz"
        with tarfile.open(sym_dir_tgz, "w:gz") as tf:
            tf.add(sym_dir_src, arcname="tailscale_1.80.0_riscv64")

        sym_dir_extract = tmp_path / "sym_dir_extract"
        sym_dir_extract.mkdir()
        sym_dir_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
CACHED_TGZ="{sym_dir_tgz}"
_TS_TMP_EXTRACT="{sym_dir_extract}"
{localized_block}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert sym_dir_proc.returncode != 0
        assert "Unexpected or symlinked archive layout" in sym_dir_proc.stderr

    def test_ntfy_intermediate_dir_symlink_rejection_during_build_and_extract(
        self, tmp_path: Path
    ) -> None:
        ntfy_text = NTFY_FORGE.read_text(encoding="utf-8")
        # 1. Verify build staging rejects symlinked src/server directory before install reads unit/config
        stage_cfg_match = re.search(
            r'(?ms)^\s*install -d -m 0755 -o root -g root "\$\{_NTFY_TMP_PKG\}/etc/systemd/system".*?^\s*fi\n\s*if \[\[ -f "\$\{BUILD_DIR\}/src/client/client\.yml" \]\]; then.*?^\s*fi',
            ntfy_text,
        )
        assert stage_cfg_match is not None
        stage_cfg_block = stage_cfg_match.group(0)

        bin_dir = tmp_path / "bin"
        install_log = tmp_path / "install.log"
        _make_install_shim(bin_dir, install_log)

        build_dir = tmp_path / "build"
        (build_dir / "src").mkdir(parents=True)
        outside = tmp_path / "outside_etc"
        outside.mkdir()
        (outside / "ntfy.service").write_text("[Unit]\n", encoding="utf-8")
        (build_dir / "src" / "server").symlink_to(outside)
        pkg_dir = tmp_path / "pkg"

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
BUILD_DIR="{build_dir}"
_NTFY_TMP_PKG="{pkg_dir}"
{stage_cfg_block}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode != 0
        assert "symlinked source directory" in proc.stderr
        assert not (pkg_dir / "etc" / "systemd" / "system" / "ntfy.service").exists()

        # 2. Verify extracted bundle symlink check rejects symlinked intermediate directory before install
        extract_guard_match = re.search(
            r'(?ms)^\s*if \[\[ -n "\$\(find "\$_NTFY_TMP_EXTRACT" -type l -print -quit\)" \]\]; then\n.*?\n\s*fi',
            ntfy_text,
        )
        assert extract_guard_match is not None
        extract_guard_block = extract_guard_match.group(0)

        ext_dir = tmp_path / "extracted_bundle"
        (ext_dir / "usr" / "bin").mkdir(parents=True)
        (ext_dir / "usr" / "bin" / "ntfy").write_bytes(b"ntfy")
        (ext_dir / "etc" / "systemd").mkdir(parents=True)
        (ext_dir / "etc" / "systemd" / "system").symlink_to(outside)

        ext_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
LOCAL_BUNDLE="/tmp/test-bundle.tar.zst"
_NTFY_TMP_EXTRACT="{ext_dir}"
{extract_guard_block}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert ext_proc.returncode != 0
        assert "symbolic links" in ext_proc.stderr


OWNED_PRIV_BOUNDARY_SCRIPTS: list[tuple[Path, list[str], str, str]] = [
    (REPO_ROOT / "os" / "bootstrap-apt.sh", ["--distro", "debian"], "RVDK_APT_DISTRO_DEFAULT", "debian"),
    (REPO_ROOT / "os" / "bootstrap-openwrt.sh", ["--hostname", "r2s-gw"], "RVDK_KEEP_VENDOR_MIRRORS", "1"),
    (REPO_ROOT / "os" / "deeptune.sh", ["--tune", "iot"], "RVDK_TUNE", "iot"),
    (REPO_ROOT / "boards" / "sifive" / "p550" / "quirks" / "fusb.sh", ["off"], "RVDK_BOARD", "sifive/p550"),
    (REPO_ROOT / "boards" / "sifive" / "p550" / "quirks" / "hdmi.sh", ["off"], "RVDK_SOC", "eswin/eic7700x"),
    (REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh", ["--tune", "iot"], "RVDK_TUNE", "iot"),
    (REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "quirks" / "c6-sdio.sh", ["disable"], "RVDK_NO_PROGBAR", "1"),
]


def _make_self_elevate_sudo_mock(
    tmp_path: Path,
    *,
    deny_setenv: bool = False,
    child_rc: int = 0,
) -> tuple[Path, Path, Path, Path]:
    bin_dir = tmp_path / "bin"
    sudo_log = tmp_path / "sudo_calls.log"
    child_env_log = tmp_path / "child_env.txt"
    pwn_flag = tmp_path / "bash_env_pwned"

    _write_exe(
        bin_dir / "sudo",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{sudo_log}"
validate_only=0
non_interactive=0
preserve_csv=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            non_interactive=1
            shift
            ;;
        -v)
            validate_only=1
            shift
            ;;
        -E)
            printf 'sudo: -E must never be called\\n' >&2
            exit 99
            ;;
        --preserve-env=*)
            preserve_csv="${{1#--preserve-env=}}"
            shift
            ;;
        --preserve-env)
            preserve_csv="${{2:-}}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            shift
            ;;
        *)
            break
            ;;
    esac
done
if [[ -n "$preserve_csv" && "{1 if deny_setenv else 0}" == "1" ]]; then
    printf 'sudo: sorry, you are not allowed to set the following environment variables: %s\\n' "$preserve_csv" >&2
    exit 1
fi
if [[ "$validate_only" == "1" ]]; then
    exit 0
fi
if [[ "$non_interactive" == "1" && "${{1:-}}" == "true" ]]; then
    exit 0
fi

clean_env=("PATH=/usr/bin:/bin" "RVDK_TEST_ELEVATED=1")
if [[ -n "$preserve_csv" ]]; then
    IFS=',' read -r -a keep_vars <<< "$preserve_csv"
    for k in "${{keep_vars[@]}}"; do
        if [[ -n "${{!k+x}}" ]]; then
            clean_env+=("${{k}}=${{!k}}")
        fi
    done
fi

env -i "${{clean_env[@]}}" "{BASH_BIN}" -c '
    printf "BASH_ENV=%s\\n" "${{BASH_ENV:-UNSET}}"
    printf "ENV=%s\\n" "${{ENV:-UNSET}}"
    printf "LD_PRELOAD=%s\\n" "${{LD_PRELOAD:-UNSET}}"
    printf "LD_LIBRARY_PATH=%s\\n" "${{LD_LIBRARY_PATH:-UNSET}}"
    printf "PATH=%s\\n" "${{PATH:-UNSET}}"
    printf "XDG_CACHE_HOME=%s\\n" "${{XDG_CACHE_HOME:-UNSET}}"
    printf "RVDK_PROGBAR_LIB=%s\\n" "${{RVDK_PROGBAR_LIB:-UNSET}}"
    printf "RVDK_APT_LIB=%s\\n" "${{RVDK_APT_LIB:-UNSET}}"
    printf "RVDK_TUNE=%s\\n" "${{RVDK_TUNE:-UNSET}}"
    printf "RVDK_BOARD=%s\\n" "${{RVDK_BOARD:-UNSET}}"
    printf "RVDK_SOC=%s\\n" "${{RVDK_SOC:-UNSET}}"
    printf "RVDK_APT_DISTRO_DEFAULT=%s\\n" "${{RVDK_APT_DISTRO_DEFAULT:-UNSET}}"
    printf "RVDK_KEEP_VENDOR_MIRRORS=%s\\n" "${{RVDK_KEEP_VENDOR_MIRRORS:-UNSET}}"
    printf "RVDK_NO_PROGBAR=%s\\n" "${{RVDK_NO_PROGBAR:-UNSET}}"
    exit {child_rc}
' > "{child_env_log}"
""",
    )
    return bin_dir, sudo_log, child_env_log, pwn_flag


class TestOsAndBoardPrivilegeBoundary:
    @pytest.mark.parametrize(
        ("script_path", "_args", "_var_name", "_var_val"),
        OWNED_PRIV_BOUNDARY_SCRIPTS,
        ids=lambda item: str(item.relative_to(REPO_ROOT)) if isinstance(item, Path) else str(item),
    )
    def test_no_sudo_dash_e_or_eval_in_owned_scripts(
        self,
        script_path: Path,
        _args: list[str],
        _var_name: str,
        _var_val: str,
    ) -> None:
        text = script_path.read_text(encoding="utf-8")
        assert not re.search(r"(^|\s)sudo\s+-E(\s|$)", text, flags=re.MULTILINE)
        assert not re.search(r"(^|[;&|]\s*)eval(\s|$)", text, flags=re.MULTILINE)
        assert "rvdk_sudo_preserve" in text

    @pytest.mark.parametrize("standalone", [False, True], ids=["repo", "standalone"])
    @pytest.mark.parametrize(
        ("script_path", "cli_args", "allow_var", "allow_val"),
        OWNED_PRIV_BOUNDARY_SCRIPTS,
        ids=lambda item: str(item.relative_to(REPO_ROOT)) if isinstance(item, Path) else str(item),
    )
    def test_self_elevation_strips_bash_env_and_dangerous_vars(
        self,
        tmp_path: Path,
        script_path: Path,
        cli_args: list[str],
        allow_var: str,
        allow_val: str,
        standalone: bool,
    ) -> None:
        if os.geteuid() == 0:
            pytest.skip("Unprivileged self-elevation path requires non-root UID")

        bin_dir, sudo_log, child_env_log, pwn_flag = _make_self_elevate_sudo_mock(tmp_path)
        evil_bashenv = tmp_path / "evil_bashenv.sh"
        evil_bashenv.write_text(
            f'if [[ "${{RVDK_TEST_ELEVATED:-0}}" == "1" ]]; then touch "{pwn_flag}"; fi\n',
            encoding="utf-8",
        )

        target = script_path
        if standalone:
            standalone_dir = tmp_path / "standalone_only"
            standalone_dir.mkdir()
            target = standalone_dir / script_path.name
            shutil.copy2(script_path, target)

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "BASH_ENV": str(evil_bashenv),
            "ENV": str(evil_bashenv),
            "LD_PRELOAD": "/tmp/evil_preload.so",
            "LD_LIBRARY_PATH": "/tmp/evil_ld_path",
            "XDG_CACHE_HOME": "/tmp/evil_xdg",
            "RVDK_PROGBAR_LIB": "/tmp/evil_progbar.sh",
            "RVDK_APT_LIB": "/tmp/evil_apt.sh",
            allow_var: allow_val,
        }

        proc = subprocess.run(
            [BASH_BIN, str(target), *cli_args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        assert not pwn_flag.exists(), "BASH_ENV must not survive sudo self-elevation"

        sudo_calls = sudo_log.read_text(encoding="utf-8").splitlines()
        assert len(sudo_calls) == 2
        assert "--preserve-env=" in sudo_calls[0]
        assert "--preserve-env=" in sudo_calls[1]
        for call in sudo_calls:
            assert " -E " not in f" {call} "
            for dangerous in (
                "BASH_ENV",
                "ENV",
                "LD_PRELOAD",
                "LD_LIBRARY_PATH",
                "PATH",
                "XDG_CACHE_HOME",
                "RVDK_PROGBAR_LIB",
                "RVDK_APT_LIB",
            ):
                assert dangerous not in call

        child_env = dict(
            line.split("=", 1) for line in child_env_log.read_text(encoding="utf-8").splitlines()
        )
        assert child_env["BASH_ENV"] == "UNSET"
        assert child_env["ENV"] == "UNSET"
        assert child_env["LD_PRELOAD"] == "UNSET"
        assert child_env["LD_LIBRARY_PATH"] == "UNSET"
        assert child_env["PATH"] == "/usr/bin:/bin"
        assert child_env["XDG_CACHE_HOME"] == "UNSET"
        assert child_env["RVDK_PROGBAR_LIB"] == "UNSET"
        assert child_env["RVDK_APT_LIB"] == "UNSET"
        assert child_env[allow_var] == allow_val

    def test_standalone_fallback_preserves_exit_code_and_falls_back_when_setenv_denied(
        self, tmp_path: Path
    ) -> None:
        if os.geteuid() == 0:
            pytest.skip("Unprivileged self-elevation path requires non-root UID")

        bin_dir, sudo_log, child_env_log, pwn_flag = _make_self_elevate_sudo_mock(
            tmp_path, deny_setenv=True, child_rc=42
        )
        evil_bashenv = tmp_path / "evil_bashenv.sh"
        evil_bashenv.write_text(
            f'if [[ "${{RVDK_TEST_ELEVATED:-0}}" == "1" ]]; then touch "{pwn_flag}"; fi\n',
            encoding="utf-8",
        )

        standalone_target = tmp_path / "standalone" / "deeptune.sh"
        standalone_target.parent.mkdir()
        shutil.copy2(REPO_ROOT / "os" / "deeptune.sh", standalone_target)

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "BASH_ENV": str(evil_bashenv),
            "LD_PRELOAD": "/tmp/evil.so",
            "RVDK_TUNE": "iot",
        }
        proc = subprocess.run(
            [BASH_BIN, str(standalone_target), "--tune", "iot"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert proc.returncode == 42
        assert not pwn_flag.exists()

        calls = sudo_log.read_text(encoding="utf-8").splitlines()
        assert len(calls) == 2
        assert calls[0].startswith("--preserve-env=")
        assert calls[1] == f"bash {standalone_target} --tune iot"

        child_env = dict(
            line.split("=", 1) for line in child_env_log.read_text(encoding="utf-8").splitlines()
        )
        assert child_env["BASH_ENV"] == "UNSET"
        assert child_env["LD_PRELOAD"] == "UNSET"
        assert child_env["RVDK_TUNE"] == "UNSET"


class TestBootstrapAptNetGuardPersistenceAndChroot:
    def _extract_net_guard_block(self, root_dir: Path, nft_bin: Path) -> str:
        apt_text = (REPO_ROOT / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8")
        match = re.search(
            r"(?ms)^# 4\. RVDK IPv4 IP-OPTIONS PREROUTING DROP GUARD.*?^(?=# =+\n# 5\. UNIFIED RVDK LOGIN HEADER)",
            apt_text,
        )
        assert match is not None, "Could not locate section 4 rvdk-net-guard block in os/bootstrap-apt.sh"
        block = match.group(0)
        return (
            block.replace("/usr/sbin/nft", str(nft_bin))
            .replace("/etc/", f"{root_dir}/etc/")
            .replace("/run/systemd/system", f"{root_dir}/run/systemd/system")
        )

    def _make_stateful_nft_mock(self, bin_dir: Path, state_file: Path, log_file: Path) -> Path:
        return _write_exe(
            bin_dir / "nft",
            f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{log_file}"
touch "{state_file}"
case "${{1:-}}" in
    -f)
        cfg="${{2:-}}"
        if [[ ! -r "$cfg" ]]; then
            printf 'nft: cannot open %s\\n' "$cfg" >&2
            exit 1
        fi
        if grep -qE '^flush ruleset$' "$cfg"; then
            : > "{state_file}"
        fi
        if grep -qE 'table inet filter' "$cfg"; then
            printf 'inet:filter\\n' >> "{state_file}"
        fi
        if grep -qE 'table ip rvdk_net_guard' "$cfg"; then
            if ! grep -qxF 'ip:rvdk_net_guard' "{state_file}"; then
                printf 'ip:rvdk_net_guard\\n' >> "{state_file}"
            fi
        fi
        exit 0
        ;;
    list)
        if [[ "${{2:-}}" == "table" && "${{3:-}}" == "ip" ]]; then
            grep -qxF "ip:${{4:-}}" "{state_file}" 2>/dev/null
            exit $?
        fi
        ;;
    delete)
        if [[ "${{2:-}}" == "table" && "${{3:-}}" == "ip" ]]; then
            grep -vxF "ip:${{4:-}}" "{state_file}" > "{state_file}.tmp" || true
            mv -f "{state_file}.tmp" "{state_file}"
            exit 0
        fi
        ;;
esac
exit 1
""",
        )

    def test_net_guard_dropin_persists_guard_across_nftables_reload_and_converges(
        self, tmp_path: Path
    ) -> None:
        root_dir = tmp_path / "rootfs"
        (root_dir / "etc" / "nftables.d").mkdir(parents=True)
        (root_dir / "run" / "systemd" / "system").mkdir(parents=True)
        nftables_conf = root_dir / "etc" / "nftables.conf"
        nftables_conf.write_text(
            "#!/usr/sbin/nft -f\nflush ruleset\ntable inet filter {\n}\n",
            encoding="utf-8",
        )

        bin_dir = tmp_path / "bin"
        nft_state = tmp_path / "nft_tables.state"
        nft_log = tmp_path / "nft.log"
        sys_log = tmp_path / "systemctl.log"
        enabled_marker = tmp_path / "unit_enabled"
        active_marker = tmp_path / "unit_active"

        nft_bin = self._make_stateful_nft_mock(bin_dir, nft_state, nft_log)
        _write_exe(bin_dir / "sysctl", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "systemctl",
            f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{sys_log}"
case "${{1:-}}" in
    daemon-reload)
        exit 0
        ;;
    enable)
        if [[ "${{2:-}}" == "--now" ]]; then
            touch "{enabled_marker}" "{active_marker}"
        else
            touch "{enabled_marker}"
        fi
        exit 0
        ;;
    is-active)
        [[ -f "{active_marker}" ]]
        exit $?
        ;;
    is-enabled)
        [[ -f "{enabled_marker}" ]]
        exit $?
        ;;
esac
exit 0
""",
        )

        guard_block = self._extract_net_guard_block(root_dir, nft_bin)
        run_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
SKIP_NET_GUARD="false"
{guard_block}
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}

        # Pass 1: initial convergence
        p1 = _run_bash(run_script, env=env)
        assert p1.returncode == 0, f"stdout={p1.stdout}\nstderr={p1.stderr}"
        assert "[OK]" in p1.stdout

        dropin_path = root_dir / "etc" / "systemd" / "system" / "nftables.service.d" / "90-rvdk-net-guard.conf"
        guard_nft_path = root_dir / "etc" / "nftables.d" / "10-rvdk-ip-options.nft"
        assert dropin_path.is_file()
        assert guard_nft_path.is_file()

        dropin_lines = [ln.strip() for ln in dropin_path.read_text(encoding="utf-8").splitlines() if ln.strip()]
        assert dropin_lines == [
            "[Service]",
            f"ExecStartPost=-{nft_bin} -f {guard_nft_path}",
            "ExecReload=",
            f"ExecReload={nft_bin} -f {root_dir}/etc/nftables.conf",
            f"ExecReload=-{nft_bin} -f {guard_nft_path}",
        ]

        # Simulate `systemctl reload nftables.service`: apply drop-in ExecReload= entries in order
        reload_cmds: list[str] = []
        for line in dropin_lines:
            if line.startswith("ExecReload="):
                val = line.split("=", 1)[1]
                if val == "":
                    reload_cmds.clear()
                else:
                    reload_cmds.append(val.lstrip("-"))
        assert len(reload_cmds) == 2

        reload_proc = _run_bash("\n".join(reload_cmds), env=env)
        assert reload_proc.returncode == 0, reload_proc.stderr
        assert "ip:rvdk_net_guard" in nft_state.read_text(encoding="utf-8").splitlines()
        assert "inet:filter" in nft_state.read_text(encoding="utf-8").splitlines()

        # Pass 2: converged re-run must emit [SKIP] and avoid re-applying nft / daemon-reload
        nft_log_before = len(nft_log.read_text(encoding="utf-8").splitlines())
        sys_log_before = len(sys_log.read_text(encoding="utf-8").splitlines())
        p2 = _run_bash(run_script, env=env)
        assert p2.returncode == 0, f"stdout={p2.stdout}\nstderr={p2.stderr}"
        assert "[SKIP]" in p2.stdout
        assert "[OK]" not in p2.stdout
        new_nft_calls = nft_log.read_text(encoding="utf-8").splitlines()[nft_log_before:]
        new_sys_calls = sys_log.read_text(encoding="utf-8").splitlines()[sys_log_before:]
        assert not any(c.startswith("-f ") for c in new_nft_calls)
        assert not any(c.startswith(("daemon-reload", "enable")) for c in new_sys_calls)

    def test_net_guard_non_systemd_chroot_offline_enable_and_converged_skip(
        self, tmp_path: Path
    ) -> None:
        root_dir = tmp_path / "chroot"
        (root_dir / "etc" / "nftables.d").mkdir(parents=True)
        # Intentionally do NOT create root_dir/run/systemd/system

        bin_dir = tmp_path / "bin"
        nft_log = tmp_path / "nft_chroot.log"
        sys_log = tmp_path / "systemctl_chroot.log"
        enabled_marker = tmp_path / "chroot_enabled"

        nft_bin = bin_dir / "nft"
        _write_exe(
            nft_bin,
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{nft_log}"
printf 'nft: netfilter unavailable in chroot\\n' >&2
exit 1
""",
        )
        _write_exe(bin_dir / "sysctl", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(
            bin_dir / "systemctl",
            f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{sys_log}"
case "${{1:-}}" in
    daemon-reload|is-active|is-system-running)
        printf 'System has not been booted with systemd as init system (PID 1).\\n' >&2
        exit 1
        ;;
    enable)
        if [[ "$*" == *"--now"* ]]; then
            printf 'System has not been booted with systemd as init system (PID 1).\\n' >&2
            exit 1
        fi
        touch "{enabled_marker}"
        exit 0
        ;;
    is-enabled)
        [[ -f "{enabled_marker}" ]]
        exit $?
        ;;
esac
exit 1
""",
        )

        guard_block = self._extract_net_guard_block(root_dir, nft_bin)
        run_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
SKIP_NET_GUARD="false"
{guard_block}
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}

        # Pass 1: writes files, offline-enables unit without --now or daemon-reload or live nft
        p1 = _run_bash(run_script, env=env)
        assert p1.returncode == 0, f"stdout={p1.stdout}\nstderr={p1.stderr}"
        assert "[OK]" in p1.stdout
        assert not nft_log.exists(), "Live nft must not be invoked when /run/systemd/system is absent"
        assert enabled_marker.is_file()
        sys_calls_1 = sys_log.read_text(encoding="utf-8").splitlines()
        assert "enable rvdk-net-guard.service" in sys_calls_1
        assert not any("daemon-reload" in c or "--now" in c or "is-active" in c for c in sys_calls_1)

        # Pass 2: converged chroot re-run logs [SKIP] and does not re-enable
        sys_count_1 = len(sys_calls_1)
        p2 = _run_bash(run_script, env=env)
        assert p2.returncode == 0, f"stdout={p2.stdout}\nstderr={p2.stderr}"
        assert "[SKIP]" in p2.stdout
        assert "[OK]" not in p2.stdout
        assert not nft_log.exists()
        sys_calls_2 = sys_log.read_text(encoding="utf-8").splitlines()[sys_count_1:]
        assert sys_calls_2 == ["is-enabled --quiet rvdk-net-guard.service"]

    def test_non_systemd_container_with_failing_systemctl_does_not_fail(
        self, tmp_path: Path
    ) -> None:
        root_dir = tmp_path / "container_rootfs"
        (root_dir / "etc" / "nftables.d").mkdir(parents=True)

        bin_dir = tmp_path / "bin"
        nft_bin = bin_dir / "nft"
        _write_exe(nft_bin, "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "sysctl", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "dpkg-query", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(
            bin_dir / "systemctl",
            "#!/usr/bin/env bash\nprintf 'System has not been booted with systemd\\n' >&2\nexit 1\n",
        )

        apt_text = (REPO_ROOT / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8")
        debloat_fn = _extract_bash_function(REPO_ROOT / "os" / "bootstrap-apt.sh", "run_headless_debloat")
        debloat_fn = debloat_fn.replace("/etc/", f"{root_dir}/etc/").replace(
            "/run/systemd/system", f"{root_dir}/run/systemd/system"
        )
        guard_block = self._extract_net_guard_block(root_dir, nft_bin)
        assert "[[ -d /run/systemd/system ]]" in apt_text

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
KEEP_GUI="false"
DISTRO_FLAVOR="debian"
_DISTRO_TITLE="Debian"
APT_FLAGS=(-y)
SKIP_NET_GUARD="false"
{debloat_fn}
run_headless_debloat
{guard_block}
"""
        p1 = _run_bash(script, env=env)
        assert p1.returncode == 0, f"stdout={p1.stdout}\nstderr={p1.stderr}"
        assert "Skipped" not in p1.stderr

        p2 = _run_bash(script, env=env)
        assert p2.returncode == 0, f"stdout={p2.stdout}\nstderr={p2.stderr}"
        assert "[SKIP]" in p2.stdout

