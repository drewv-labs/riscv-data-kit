"""Lifecycle security, storage autotune, and zsh entrypoint tests."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


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
    pytest.skip("Bash >= 4.0 is required for RVDK lifecycle tests")
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


def _extract_install_cli_managed_dir_fn() -> str:
    text = (REPO_ROOT / "install-cli.sh").read_text(encoding="utf-8")
    pattern = re.compile(
        r"(?ms)^if ! typeset -f rvdk_assert_safe_managed_dir >/dev/null 2>&1; then\n"
        r"(.*?^\s*rvdk_assert_safe_managed_dir\(\)\s*\{.*?^\s*\})\nfi"
    )
    match = pattern.search(text)
    assert match is not None, "Could not extract inline rvdk_assert_safe_managed_dir from install-cli.sh"
    return "\n".join(line.removeprefix("    ") for line in match.group(1).splitlines())


class TestPurgeUserLifecycle:
    def test_static_lock_ordering_and_no_engine_promotion(self) -> None:
        text = (REPO_ROOT / "utils" / "purge-user.sh").read_text(encoding="utf-8")
        lock_idx = text.find('usermod -L "$target_user"')
        term_idx = text.find('loginctl terminate-user "$target_user"')
        pkill_idx = text.find('pkill -KILL -u "$target_uid"')
        step1_idx = text.find("# 1. Promote safe legacy")
        assert -1 not in (lock_idx, term_idx, pkill_idx, step1_idx)
        assert lock_idx < term_idx < pkill_idx < step1_idx
        assert 'Skipped legacy user-owned engine at ${src_home}/.rvdk/engine' in text

    def test_behavioral_pre_step1_lock_and_never_promotes_user_engine(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        event_log = tmp_path / "events.log"
        src_home = tmp_path / "home" / "victim"
        dest_home = tmp_path / "home" / "admin"
        (src_home / ".rvdk" / "engine").mkdir(parents=True)
        (src_home / ".rvdk" / "engine" / "bootstrap.sh").write_text("#!/bin/sh\necho PWN\n", encoding="utf-8")
        dest_home.mkdir(parents=True)

        engine_dir = tmp_path / "sys_engine"
        cache_dir = tmp_path / "sys_cache"

        real_uname = shutil.which("uname") or "/usr/bin/uname"
        _write_exe(
            bin_dir / "uname",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-s" ]]; then
    printf 'Linux\\n'
    exit 0
fi
exec "{real_uname}" "$@"
""",
        )
        _write_exe(
            bin_dir / "id",
            """#!/usr/bin/env bash
case "${1:-}:${2:-}" in
    -u:victim) printf '1001\\n' ;;
    -u:admin)  printf '1000\\n' ;;
    -gn:admin) printf 'admin\\n' ;;
    -u:)       printf '0\\n' ;;
    *)         exit 1 ;;
esac
""",
        )
        _write_exe(
            bin_dir / "getent",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "passwd" ]]; then
    case "${{2:-}}" in
        victim) printf 'victim:x:1001:1001::%s:/bin/bash\\n' "{src_home}" ;;
        admin)  printf 'admin:x:1000:1000::%s:/bin/bash\\n' "{dest_home}" ;;
    esac
fi
""",
        )
        for tool_name in ("usermod", "loginctl", "systemctl", "pkill", "userdel"):
            _write_exe(
                bin_dir / tool_name,
                f"""#!/usr/bin/env bash
printf '%s %s\\n' "{tool_name}" "$*" >> "{event_log}"
exit 0
""",
            )
        _write_exe(bin_dir / "sleep", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "install", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "chown", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "chmod", "#!/usr/bin/env bash\nexit 0\n")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/purge-user.sh"
rvdk_require_root() {{ :; }}
rvdk_resolve_caller() {{ REAL_USER="admin"; }}
rvdk_purge_validate_src_home() {{
    [[ "$1" == "{src_home}" ]]
}}
export RVDK_ENGINE_DIR="{engine_dir}"
export RVDK_CACHE_DIR="{cache_dir}"
export RVDK_ENV_FILE="{tmp_path}/nonexistent.env"
main victim --to-user admin 2>&1 | while IFS= read -r line; do
    printf 'OUT:%s\\n' "$line" >> "{event_log}"
    printf '%s\\n' "$line"
done
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert "Skipped legacy user-owned engine" in proc.stdout
        assert not (engine_dir / "bootstrap.sh").exists()
        assert not engine_dir.exists()

        events = event_log.read_text(encoding="utf-8").splitlines()
        lock_pos = next(i for i, e in enumerate(events) if e == "usermod -L victim")
        term_pos = next(i for i, e in enumerate(events) if e == "loginctl terminate-user victim")
        pkill_pos = next(i for i, e in enumerate(events) if e == "pkill -KILL -u 1001")
        migrate_pos = next(i for i, e in enumerate(events) if "Migrating user-space state" in e)
        assert lock_pos < term_pos < pkill_pos < migrate_pos

    def test_promote_legacy_config_filters_security_keys_and_preserves_safe_keys(
        self, tmp_path: Path
    ) -> None:
        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "install", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "chown", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "chmod", "#!/usr/bin/env bash\nexit 0\n")

        legacy_cfg = tmp_path / "legacy_config.env"
        legacy_cfg.write_text(
            "RVDK_TIMEZONE=America/Chicago\n"
            "RVDK_HOSTNAME=rv-node-01\n"
            "MOUNT_POINT=/mnt/nvme_data\n"
            "RVDK_MIRROR_URL=https://evil.example/mirror\n"
            "PG_PREBUILT_DEB_URL=https://evil.example/pg.tar.zst\n"
            "RVDK_RELEASE_BASE=https://evil.example/rel\n"
            "FORCE_WIPE_NVME=true\n"
            "FORCE_WIPE_RAID=true\n"
            "PG_ALLOW_CIDR=0.0.0.0/0\n"
            "NFS_ALLOW_CIDR=0.0.0.0/0\n"
            "NFS_VAULT_PATH=/etc/shadow\n"
            "RVDK_EDITOR=/tmp/pwn\n"
            "NTFY_VERSION=9.9.9\n",
            encoding="utf-8",
        )

        # Also test MOUNT_POINT=/root explicitly in a second config
        unsafe_mnt_cfg = tmp_path / "unsafe_mnt.env"
        unsafe_mnt_cfg.write_text("MOUNT_POINT=/root\nRVDK_TIMEZONE=UTC\n", encoding="utf-8")

        captured = tmp_path / "promoted.txt"
        captured2 = tmp_path / "promoted2.txt"

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/purge-user.sh"
rvdk_kv_write() {{
    local dst="$1"
    shift 3
    printf 'DST=%s\\n' "$dst" > "{captured}"
    printf '%s\\n' "$@" >> "{captured}"
}}
_rvdk_purge_promote_legacy_config "{legacy_cfg}" "/home/victim"
rvdk_kv_write() {{
    local dst="$1"
    shift 3
    printf '%s\\n' "$@" > "{captured2}"
}}
_rvdk_purge_promote_legacy_config "{unsafe_mnt_cfg}" "/home/victim"
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr

        lines = captured.read_text(encoding="utf-8").splitlines()
        assert lines[0] == "DST=/etc/rvdk/config.env"
        assert lines[1:] == [
            "RVDK_TIMEZONE=America/Chicago",
            "RVDK_HOSTNAME=rv-node-01",
            "MOUNT_POINT=/mnt/nvme_data",
        ]

        lines2 = captured2.read_text(encoding="utf-8").splitlines()
        assert lines2 == ["RVDK_TIMEZONE=UTC"]
        assert "Skipped invalid legacy config key 'MOUNT_POINT'" in proc.stdout


class TestUninstallAndInstallCli:
    @pytest.mark.parametrize("bad_dir", ["/usr/", "/etc/.", "/usr//local"])
    def test_uninstall_dry_run_rejects_unsafe_engine_dir(self, bad_dir: str) -> None:
        proc = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={"RVDK_ENGINE_DIR": bad_dir},
        )
        assert proc.returncode != 0
        assert "Unsafe RVDK_ENGINE_DIR:" in proc.stderr

    def test_uninstall_dry_run_rejects_symlinked_engine_dir(self, tmp_path: Path) -> None:
        real_dir = tmp_path / "real_engine"
        real_dir.mkdir()
        sym_dir = tmp_path / "sym_engine"
        sym_dir.symlink_to(real_dir)

        proc = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={"RVDK_ENGINE_DIR": str(sym_dir)},
        )
        assert proc.returncode != 0
        assert "Unsafe RVDK_ENGINE_DIR:" in proc.stderr
        assert "symbolic link" in proc.stderr

    def test_install_cli_inline_safe_managed_dir_guard(self, tmp_path: Path) -> None:
        fn_def = _extract_install_cli_managed_dir_fn()
        real_dir = tmp_path / "real_engine"
        real_dir.mkdir()
        sym_dir = tmp_path / "sym_engine"
        sym_dir.symlink_to(real_dir)
        home_dir = tmp_path / "home" / "alice"
        home_dir.mkdir(parents=True)

        for bad in ("/usr/", "/usr//local", "/etc/.", str(sym_dir), str(home_dir)):
            proc = _run_bash(
                f"""
set -Eeuo pipefail
log_fatal() {{ printf '%s\\n' "$1" >&2; exit 1; }}
REAL_HOME="{home_dir}"
{fn_def}
rvdk_assert_safe_managed_dir "{bad}" "RVDK_ENGINE_DIR"
"""
            )
            assert proc.returncode != 0, f"Unexpectedly accepted {bad!r}"
            assert "Unsafe RVDK_ENGINE_DIR:" in proc.stderr

        good_proc = _run_bash(
            f"""
set -Eeuo pipefail
log_fatal() {{ printf '%s\\n' "$1" >&2; exit 1; }}
REAL_HOME="{home_dir}"
{fn_def}
rvdk_assert_safe_managed_dir "/usr/local/share/rvdk/engine" "RVDK_ENGINE_DIR"
"""
        )
        assert good_proc.returncode == 0, good_proc.stderr

    def test_uninstall_restore_preserved_backups_includes_boot_category(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        real_uname = shutil.which("uname") or "/usr/bin/uname"
        _write_exe(
            bin_dir / "uname",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-s" ]]; then
    printf 'Linux\\n'
    exit 0
fi
exec "{real_uname}" "$@"
""",
        )

        backup_root = tmp_path / "backups"
        boot_backup = backup_root / "boot" / "etc__kernel__postinst.d__zz-u-boot-menu.orig"
        boot_backup.parent.mkdir(parents=True)
        boot_backup.write_text("#!/bin/sh\n", encoding="utf-8")

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENGINE_DIR": str(tmp_path / "safe" / "engine"),
            "RVDK_CACHE_DIR": str(tmp_path / "safe" / "cache"),
            "RVDK_STATE_DIR": str(tmp_path / "safe" / "state"),
            "RVDK_BACKUP_ROOT": str(backup_root),
        }
        proc = _run_bash(f'"{REPO_ROOT}/utils/uninstall.sh" --purge --dry-run -y', env=env)
        assert proc.returncode == 0, proc.stderr
        assert (
            f"[DRY-RUN] Would restore backup: {boot_backup} -> /etc/kernel/postinst.d/zz-u-boot-menu"
            in proc.stdout
        )


class TestStorageAutotuneGrantCap:
    def test_autotune_awk_caps_last_hungry_grant_at_want_i(self) -> None:
        storage_text = (REPO_ROOT / "utils" / "storage.sh").read_text(encoding="utf-8")
        match = re.search(
            r'grant_out="\$\(awk -v alloc="\$alloc_ext" -v specs="\$w_specs" \'(.*?)\'\)"',
            storage_text,
            flags=re.DOTALL,
        )
        assert match is not None, "Could not locate autotune awk block in utils/storage.sh"
        awk_prog = match.group(1)
        assert "if (g > want[i]) g = want[i];" in awk_prog

        # Case 1: LV1 wants 50 (weight 1), LV2 wants 10 (weight 100), alloc=55 -> rem=52 > want[2]=10.
        # last_hungry (LV2) MUST be capped at 10, never over-allocated to 52.
        proc = subprocess.run(
            ["awk", "-v", "alloc=55", "-v", "specs=50:1 10:100", awk_prog],
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        grants = [int(x) for x in proc.stdout.strip().split()]
        assert grants == [3, 10]
        assert grants[1] <= 10

        # Case 2: Balanced split within caps
        proc2 = subprocess.run(
            ["awk", "-v", "alloc=50", "-v", "specs=40:1 60:1", awk_prog],
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc2.returncode == 0, proc2.stderr
        assert [int(x) for x in proc2.stdout.strip().split()] == [20, 30]


class TestZshEntrypoints:
    @pytest.fixture
    def zsh_bin(self) -> str:
        found = shutil.which("zsh")
        if not found:
            pytest.skip("zsh binary not found on PATH")
        return found

    @pytest.mark.parametrize(
        "argv",
        [
            ["bootstrap.sh", "--help"],
            ["utils/uninstall.sh", "--dry-run"],
            ["utils/storage.sh", "--help"],
            ["utils/purge-user.sh", "--help"],
        ],
    )
    def test_zsh_reexecs_file_entrypoint_and_exits_zero(self, zsh_bin: str, argv: list[str]) -> None:
        proc = subprocess.run(
            [zsh_bin, *argv],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr

    @pytest.mark.parametrize(
        "rel_path",
        [
            "bootstrap.sh",
            "install-cli.sh",
            "utils/storage.sh",
            "utils/uninstall.sh",
            "utils/purge-user.sh",
        ],
    )
    def test_zsh_stdin_pipe_fails_fast_with_bash_instruction(
        self, zsh_bin: str, rel_path: str
    ) -> None:
        script_bytes = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
        proc = subprocess.run(
            [zsh_bin],
            input=script_bytes,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 1
        assert "curl ... | sudo bash" in proc.stderr
