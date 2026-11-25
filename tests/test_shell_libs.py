"""Bash subprocess tests for RVDK shell libraries and storage/purge helpers."""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import time
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
    pytest.skip("Bash >= 4.0 is required for RVDK shell library tests")
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


def _extract_bash_function(file_path: Path, fn_name: str) -> str:
    text = file_path.read_text(encoding="utf-8")
    pattern = re.compile(rf"(?ms)^{re.escape(fn_name)}\(\)\s*\{{.*?^\}}")
    match = pattern.search(text)
    assert match is not None, f"Could not extract {fn_name}() from {file_path}"
    return match.group(0)


class TestRvdkKvLoad:
    def test_quoting_unescaping_preserve_existing_and_allowed_filtering(self, tmp_path: Path) -> None:
        env_file = tmp_path / "config.env"
        env_file.write_text(
            "# comment line\n"
            "  export SINGLE_VAL='hello # world $HOME $(id) `uname`'\n"
            'DOUBLE_VAL="a\\\\b \\"c\\" \\$d \\`e\\`"\n'
            "UNQUOTED_VAL=bare_value # inline comment\n"
            "OVERWRITE_ME=from_file\n"
            "KEEP_ME=from_file\n"
            "DISALLOWED_KEY=should_not_load\n",
            encoding="utf-8",
        )

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
OVERWRITE_ME=""
KEEP_ME="caller_value"
DISALLOWED_KEY="unchanged"
rvdk_kv_load "{env_file}" --preserve-existing SINGLE_VAL DOUBLE_VAL UNQUOTED_VAL OVERWRITE_ME KEEP_ME
printf 'SINGLE=%s\\n' "$SINGLE_VAL"
printf 'DOUBLE=%s\\n' "$DOUBLE_VAL"
printf 'UNQUOTED=%s\\n' "$UNQUOTED_VAL"
printf 'OVERWRITE=%s\\n' "$OVERWRITE_ME"
printf 'KEEP=%s\\n' "$KEEP_ME"
printf 'DISALLOWED=%s\\n' "$DISALLOWED_KEY"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == [
            "SINGLE=hello # world $HOME $(id) `uname`",
            'DOUBLE=a\\b "c" $d `e`',
            "UNQUOTED=bare_value",
            "OVERWRITE=from_file",
            "KEEP=caller_value",
            "DISALLOWED=unchanged",
        ]

    def test_kv_write_round_trip(self, tmp_path: Path) -> None:
        env_file = tmp_path / "written.env"
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_kv_write "{env_file}" 0600 "Test Header" 'A=slash\\quote"dollar$tick`end' 'B=plain'
unset A B
rvdk_kv_load "{env_file}" A B
printf 'A=%s\\nB=%s\\n' "$A" "$B"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == [
            'A=slash\\quote"dollar$tick`end',
            "B=plain",
        ]

    def test_multiline_rejection_and_no_eval_invariant(self, tmp_path: Path) -> None:
        pwn1 = tmp_path / "pwned_unquoted"
        pwn2 = tmp_path / "pwned_double"
        pwn3 = tmp_path / "pwned_single"
        pwn4 = tmp_path / "pwned_backtick"
        pwn5 = tmp_path / "pwned_multiline"

        env_file = tmp_path / "evil.env"
        env_file.write_bytes(
            f"CMD_UNQUOTED=$(touch {pwn1})\n"
            f'CMD_DOUBLE="$(touch {pwn2})"\n'
            f"CMD_SINGLE='$(touch {pwn3})'\n"
            f"CMD_TICK=`touch {pwn4}`\n".encode()
            + b'CR_MULTILINE="first\rsecond"\n'
            + f'SPLIT_LINE="line1\ntouch {pwn5}"\n'.encode()
        )

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
CR_MULTILINE="unset"
rvdk_kv_load "{env_file}" CMD_UNQUOTED CMD_DOUBLE CMD_SINGLE CMD_TICK CR_MULTILINE SPLIT_LINE
printf 'U=%s\\nD=%s\\nS=%s\\nT=%s\\nCR=%s\\nSP=%s\\n' \\
    "$CMD_UNQUOTED" "$CMD_DOUBLE" "$CMD_SINGLE" "$CMD_TICK" "$CR_MULTILINE" "$SPLIT_LINE"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert not pwn1.exists()
        assert not pwn2.exists()
        assert not pwn3.exists()
        assert not pwn4.exists()
        assert not pwn5.exists()
        assert "Ignored multiline value for 'CR_MULTILINE'" in proc.stdout
        assert "CR=unset" in proc.stdout.splitlines()
        assert f"U=$(touch {pwn1})" in proc.stdout.splitlines()
        assert f"D=$(touch {pwn2})" in proc.stdout.splitlines()
        assert f"S=$(touch {pwn3})" in proc.stdout.splitlines()
        assert f"T=`touch {pwn4}`" in proc.stdout.splitlines()


class TestRvdkRegisterCleanup:
    def test_lifo_order_deduplication_and_exit_code_preservation(self, tmp_path: Path) -> None:
        log_file = tmp_path / "cleanup.log"
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
hook_a() {{ echo "hook_a" >> "{log_file}"; }}
hook_b() {{ echo "hook_b" >> "{log_file}"; }}
hook_c() {{ echo "hook_c" >> "{log_file}"; }}
rvdk_register_cleanup hook_a
rvdk_register_cleanup hook_b
rvdk_register_cleanup hook_a
rvdk_register_cleanup hook_c
exit 42
"""
        proc = _run_bash(script)
        assert proc.returncode == 42
        assert log_file.read_text(encoding="utf-8").splitlines() == ["hook_c", "hook_b", "hook_a"]

    def test_subshell_isolation_does_not_wipe_parent_hooks(self, tmp_path: Path) -> None:
        log_file = tmp_path / "subshell.log"
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
parent_hook() {{ echo "parent" >> "{log_file}"; }}
sub_hook() {{ echo "sub" >> "{log_file}"; }}
rvdk_register_cleanup parent_hook
(
    rvdk_register_cleanup sub_hook
    echo "in_subshell" >> "{log_file}"
)
echo "after_subshell" >> "{log_file}"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert log_file.read_text(encoding="utf-8").splitlines() == [
            "in_subshell",
            "sub",
            "after_subshell",
            "parent",
        ]

    @pytest.mark.parametrize(
        ("sig", "expected_rc"),
        [
            (signal.SIGINT, 130),
            (signal.SIGTERM, 143),
        ],
    )
    def test_signal_exit_codes_and_cleanup_execution(
        self, tmp_path: Path, sig: signal.Signals, expected_rc: int
    ) -> None:
        pid_file = tmp_path / "child.pid"
        cleaned_file = tmp_path / "cleaned.txt"
        child_script = tmp_path / "child.sh"
        child_script.write_text(
            f"""set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
sleep_pid=""
on_clean() {{
    echo "cleaned:{sig.name}" >> "{cleaned_file}"
    [[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null || true
}}
rvdk_register_cleanup on_clean
printf '%s\\n' "$$" > "{pid_file}"
sleep 30 >/dev/null 2>&1 &
sleep_pid="$!"
wait "$sleep_pid"
""",
            encoding="utf-8",
        )

        # Invoke child via an outer bash shell (with `; exit $?` to prevent exec optimization)
        # so POSIX/bash wait status (128 + sig) is observed.
        proc = subprocess.Popen(
            [BASH_BIN, "-c", '"$1" "$2"; exit $?', "_", BASH_BIN, str(child_script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5.0
            while not pid_file.exists() or not pid_file.read_text(encoding="utf-8").strip():
                assert time.monotonic() < deadline, "Timed out waiting for child PID"
                time.sleep(0.02)
            child_pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(child_pid, sig)
            _, stderr = proc.communicate(timeout=5.0)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        assert proc.returncode == expected_rc, stderr
        assert cleaned_file.read_text(encoding="utf-8").splitlines() == [f"cleaned:{sig.name}"]

    @pytest.mark.parametrize("no_progbar_env", ["1", "0"])
    def test_prog_init_does_not_clobber_user_hooks_and_reaps_apt_stamp(
        self, tmp_path: Path, no_progbar_env: str
    ) -> None:
        log_file = tmp_path / "prog_cleanup.log"
        stamp_file = tmp_path / "apt.stamp"
        stamp_file.write_text("stamp", encoding="utf-8")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/progbar.sh"
user_hook() {{ echo "user_hook_ran" >> "{log_file}"; }}
rvdk_register_cleanup user_hook
_RVDK_OWN_APT_STAMP="{stamp_file}"
export RVDK_NO_PROGBAR="{no_progbar_env}"
rvdk_prog_init "Testing non-clobber"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert log_file.read_text(encoding="utf-8").splitlines() == ["user_hook_ran"]
        assert not stamp_file.exists()


class TestFstabConvergence:
    def _make_systemctl_spy(self, tmp_path: Path) -> tuple[Path, Path]:
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        spy_log = tmp_path / "systemctl.log"
        systemctl = bin_dir / "systemctl"
        systemctl.write_text(
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{spy_log}"\nexit 1\n',
            encoding="utf-8",
        )
        systemctl.chmod(0o755)
        return bin_dir, spy_log

    def test_nvme_converge_fstab_entry_dual_lv_idempotency(self, tmp_path: Path) -> None:
        bin_dir, spy_log = self._make_systemctl_spy(tmp_path)
        fn_body = _extract_bash_function(REPO_ROOT / "mods" / "nvme-4kn" / "forge.sh", "converge_fstab_entry")
        fstab = tmp_path / "fstab"
        fstab.write_text(
            "# /etc/fstab: static file system information.\n"
            "UUID=root-1234  /  ext4  defaults  0  1\n"
            "LABEL=RVDK_NVME  /mnt/nvme_data  ext4  defaults  0  2\n"
            "UUID=boot-5678  /boot  vfat  defaults  0  2\n",
            encoding="utf-8",
        )

        pri_entry = "LABEL=RVDK_NVME  /mnt/nvme_data  xfs  rw,noatime,nodiratime,nofail  0  2"
        sec_entry = "LABEL=RVDK_SECONDARY  /mnt/nvme_secondary  btrfs  rw,noatime,compress=zstd:3,nofail  0  2"

        pass_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
{fn_body}
converge_fstab_entry "LABEL=RVDK_NVME" "/mnt/nvme_data" "xfs" "{pri_entry}" "{fstab}"
converge_fstab_entry "LABEL=RVDK_SECONDARY" "/mnt/nvme_secondary" "btrfs" "{sec_entry}" "{fstab}"
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        run1 = _run_bash(pass_script, env=env)
        assert run1.returncode == 0, run1.stderr
        assert "[OK]" in run1.stdout
        assert not spy_log.exists()

        expected = (
            "# /etc/fstab: static file system information.\n"
            "UUID=root-1234  /  ext4  defaults  0  1\n"
            f"{pri_entry}\n"
            "UUID=boot-5678  /boot  vfat  defaults  0  2\n"
            f"{sec_entry}\n"
        )
        assert fstab.read_text(encoding="utf-8") == expected

        # Pass 2: zero diff, [SKIP] on both, zero systemctl invocations
        run2 = _run_bash(pass_script, env=env)
        assert run2.returncode == 0, run2.stderr
        assert run2.stdout.count("[SKIP]") == 2
        assert "[OK]" not in run2.stdout
        assert fstab.read_text(encoding="utf-8") == expected
        assert not spy_log.exists()

    def test_btrfs_converge_fstab_entry_multi_array_idempotency(self, tmp_path: Path) -> None:
        bin_dir, spy_log = self._make_systemctl_spy(tmp_path)
        fn_body = _extract_bash_function(
            REPO_ROOT / "mods" / "btrfs-raid" / "forge.sh", "_btrfs_converge_fstab_entry"
        )
        fstab = tmp_path / "fstab"
        fstab.write_text(
            "# Header comment\n"
            "UUID=root-1234  /  ext4  defaults  0  1\n"
            "LABEL=OLD_WARM  /mnt/raid_warm  btrfs  defaults  0  2\n"
            "UUID=swap-9999  none  swap  sw  0  0\n",
            encoding="utf-8",
        )

        arr1 = "LABEL=RVDK_RAID10  /mnt/raid_warm  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail  0  2"
        arr2 = "LABEL=RVDK_RAID1  /mnt/raid_cold  btrfs  rw,noatime,compress=zstd:3,space_cache=v2,nofail  0  2"

        pass_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
{fn_body}
_btrfs_converge_fstab_entry "LABEL=RVDK_RAID10" "/mnt/raid_warm" "{arr1}" "{fstab}"
_btrfs_converge_fstab_entry "LABEL=RVDK_RAID1" "/mnt/raid_cold" "{arr2}" "{fstab}"
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        run1 = _run_bash(pass_script, env=env)
        assert run1.returncode == 0, run1.stderr
        assert run1.stdout.count("[OK]") == 2
        assert not spy_log.exists()

        expected = (
            "# Header comment\n"
            "UUID=root-1234  /  ext4  defaults  0  1\n"
            f"{arr1}\n"
            "UUID=swap-9999  none  swap  sw  0  0\n"
            f"{arr2}\n"
        )
        assert fstab.read_text(encoding="utf-8") == expected

        run2 = _run_bash(pass_script, env=env)
        assert run2.returncode == 0, run2.stderr
        assert run2.stdout.count("[SKIP]") == 2
        assert "[OK]" not in run2.stdout
        assert fstab.read_text(encoding="utf-8") == expected
        assert not spy_log.exists()


class TestLibBsp:
    def test_parse_lsblk_line_empty_fstype_does_not_shift_size_or_label(self) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/bsp.sh"
_rvdk_bsp_parse_lsblk_line 'PATH="/dev/mmcblk0p2" TYPE="part" FSTYPE="" SIZE="1073741824" LABEL="rootfs"'
printf 'PATH=%s|TYPE=%s|FSTYPE=%s|SIZE=%s|LABEL=%s\\n' \\
    "$_RVDK_LSBLK_PATH" "$_RVDK_LSBLK_TYPE" "$_RVDK_LSBLK_FSTYPE" "$_RVDK_LSBLK_SIZE" "$_RVDK_LSBLK_LABEL"
_rvdk_bsp_parse_lsblk_line 'PATH="/dev/mmcblk0p3" TYPE="part" FSTYPE="ext4" SIZE="8589934592" LABEL=""'
printf 'PATH=%s|TYPE=%s|FSTYPE=%s|SIZE=%s|LABEL=%s\\n' \\
    "$_RVDK_LSBLK_PATH" "$_RVDK_LSBLK_TYPE" "$_RVDK_LSBLK_FSTYPE" "$_RVDK_LSBLK_SIZE" "$_RVDK_LSBLK_LABEL"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == [
            "PATH=/dev/mmcblk0p2|TYPE=part|FSTYPE=|SIZE=1073741824|LABEL=rootfs",
            "PATH=/dev/mmcblk0p3|TYPE=part|FSTYPE=ext4|SIZE=8589934592|LABEL=",
        ]

    def test_select_root_part_ignores_empty_fstype_and_boot_partitions(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        lsblk_shim = bin_dir / "lsblk"
        lsblk_shim.write_text(
            """#!/usr/bin/env bash
cat <<'EOF'
PATH="/dev/mmcblk0" TYPE="disk" FSTYPE="" SIZE="31914983424" LABEL=""
PATH="/dev/mmcblk0p1" TYPE="part" FSTYPE="" SIZE="16777216" LABEL=""
PATH="/dev/mmcblk0p2" TYPE="part" FSTYPE="ext4" SIZE="536870912" LABEL="bootfs"
PATH="/dev/mmcblk0p3" TYPE="part" FSTYPE="" SIZE="21474836480" LABEL="rootfs"
PATH="/dev/mmcblk0p4" TYPE="part" FSTYPE="ext4" SIZE="10737418240" LABEL="opi_root"
EOF
""",
            encoding="utf-8",
        )
        lsblk_shim.chmod(0o755)

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/bsp.sh"
_rvdk_bsp_select_root_part "/dev/mmcblk0"
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "/dev/mmcblk0p4"

    def test_strip_fstab_commit_scoped_strictly_to_root_ext4(self) -> None:
        fstab_in = (
            "# UUID=comment / ext4 defaults,commit=600 0 1\n"
            "UUID=1111 / ext4 errors=remount-ro,commit=600,noatime 0 1\n"
            "UUID=2222 / ext4 commit=600 0 1\n"
            "UUID=3333 / ext4 commit=5,noatime 0 1\n"
            "UUID=4444 /mnt/data ext4 defaults,commit=600 0 2\n"
            "UUID=5555 / btrfs defaults,commit=600 0 1\n"
        )
        expected = (
            "# UUID=comment / ext4 defaults,commit=600 0 1\n"
            "UUID=1111 / ext4 errors=remount-ro,noatime 0 1\n"
            "UUID=2222 / ext4 defaults 0 1\n"
            "UUID=3333 / ext4 commit=5,noatime 0 1\n"
            "UUID=4444 /mnt/data ext4 defaults,commit=600 0 2\n"
            "UUID=5555 / btrfs defaults,commit=600 0 1\n"
        )
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/bsp.sh"
_rvdk_bsp_strip_fstab_commit <<'EOF'
{fstab_in.rstrip()}
EOF
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == expected


class TestPurgeUserHelpers:
    @pytest.mark.parametrize(
        "bad_path",
        [
            "",
            "/home/",
            "/home/.",
            "/home/..",
            "/home/./",
            "/home/../",
            "/",
            "/home",
            "/home/a/b",
            "/etc/passwd",
        ],
    )
    def test_validate_src_home_rejects_unsafe_paths(self, bad_path: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/purge-user.sh"
if rvdk_purge_validate_src_home "{bad_path}"; then
    exit 1
fi
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, f"Unexpectedly accepted {bad_path!r}"

    @pytest.mark.parametrize("good_path", ["/home/alice", "/home/alice/"])
    def test_validate_src_home_accepts_valid_home(self, good_path: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/purge-user.sh"
rvdk_purge_validate_src_home "{good_path}"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr

    def test_path_is_symlink_free_checks_components(self, tmp_path: Path) -> None:
        # 1. Real directory + real file -> passes
        real_home = tmp_path / "home_real"
        (real_home / ".rvdk").mkdir(parents=True)
        (real_home / ".rvdk" / "config.env").write_text("FOO=bar\n", encoding="utf-8")

        # 2. Symlinked config.env -> rejected
        sym_file_home = tmp_path / "home_sym_file"
        (sym_file_home / ".rvdk").mkdir(parents=True)
        target_file = tmp_path / "outside.env"
        target_file.write_text("FOO=evil\n", encoding="utf-8")
        (sym_file_home / ".rvdk" / "config.env").symlink_to(target_file)

        # 3. Symlinked .rvdk dir -> rejected
        sym_dir_home = tmp_path / "home_sym_dir"
        sym_dir_home.mkdir()
        outside_dir = tmp_path / "outside_dir"
        outside_dir.mkdir()
        (outside_dir / "config.env").write_text("FOO=evil\n", encoding="utf-8")
        (sym_dir_home / ".rvdk").symlink_to(outside_dir)

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/utils/purge-user.sh"
rvdk_purge_path_is_symlink_free "{real_home}" ".rvdk/config.env"
! rvdk_purge_path_is_symlink_free "{sym_file_home}" ".rvdk/config.env"
! rvdk_purge_path_is_symlink_free "{sym_dir_home}" ".rvdk/config.env"
! rvdk_purge_path_is_symlink_free "{real_home}" ".rvdk/../.rvdk/config.env"
! rvdk_purge_path_is_symlink_free "{real_home}" "./.rvdk/config.env"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr


def _write_exe(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


class TestRvdkValidateCidr:
    @pytest.mark.parametrize(
        "bad_cidr",
        [
            "10.0.08.0/24",
            "01.2.3.4/24",
            "192.168.1.0/08",
            "256.0.0.1/24",
            "10.0.0.0/33",
        ],
    )
    def test_rejects_malformed_or_octal_cidrs_without_set_e_crash(self, bad_cidr: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rc=0
rvdk_validate_cidr "{bad_cidr}" || rc=$?
printf 'RC=%d\\n' "$rc"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "RC=1"

    @pytest.mark.parametrize(
        "good_cidr",
        [
            "192.168.1.0/24",
            "0.0.0.0/0",
            "10.0.0.1/32",
        ],
    )
    def test_accepts_valid_cidrs(self, good_cidr: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_validate_cidr "{good_cidr}"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr


class TestRvdkSyncColdClock:
    def _make_common_with_root_gate_enabled(self, tmp_path: Path) -> Path:
        src = (REPO_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        needle = '[[ "$(uname -s)" == "Linux" && "${EUID:-$(id -u)}" -eq 0 ]] || return 0'
        assert needle in src
        patched = tmp_path / "common_clock.sh"
        patched.write_text(
            src.replace(needle, '[[ "$(uname -s)" == "Linux" ]] || return 0', 1),
            encoding="utf-8",
        )
        return patched

    def _setup_clock_shims(
        self,
        tmp_path: Path,
        host_dates: dict[str, str],
        local_epoch: str = "1700000000",
    ) -> tuple[dict[str, str], Path, Path]:
        bin_dir = tmp_path / "bin"
        date_set_log = tmp_path / "date_set.log"
        hwclock_log = tmp_path / "hwclock.log"

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
            bin_dir / "date",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-u" && "${{2:-}}" == "+%s" ]]; then
    printf '%s\\n' "{local_epoch}"
    exit 0
fi
if [[ "${{1:-}}" == "-u" && "${{2:-}}" == "-s" ]]; then
    printf '%s\\n' "$*" >> "{date_set_log}"
    exit 0
fi
if [[ "${{1:-}}" == "-u" && "${{2:-}}" == "+%Y-%m-%d %H:%M:%S UTC" ]]; then
    printf '2026-11-18 12:01:00 UTC\\n'
    exit 0
fi
if [[ "${{1:-}}" == "-u" && "${{2:-}}" == "-d" ]]; then
    exit 1
fi
exec /bin/date "$@"
""",
        )
        _write_exe(
            bin_dir / "hwclock",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{hwclock_log}"
exit 0
""",
        )
        _write_exe(bin_dir / "timedatectl", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "chronyc", "#!/usr/bin/env bash\nexit 1\n")

        cases = []
        for url_sub, date_hdr in host_dates.items():
            if date_hdr:
                cases.append(
                    f'    *"{url_sub}"*)\n'
                    f'        printf "HTTP/1.1 200 OK\\r\\nDate: {date_hdr}\\r\\n\\r\\n"\n'
                    f"        exit 0\n"
                    f"        ;;"
                )
            else:
                cases.append(f'    *"{url_sub}"*)\n        exit 1\n        ;;')
        case_block = "\n".join(cases)
        _write_exe(
            bin_dir / "curl",
            f"""#!/usr/bin/env bash
url="${{@: -1}}"
case "$url" in
{case_block}
    *)
        exit 1
        ;;
esac
""",
        )
        return {"PATH": f"{bin_dir}:{os.environ['PATH']}"}, date_set_log, hwclock_log

    def test_rejects_year_2099_http_date_with_warn_and_no_date_step(self, tmp_path: Path) -> None:
        common_sh = self._make_common_with_root_gate_enabled(tmp_path)
        env, date_set_log, hwclock_log = self._setup_clock_shims(
            tmp_path,
            {
                "rvdk.drewv-labs.dev": "Thu, 01 Jan 2099 00:00:00 GMT",
                "deb.debian.org": "Thu, 01 Jan 2099 00:00:10 GMT",
                "connectivitycheck.gstatic.com": "Thu, 01 Jan 2099 00:00:20 GMT",
            },
        )
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{common_sh}"
rvdk_sync_cold_clock
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert "[WARN]" in proc.stdout
        assert "outside [" in proc.stdout
        assert not date_set_log.exists()
        assert not hwclock_log.exists()

    def test_rejects_single_source_spoofed_http_date(self, tmp_path: Path) -> None:
        common_sh = self._make_common_with_root_gate_enabled(tmp_path)
        env, date_set_log, hwclock_log = self._setup_clock_shims(
            tmp_path,
            {
                "rvdk.drewv-labs.dev": "Wed, 18 Nov 2026 12:00:00 GMT",
                "deb.debian.org": "",
                "connectivitycheck.gstatic.com": "",
            },
        )
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{common_sh}"
rvdk_sync_cold_clock
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert "[WARN]" in proc.stdout
        assert "quorum of 2 agreeing hosts required" in proc.stdout
        assert not date_set_log.exists()
        assert not hwclock_log.exists()

    def test_rejects_two_disagreeing_hosts_over_300s(self, tmp_path: Path) -> None:
        common_sh = self._make_common_with_root_gate_enabled(tmp_path)
        env, date_set_log, hwclock_log = self._setup_clock_shims(
            tmp_path,
            {
                "rvdk.drewv-labs.dev": "Wed, 18 Nov 2026 12:00:00 GMT",
                "deb.debian.org": "Wed, 18 Nov 2026 12:10:00 GMT",
                "connectivitycheck.gstatic.com": "",
            },
        )
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{common_sh}"
rvdk_sync_cold_clock
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert "[WARN]" in proc.stdout
        assert "disagreed by >300s" in proc.stdout
        assert not date_set_log.exists()
        assert not hwclock_log.exists()

    def test_two_agreeing_hosts_within_300s_step_clock_and_hwclock(self, tmp_path: Path) -> None:
        common_sh = self._make_common_with_root_gate_enabled(tmp_path)
        env, date_set_log, hwclock_log = self._setup_clock_shims(
            tmp_path,
            {
                "rvdk.drewv-labs.dev": "Wed, 18 Nov 2026 12:00:00 GMT",
                "deb.debian.org": "Wed, 18 Nov 2026 12:02:00 GMT",
                "connectivitycheck.gstatic.com": "",
            },
        )
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{common_sh}"
rvdk_sync_cold_clock
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert "[OK]" in proc.stdout
        assert "2-host HTTP Date quorum" in proc.stdout
        assert date_set_log.is_file()
        assert len(date_set_log.read_text(encoding="utf-8").splitlines()) == 1
        assert hwclock_log.read_text(encoding="utf-8").splitlines() == ["--systohc --utc"]


class TestRvdkAssertSafeManagedDir:
    @pytest.mark.parametrize(
        "bad_path",
        [
            "",
            "relative/path",
            "/",
            "/usr/",
            "/usr//local",
            "/etc/.",
            "/usr/local/share/rvdk/../../etc",
            "/foo",
        ],
    )
    def test_rejects_unsafe_paths(self, bad_path: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_assert_safe_managed_dir "{bad_path}" "TEST_DIR"
"""
        proc = _run_bash(script)
        assert proc.returncode != 0, f"Unexpectedly accepted {bad_path!r}"
        assert "Unsafe TEST_DIR:" in proc.stderr

    def test_rejects_symlink_and_real_home(self, tmp_path: Path) -> None:
        real_target = tmp_path / "real_target"
        real_target.mkdir()
        sym_dir = tmp_path / "sym_engine"
        sym_dir.symlink_to(real_target)

        sym_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_assert_safe_managed_dir "{sym_dir}" "RVDK_ENGINE_DIR"
"""
        )
        assert sym_proc.returncode != 0
        assert "symbolic link" in sym_proc.stderr

        user_home = tmp_path / "home" / "alice"
        user_home.mkdir(parents=True)
        home_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
REAL_HOME="{user_home}"
rvdk_assert_safe_managed_dir "{user_home}" "RVDK_ENGINE_DIR"
"""
        )
        assert home_proc.returncode != 0
        assert "resolves to user home" in home_proc.stderr

    @pytest.mark.parametrize("good_path", ["/var/cache/rvdk", "/usr/local/share/rvdk/engine"])
    def test_accepts_safe_paths_with_zero_stdout(self, good_path: str) -> None:
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_assert_safe_managed_dir "{good_path}" "RVDK_ENGINE_DIR"
"""
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == ""


class TestLibKit:
    def test_kit_resolve_board_override_clears_dt_inferred_soc_and_factory_user(self) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
export RVDK_DT_MODEL="StarFive VisionFive 2 v1.3B"
rvdk_kit_resolve --no-cache --board p550 --os debian
printf 'BOARD=%s\\nSOC=%s\\nUSER=%s\\nOS=%s\\n' \\
    "$RVDK_BOARD" "$RVDK_SOC" "$RVDK_FACTORY_USER" "$RVDK_OS_ID"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == [
            "BOARD=sifive/p550",
            "SOC=eswin/eic7700x",
            "USER=",
            "OS=debian",
        ]

    @pytest.mark.parametrize("bad_id", ["foo/..", "../bar", "foo/."])
    def test_rejects_traversal_in_board_soc_and_resolve_board_dir(self, bad_id: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
export RVDK_DT_MODEL="Unknown"
rvdk_kit_resolve --no-cache --board "{bad_id}" --soc "{bad_id}" --os debian
printf 'BOARD=%s|SOC=%s\\n' "$RVDK_BOARD" "$RVDK_SOC"
if rvdk_resolve_board_dir "{REPO_ROOT}" "{bad_id}"; then
    exit 1
fi
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "BOARD=|SOC="


class TestLibAptAndProgbar:
    def test_apt_rewrite_stream_preserves_and_rewrites_to_apt_armbian_com(self, tmp_path: Path) -> None:
        src_list = tmp_path / "armbian.list"
        src_list.write_text(
            "deb https://apt.armbian.com bookworm main bookworm-utils\n"
            "deb http://mirrors.tuna.tsinghua.edu.cn/armbian bookworm main\n"
            "deb https://repo.huaweicloud.com/armbian noble main\n"
            "deb http://apt.armbian.com bookworm main\n",
            encoding="utf-8",
        )
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/apt.sh"
_rvdk_apt_rewrite_stream "{src_list}" "https"
"""
        )
        assert proc.returncode == 0, proc.stderr
        assert "armbian.chi.auroradev.org" not in proc.stdout
        assert proc.stdout.splitlines() == [
            "deb https://apt.armbian.com bookworm main bookworm-utils",
            "deb https://apt.armbian.com bookworm main",
            "deb https://apt.armbian.com noble main",
            "deb https://apt.armbian.com bookworm main",
        ]

    def test_prog_validate_sub_state_confinement(self, tmp_path: Path) -> None:
        # Reject /tmp/rvdk-foo and /run/rvdk/.. directly against real lib/progbar.sh
        reject_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/progbar.sh"
! _rvdk_prog_validate_sub_state "/tmp/rvdk-foo"
! _rvdk_prog_validate_sub_state "/run/rvdk/.."
"""
        )
        assert reject_proc.returncode == 0, reject_proc.stderr

        # Test accepting /run/rvdk/valid.state via a localized /run/rvdk directory check + mocked root/0755 stat
        progbar_src = (REPO_ROOT / "lib" / "progbar.sh").read_text(encoding="utf-8")
        needle = '[[ -d "$pdir" && ! -L "$pdir" ]] || return 1'
        assert needle in progbar_src
        fake_run_rvdk = tmp_path / "run" / "rvdk"
        fake_run_rvdk.mkdir(parents=True)
        patched_progbar = tmp_path / "progbar_test.sh"
        patched_progbar.write_text(
            progbar_src.replace(
                needle,
                f'[[ "$pdir" == "/run/rvdk" ]] && pdir="{fake_run_rvdk}"\n    [[ -d "$pdir" && ! -L "$pdir" ]] || return 1',
                1,
            ),
            encoding="utf-8",
        )

        bin_dir = tmp_path / "bin"
        _write_exe(
            bin_dir / "stat",
            """#!/usr/bin/env bash
case "${1:-}" in
    -c)
        case "${2:-}" in
            %u) printf '0\\n' ;;
            %a) printf '0755\\n' ;;
        esac
        ;;
    -f)
        case "${2:-}" in
            %u) printf '0\\n' ;;
            %Lp) printf '755\\n' ;;
        esac
        ;;
esac
""",
        )
        accept_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_progbar}"
_rvdk_prog_validate_sub_state "/run/rvdk/valid.state"
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert accept_proc.returncode == 0, accept_proc.stderr
