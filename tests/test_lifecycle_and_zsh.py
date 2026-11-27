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

    def test_promote_legacy_config_accepts_iot_tune_and_rejects_invalid_tune(
        self, tmp_path: Path
    ) -> None:
        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "install", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "chown", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "chmod", "#!/usr/bin/env bash\nexit 0\n")

        iot_cfg = tmp_path / "iot.env"
        iot_cfg.write_text("RVDK_TUNE=iot\nRVDK_HOSTNAME=iot-node-01\n", encoding="utf-8")

        bad_cfg = tmp_path / "bad_tune.env"
        bad_cfg.write_text("RVDK_TUNE=bogus\nRVDK_TIMEZONE=UTC\n", encoding="utf-8")

        cap_iot = tmp_path / "promoted_iot.txt"
        cap_bad = tmp_path / "promoted_bad.txt"

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/purge-user.sh"
rvdk_kv_write() {{
    local dst="$1"
    shift 3
    printf '%s\\n' "$@" > "{cap_iot}"
}}
_rvdk_purge_promote_legacy_config "{iot_cfg}" "/home/victim"
rvdk_kv_write() {{
    local dst="$1"
    shift 3
    printf '%s\\n' "$@" > "{cap_bad}"
}}
_rvdk_purge_promote_legacy_config "{bad_cfg}" "/home/victim"
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert cap_iot.read_text(encoding="utf-8").splitlines() == [
            "RVDK_HOSTNAME=iot-node-01",
            "RVDK_TUNE=iot",
        ]
        assert cap_bad.read_text(encoding="utf-8").splitlines() == ["RVDK_TIMEZONE=UTC"]
        assert "Skipped invalid legacy config key 'RVDK_TUNE'" in proc.stdout


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

    def test_uninstall_xdg_cache_home_confinement_and_symlink_rejection(self, tmp_path: Path) -> None:
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

        home_base = tmp_path / "home"
        real_home = home_base / "alice"
        fallback_cache = real_home / ".cache" / "rvdk"
        fallback_cache.mkdir(parents=True)

        prefix_twin_cache = home_base / "alice2" / ".cache" / "rvdk"
        prefix_twin_cache.mkdir(parents=True)

        outside_dir = tmp_path / "outside"
        (outside_dir / "rvdk").mkdir(parents=True)
        sym_in_home = real_home / "sym_cache"
        sym_in_home.symlink_to(outside_dir)

        custom_cache = real_home / ".custom_cache"
        (custom_cache / "rvdk").mkdir(parents=True)

        _write_exe(
            bin_dir / "getent",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "passwd" ]]; then
    printf '%s:x:1000:1000::%s:/bin/bash\\n' "${{2:-alice}}" "{real_home}"
fi
""",
        )

        base_env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENGINE_DIR": str(tmp_path / "safe" / "engine"),
            "RVDK_CACHE_DIR": str(tmp_path / "safe" / "cache"),
            "RVDK_STATE_DIR": str(tmp_path / "safe" / "state"),
        }

        # 1. XDG_CACHE_HOME=/var/lib must be rejected with [WARN], never target /var/lib/rvdk, and fall back
        proc_varlib = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={**base_env, "XDG_CACHE_HOME": "/var/lib"},
        )
        assert proc_varlib.returncode == 0, proc_varlib.stderr
        assert "[WARN]" in proc_varlib.stdout
        assert "/var/lib/rvdk" not in proc_varlib.stdout
        assert f"[DRY-RUN] Would remove: {fallback_cache}" in proc_varlib.stdout

        # 2. Prefix confusion (${REAL_HOME}2) must be rejected and fall back to REAL_HOME/.cache/rvdk
        proc_twin = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={**base_env, "XDG_CACHE_HOME": str(home_base / "alice2" / ".cache")},
        )
        assert proc_twin.returncode == 0, proc_twin.stderr
        assert "[WARN]" in proc_twin.stdout
        assert str(prefix_twin_cache) not in proc_twin.stdout
        assert f"[DRY-RUN] Would remove: {fallback_cache}" in proc_twin.stdout

        # 3. Symlink component inside REAL_HOME must be rejected and fall back safely
        proc_sym = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={**base_env, "XDG_CACHE_HOME": str(sym_in_home)},
        )
        assert proc_sym.returncode == 0, proc_sym.stderr
        assert "[WARN]" in proc_sym.stdout
        assert str(sym_in_home / "rvdk") not in proc_sym.stdout
        assert str(outside_dir / "rvdk") not in proc_sym.stdout
        assert f"[DRY-RUN] Would remove: {fallback_cache}" in proc_sym.stdout

        # 4. Valid XDG_CACHE_HOME strictly inside REAL_HOME is accepted with zero warning
        proc_valid = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={**base_env, "XDG_CACHE_HOME": str(custom_cache)},
        )
        assert proc_valid.returncode == 0, proc_valid.stderr
        assert "[WARN]" not in proc_valid.stdout
        assert f"[DRY-RUN] Would remove: {custom_cache / 'rvdk'}" in proc_valid.stdout

        # 5. Relative / traversal XDG_CACHE_HOME must be rejected and fall back safely
        proc_rel = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={**base_env, "XDG_CACHE_HOME": f"{real_home}/../outside"},
        )
        assert proc_rel.returncode == 0, proc_rel.stderr
        assert "[WARN]" in proc_rel.stdout
        assert str(outside_dir / "rvdk") not in proc_rel.stdout
        assert f"[DRY-RUN] Would remove: {fallback_cache}" in proc_rel.stdout

        # 6. Symlinked fallback (${REAL_HOME}/.cache -> outside) must ALSO be rejected safely
        shutil.rmtree(real_home / ".cache")
        (real_home / ".cache").symlink_to(outside_dir)
        proc_bad_fb = _run_bash(
            f'"{REPO_ROOT}/utils/uninstall.sh" --dry-run',
            env={**base_env, "XDG_CACHE_HOME": "/var/lib"},
        )
        assert proc_bad_fb.returncode == 0, proc_bad_fb.stderr
        assert "[WARN]" in proc_bad_fb.stdout
        assert f"Would remove: {fallback_cache}" not in proc_bad_fb.stdout
        assert str(outside_dir / "rvdk") not in proc_bad_fb.stdout

    def test_uninstall_purge_dry_run_includes_iot_cpufreq_units(self, tmp_path: Path) -> None:
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

        systemd_dir = tmp_path / "etc" / "systemd" / "system"
        systemd_dir.mkdir(parents=True)
        (systemd_dir / "eic7700x-cpufreq-iot.service").write_text("[Unit]\n", encoding="utf-8")
        (systemd_dir / "spacemit-k1-cpufreq-iot.service").write_text("[Unit]\n", encoding="utf-8")

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENGINE_DIR": str(tmp_path / "safe" / "engine"),
            "RVDK_CACHE_DIR": str(tmp_path / "safe" / "cache"),
            "RVDK_STATE_DIR": str(tmp_path / "safe" / "state"),
            "RVDK_SYSTEMD_UNIT_DIR": str(systemd_dir),
        }
        proc = _run_bash(f'"{REPO_ROOT}/utils/uninstall.sh" --purge --dry-run -y', env=env)
        assert proc.returncode == 0, proc.stderr
        assert (
            f"[DRY-RUN] Would disable & remove systemd unit: {systemd_dir}/eic7700x-cpufreq-iot.service"
            in proc.stdout
        )
        assert (
            f"[DRY-RUN] Would disable & remove systemd unit: {systemd_dir}/spacemit-k1-cpufreq-iot.service"
            in proc.stdout
        )

    def test_uninstall_restore_preserved_backups_path_sidecar_and_deeptune(self, tmp_path: Path) -> None:
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
        deeptune_dir = backup_root / "deeptune"
        deeptune_dir.mkdir(parents=True)

        # Standard .path sidecar (exact path containing '__' that stem decoding alone would mangle)
        k1_orig = deeptune_dir / "etc__modules-load.d__my__custom.conf.orig"
        k1_orig.write_text("# modules\n", encoding="utf-8")
        (deeptune_dir / "etc__modules-load.d__my__custom.conf.path").write_text(
            "/etc/modules-load.d/my__custom.conf\n", encoding="utf-8"
        )

        # .orig.path sidecar variant
        apt_dir = backup_root / "apt"
        apt_dir.mkdir(parents=True)
        apt_orig = apt_dir / "custom_repo.orig"
        apt_orig.write_text("deb https://deb.debian.org/debian trixie main\n", encoding="utf-8")
        (apt_dir / "custom_repo.orig.path").write_text(
            "/etc/apt/sources.list.d/vendor__repo.list\n", encoding="utf-8"
        )

        # Unsafe sidecars (traversal, symlink, protected /etc/config/network) must all be ignored
        bad_trav = apt_dir / "bad_trav.orig"
        bad_trav.write_text("x\n", encoding="utf-8")
        (apt_dir / "bad_trav.path").write_text("/etc/apt/../shadow\n", encoding="utf-8")

        bad_sym = apt_dir / "bad_sym.orig"
        bad_sym.write_text("x\n", encoding="utf-8")
        (apt_dir / "bad_sym.path").symlink_to("/etc/passwd")

        bad_multi = apt_dir / "bad_multi.orig"
        bad_multi.write_text("x\n", encoding="utf-8")
        (apt_dir / "bad_multi.path").write_text("/etc/apt/a.list\n/etc/apt/b.list\n", encoding="utf-8")

        owrt_dir = backup_root / "openwrt"
        owrt_dir.mkdir(parents=True)
        bad_net = owrt_dir / "net.orig"
        bad_net.write_text("x\n", encoding="utf-8")
        (owrt_dir / "net.path").write_text("/etc/config/network\n", encoding="utf-8")

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
            f"[DRY-RUN] Would restore backup: {k1_orig} -> /etc/modules-load.d/my__custom.conf"
            in proc.stdout
        )
        assert (
            f"[DRY-RUN] Would restore backup: {apt_orig} -> /etc/apt/sources.list.d/vendor__repo.list"
            in proc.stdout
        )
        assert "/etc/apt/../shadow" not in proc.stdout
        assert "/etc/passwd" not in proc.stdout
        assert "/etc/apt/a.list" not in proc.stdout
        assert "/etc/config/network" not in proc.stdout

    def test_uninstall_purge_removes_rv2_dropins_and_unmasks_recorded_user_units(
        self, tmp_path: Path
    ) -> None:
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
        _write_exe(bin_dir / "systemctl", "#!/usr/bin/env bash\nexit 0\n")

        sys_unit_dir = tmp_path / "etc" / "systemd" / "system"
        user_unit_dir = tmp_path / "etc" / "systemd" / "user"
        backup_root = tmp_path / "var" / "lib" / "rvdk" / "backups"
        irq_d = sys_unit_dir / "spacemit-k1-irq-affinity.service.d"
        cpu_d = sys_unit_dir / "spacemit-k1-cpufreq-iot.service.d"
        irq_d.mkdir(parents=True)
        cpu_d.mkdir(parents=True)
        (irq_d / "90-rvdk-orangepi-rv2.conf").write_text("[Service]\n", encoding="utf-8")
        (cpu_d / "90-rvdk-orangepi-rv2.conf").write_text("[Service]\n", encoding="utf-8")

        user_unit_dir.mkdir(parents=True)
        (user_unit_dir / "tracker-miner-fs-3.service").symlink_to("/dev/null")
        (user_unit_dir / "non_null.service").write_text("[Unit]\n", encoding="utf-8")
        (user_unit_dir / "user_existing.service").symlink_to("/dev/null")
        (backup_root / "systemd-user").mkdir(parents=True)
        (backup_root / "systemd-user" / "masked.list").write_text(
            "tracker-miner-fs-3.service\n../escape.service\nnon_null.service\n",
            encoding="utf-8",
        )

        # Also stage deeptune backups of journald.conf & cpufrequtils to verify dry-run restore plan
        (backup_root / "deeptune").mkdir(parents=True)
        (backup_root / "deeptune" / "etc__systemd__journald.conf.orig").write_text("[Journal]\n", encoding="utf-8")
        (backup_root / "deeptune" / "etc__systemd__journald.conf.path").write_text(
            "/etc/systemd/journald.conf\n", encoding="utf-8"
        )
        (backup_root / "deeptune" / "etc__default__cpufrequtils.orig").write_text("GOVERNOR=ondemand\n", encoding="utf-8")
        (backup_root / "deeptune" / "etc__default__cpufrequtils.path").write_text(
            "/etc/default/cpufrequtils\n", encoding="utf-8"
        )

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENGINE_DIR": str(tmp_path / "safe" / "engine"),
            "RVDK_CACHE_DIR": str(tmp_path / "safe" / "cache"),
            "RVDK_STATE_DIR": str(tmp_path / "safe" / "state"),
            "RVDK_BACKUP_ROOT": str(backup_root),
            "RVDK_SYSTEMD_UNIT_DIR": str(sys_unit_dir),
            "RVDK_SYSTEMD_USER_UNIT_DIR": str(user_unit_dir),
        }

        # 1. Dry-run verifies journald.conf + cpufrequtils backup restore + drop-ins + unmask plan
        p_dry = _run_bash(f'"{REPO_ROOT}/utils/uninstall.sh" --purge --dry-run -y', env=env)
        assert p_dry.returncode == 0, p_dry.stderr
        assert "-> /etc/systemd/journald.conf" in p_dry.stdout
        assert "-> /etc/default/cpufrequtils" in p_dry.stdout
        assert "90-rvdk-orangepi-rv2.conf" in p_dry.stdout
        assert f"Would unmask systemd user unit: {user_unit_dir}/tracker-miner-fs-3.service" in p_dry.stdout
        assert f"Would unmask systemd user unit: {user_unit_dir}/../escape.service" not in p_dry.stdout
        assert "Skipped unsafe unit entry in" in p_dry.stdout

        # 2. Live execution against isolated temp dirs (sandbox remove_path strictly to tmp_path)
        uninstall_src = (REPO_ROOT / "utils" / "uninstall.sh").read_text(encoding="utf-8")
        patched_uninstall = tmp_path / "uninstall_live.sh"
        patched_uninstall.write_text(
            uninstall_src.replace(
                'rvdk_require_root "$script_self" ${orig_args[@]+"${orig_args[@]}"}',
                "true",
                1,
            ).replace(
                '    remove_path() {\n        local p="$1"',
                f'    remove_path() {{\n        local p="$1"\n        [[ "$p" == "{tmp_path}"/* ]] || return 0',
                1,
            ).replace(
                "                restore_preserved_backups\n",
                "                true # skip host /etc restore in sandboxed live test\n",
                1,
            ),
            encoding="utf-8",
        )
        p_live = _run_bash(f'bash "{patched_uninstall}" --purge -y', env=env)
        assert p_live.returncode == 0, f"stdout={p_live.stdout}\nstderr={p_live.stderr}"
        assert not irq_d.exists(), "Empty spacemit-k1-irq-affinity.service.d should be removed"
        assert not cpu_d.exists(), "Empty spacemit-k1-cpufreq-iot.service.d should be removed"
        assert not (user_unit_dir / "tracker-miner-fs-3.service").exists()
        assert (user_unit_dir / "non_null.service").is_file(), "Non-/dev/null regular file must not be removed"
        assert (user_unit_dir / "user_existing.service").is_symlink(), "Unrecorded user mask must remain intact"

    def test_install_cli_ref_pinning_detached_checkout_and_rejects_malformed_ref(
        self, tmp_path: Path
    ) -> None:
        # Build a tiny local git repository with 2 commits and a tag v1.0.0
        upstream = tmp_path / "upstream"
        upstream.mkdir()
        git_env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "RVDK Test",
            "GIT_AUTHOR_EMAIL": "ci@rvdk.drewv-labs.dev",
            "GIT_COMMITTER_NAME": "RVDK Test",
            "GIT_COMMITTER_EMAIL": "ci@rvdk.drewv-labs.dev",
        }
        subprocess.run(["git", "init", "-b", "main", str(upstream)], check=True, capture_output=True, env=git_env)
        (upstream / "bootstrap.sh").write_text("#!/usr/bin/env bash\necho v1\n", encoding="utf-8")
        (upstream / "bootstrap.sh").chmod(0o755)
        subprocess.run(["git", "-C", str(upstream), "add", "bootstrap.sh"], check=True, capture_output=True, env=git_env)
        subprocess.run(["git", "-C", str(upstream), "commit", "-m", "v1"], check=True, capture_output=True, env=git_env)
        commit1 = subprocess.run(
            ["git", "-C", str(upstream), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            env=git_env,
        ).stdout.strip()
        subprocess.run(["git", "-C", str(upstream), "tag", "v1.0.0"], check=True, capture_output=True, env=git_env)

        (upstream / "bootstrap.sh").write_text("#!/usr/bin/env bash\necho v2\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(upstream), "add", "bootstrap.sh"], check=True, capture_output=True, env=git_env)
        subprocess.run(["git", "-C", str(upstream), "commit", "-m", "v2"], check=True, capture_output=True, env=git_env)

        install_src = (REPO_ROOT / "install-cli.sh").read_text(encoding="utf-8")
        bin_dir_out = tmp_path / "local_bin"
        bin_dir_out.mkdir()
        patched_cli = tmp_path / "install_cli_test.sh"
        patched_cli.write_text(
            install_src.replace("if [[ $EUID -ne 0 ]]; then", "if false; then", 1)
            .replace('RVDK_ENGINE_DIR="${RVDK_ENGINE_DIR:-/opt/rvdk}"', f'RVDK_ENGINE_DIR="{tmp_path / "opt" / "rvdk"}"', 1)
            .replace("/usr/local/bin/rvdk", str(bin_dir_out / "rvdk"))
            .replace("/usr/local/bin", str(bin_dir_out))
            .replace("/usr/bin/rvdk", str(bin_dir_out / "rvdk_usr"))
            .replace("chown -R", "true # chown -R")
            .replace('if [[ "$(uname -s)" == "Linux" ]]; then', "if false; then"),
            encoding="utf-8",
        )
        env = {
            "PATH": os.environ["PATH"],
            "RVDK_ENGINE_DIR": str(tmp_path / "opt" / "rvdk"),
            "RVDK_REPO_URL": str(upstream),
            "RVDK_NO_PROGBAR": "1",
        }

        # 1. Malformed --ref rejected
        p_bad = _run_bash(f'bash "{patched_cli}" --ref "bad;ref"', env=env)
        assert p_bad.returncode != 0
        assert "Invalid --ref value" in p_bad.stderr

        # 2. Fresh clone pinned to tag v1.0.0 checks out detached HEAD at commit1
        p_tag = _run_bash(f'bash "{patched_cli}" --ref v1.0.0', env=env)
        assert p_tag.returncode == 0, f"stdout={p_tag.stdout}\nstderr={p_tag.stderr}"
        engine_dir = tmp_path / "opt" / "rvdk"
        head_after_tag = subprocess.run(
            ["git", "-C", str(engine_dir), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert head_after_tag == commit1
        assert "echo v1" in (engine_dir / "bootstrap.sh").read_text(encoding="utf-8")

        # 3. Re-run pinned to explicit commit SHA remains converged on commit1
        p_sha = _run_bash(f'bash "{patched_cli}" --ref "{commit1}"', env=env)
        assert p_sha.returncode == 0, f"stdout={p_sha.stdout}\nstderr={p_sha.stderr}"
        head_after_sha = subprocess.run(
            ["git", "-C", str(engine_dir), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert head_after_sha == commit1


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

    def test_autotune_healthy_summary_uses_comma_space_separator(self, tmp_path: Path) -> None:
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
        _write_exe(
            bin_dir / "vgs",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "vg_rvdk" ]]; then
    exit 0
fi
if [[ "$*" == *"vg_size,vg_free"* ]]; then
    printf '107374182400 21474836480 4194304 25600 5120\\n'
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "lvs",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "--noheadings" && "${2:-}" == "-o" && "${3:-}" == "lv_name" ]]; then
    printf '  lv_a\\n  lv_b\\n'
    exit 0
fi
if [[ "${1:-}" == "vg_rvdk/lv_a" || "${1:-}" == "vg_rvdk/lv_b" ]]; then
    exit 0
fi
if [[ "$*" == *"lv_size"* ]]; then
    printf '42949672960\\n'
    exit 0
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "findmnt",
            """#!/usr/bin/env bash
case "$*" in
    *"-S /dev/vg_rvdk/lv_a -o TARGET"*) printf '/mnt/lv_a\\n' ;;
    *"-S /dev/vg_rvdk/lv_b -o TARGET"*) printf '/mnt/lv_b\\n' ;;
    *"-M /mnt/lv_a -o FSTYPE"*) printf 'xfs\\n' ;;
    *"-M /mnt/lv_b -o FSTYPE"*) printf 'btrfs\\n' ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "df",
            """#!/usr/bin/env bash
printf '1B-blocks Used Avail\\n'
case "${*: -1}" in
    /mnt/lv_a) printf '42949672960 17179869184 25769803776\\n' ;;
    /mnt/lv_b) printf '42949672960 8589934592 34359738368\\n' ;;
esac
exit 0
""",
        )

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/storage.sh"
rvdk_require_root() {{ :; }}
export RVDK_ENV_FILE="{tmp_path}/nonexistent.env"
main autotune --vg vg_rvdk --dry-run
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert "All mounted volumes healthy below 75% high-water mark (lv_a: 40%, lv_b: 20%)." in proc.stdout


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
