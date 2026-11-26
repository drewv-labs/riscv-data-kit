"""Bash subprocess tests for RVDK shell libraries and storage/purge helpers."""

from __future__ import annotations

import json
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
source "{REPO_ROOT}/lib/storage_guard.sh"
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
source "{REPO_ROOT}/lib/storage_guard.sh"
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

    def test_rvdk_converge_fstab_entry_preserves_octal_040_escaped_mountpoints(self, tmp_path: Path) -> None:
        bin_dir, spy_log = self._make_systemctl_spy(tmp_path)
        fstab = tmp_path / "fstab"
        fstab.write_text(
            "# Header comment\n"
            "UUID=root-1234  /  ext4  defaults  0  1\n"
            r"LABEL=OLD_SPACE  /mnt/my\040data  ext4  defaults  0  2" + "\n"
            r"LABEL=OTHER_SPACE  /mnt/other\040vol  xfs  defaults  0  2" + "\n",
            encoding="utf-8",
        )

        new_entry = r"LABEL=RVDK_SPACE  /mnt/my\040data  xfs  rw,noatime,nodiratime,nofail  0  2"
        pass_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
rvdk_converge_fstab_entry 'LABEL=RVDK_SPACE' '/mnt/my\\040data' 'xfs' '{new_entry}' "{fstab}"
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        run1 = _run_bash(pass_script, env=env)
        assert run1.returncode == 0, run1.stderr
        assert "[OK]" in run1.stdout
        assert not spy_log.exists()

        expected = (
            "# Header comment\n"
            "UUID=root-1234  /  ext4  defaults  0  1\n"
            f"{new_entry}\n"
            r"LABEL=OTHER_SPACE  /mnt/other\040vol  xfs  defaults  0  2" + "\n"
        )
        assert fstab.read_text(encoding="utf-8") == expected

        run2 = _run_bash(pass_script, env=env)
        assert run2.returncode == 0, run2.stderr
        assert "[SKIP]" in run2.stdout
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
source "{REPO_ROOT}/lib/common.sh"
_rvdk_strip_fstab_commit <<'EOF'
{fstab_in.rstrip()}
EOF
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == expected

    def test_common_rewrite_label_token_and_literal_and_normalize_mount_path(
        self, tmp_path: Path
    ) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
_rvdk_rewrite_literal "1111-2222" 'aaaa&\\1$b' <<'EOF'
UUID=1111-2222 / ext4 defaults 0 1
# comment 1111-2222
EOF
printf '===LBL===\\n'
_rvdk_rewrite_label_token "armbi_root" "rvdk_emmc_root" <<'EOF'
root=LABEL=armbi_root,ro LABEL=armbi_root2
EOF
printf '===NORM1=<%s>===\\n' "$(rvdk_normalize_mount_path "/mnt/nvme_data///")"
printf '===NORM_RAW===\\n'
rvdk_normalize_mount_path "/mnt/nvme_data///"
rvdk_normalize_mount_path "/"
rvdk_normalize_mount_path ""
printf '===RESOLVE===\\n'
rvdk_resolve_data_mount "/mnt/nvme_data///"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == (
            "UUID=aaaa&\\1$b / ext4 defaults 0 1\n"
            "# comment aaaa&\\1$b\n"
            "===LBL===\n"
            "root=LABEL=rvdk_emmc_root,ro LABEL=armbi_root2\n"
            "===NORM1=</mnt/nvme_data>===\n"
            "===NORM_RAW===\n"
            "/mnt/nvme_data\n"
            "/\n"
            "\n"
            "===RESOLVE===\n"
            "/mnt/nvme_data\n"
        )

        # Verify standalone purge-user.sh fallback stub matches trailing-newline semantics
        purge_stub = tmp_path / "purge_standalone.sh"
        purge_stub.write_text((REPO_ROOT / "utils" / "purge-user.sh").read_text(encoding="utf-8"), encoding="utf-8")
        stub_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{purge_stub}"
rvdk_normalize_mount_path "/mnt/data///"
rvdk_normalize_mount_path "/"
"""
        )
        assert stub_proc.returncode == 0, stub_proc.stderr
        assert stub_proc.stdout == "/mnt/data\n/\n"


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

    @pytest.mark.parametrize(
        "alias",
        [
            "espressif-esp32p4",
            "espressif/esp32p4",
            "waveshare-esp32-p4-wifi6",
            "waveshare/esp32-p4-wifi6",
            "waveshare-esp32-p4",
            "waveshare/esp32-p4",
            "waveshare-p4",
            "waveshare/p4",
            "esp32-p4-wifi6",
            "esp32-p4-wifi6-dev-kit",
            "esp32-p4",
            "esp32p4",
            "p4",
        ],
    )
    def test_kit_resolve_all_13_esp32p4_aliases(self, alias: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
rvdk_kit_resolve --no-cache --board "{alias}" --os esp-idf
printf 'BOARD=%s|SOC=%s|SLUG=%s|TAG=%s|ARCH=%s|MMU=%s|OS=%s\\n' \\
    "$RVDK_BOARD" "$RVDK_SOC" "$RVDK_SOC_SLUG" "$RVDK_BOARD_TAG" "$RVDK_ARCH" "$RVDK_MMU" "$RVDK_OS_ID"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert (
            proc.stdout.strip()
            == "BOARD=waveshare/esp32-p4-wifi6|SOC=espressif/esp32p4|SLUG=espressif-esp32p4|TAG=p4|ARCH=riscv32|MMU=none|OS=esp-idf"
        )

    @pytest.mark.parametrize(
        "dt_model",
        [
            "Waveshare ESP32-P4-WIFI6-DEV-KIT",
            "Waveshare ESP32-P4 Evaluation",
            "Custom ESP32-P4 Sensor",
            "Espressif ESP32P4 SoC",
        ],
    )
    def test_kit_resolve_esp32p4_dt_tokens(self, dt_model: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
export RVDK_DT_MODEL="{dt_model}"
rvdk_kit_resolve --no-cache --os nuttx
printf 'BOARD=%s|SOC=%s|TAG=%s|ARCH=%s|MMU=%s|OS=%s\\n' \\
    "$RVDK_BOARD" "$RVDK_SOC" "$RVDK_BOARD_TAG" "$RVDK_ARCH" "$RVDK_MMU" "$RVDK_OS_ID"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert (
            proc.stdout.strip()
            == "BOARD=waveshare/esp32-p4-wifi6|SOC=espressif/esp32p4|TAG=p4|ARCH=riscv32|MMU=none|OS=nuttx"
        )

    @pytest.mark.parametrize("bare_dt", ["Waveshare Generic Demo", "Orange Pi P4"])
    def test_kit_resolve_rejects_bare_waveshare_or_p4_dt_tokens(self, bare_dt: str) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
export RVDK_DT_MODEL="{bare_dt}"
rvdk_kit_resolve --no-cache --os debian
printf 'BOARD=%s|SOC=%s\\n' "$RVDK_BOARD" "$RVDK_SOC"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "BOARD=|SOC="

    @pytest.mark.parametrize("os_name", ["esp-idf", "nuttx", "buildroot", "linux-nommu"])
    def test_kit_resolve_uname_riscv32_and_nommu_os_ids(self, tmp_path: Path, os_name: str) -> None:
        bin_dir = tmp_path / "bin"
        real_uname = shutil.which("uname") or "/usr/bin/uname"
        _write_exe(
            bin_dir / "uname",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-m" ]]; then
    printf 'riscv32\\n'
    exit 0
fi
if [[ "${{1:-}}" == "-s" ]]; then
    printf 'Linux\\n'
    exit 0
fi
exec "{real_uname}" "$@"
""",
        )
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
export RVDK_DT_MODEL="Unknown"
rvdk_kit_resolve --no-cache --os "{os_name}"
printf 'ARCH=%s|MMU=%s|OS=%s\\n' "$RVDK_ARCH" "$RVDK_MMU" "$RVDK_OS_ID"
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == f"ARCH=riscv32|MMU=none|OS={os_name}"

    def test_kit_compiler_profile_and_probe_cflags_esp32p4_and_generics(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        fake_cc = _write_exe(
            bin_dir / "fake-gcc",
            """#!/usr/bin/env bash
if [[ "$*" == *"-march=rv32imafc_zicsr_zifencei_xespv2p1"* ]]; then
    exit 1
fi
if [[ "$*" == *"-march=rv32imafc_zicsr_zifencei"* && "$*" == *"-mabi=ilp32f"* ]]; then
    exit 0
fi
if [[ "$*" == *"-march=rv32imafc_zicsr_zifencei"* && "$*" != *"-mabi="* ]]; then
    exit 0
fi
exit 1
""",
        )
        fake_go = _write_exe(bin_dir / "fake-go", "#!/usr/bin/env bash\nexit 0\n")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
rvdk_kit_compiler_profile "espressif/esp32p4" "riscv32"
rvdk_kit_probe_cflags "{fake_cc}"
rvdk_kit_probe_goriscv64 "{fake_go}"
printf 'P4=%s|%s|%s|%s|%s|%s|%s\\n' \\
    "$RVDK_TARGET_SLUG" "$RVDK_CPU_MTUNE" "$RVDK_MABI" "$RVDK_GORISCV64_CANDIDATES" \\
    "$RVDK_SELECTED_MARCH" "$RVDK_OPT_CFLAGS" "$RVDK_SELECTED_GORISCV64"

rvdk_kit_compiler_profile "" "riscv32"
printf 'GEN32=%s|%s|%s|%s\\n' \\
    "$RVDK_TARGET_SLUG" "$RVDK_MARCH_CANDIDATES" "$RVDK_MABI" "$RVDK_GORISCV64_CANDIDATES"

rvdk_kit_compiler_profile "eswin/eic7700x" "riscv64"
printf 'RV64=%s|%s\\n' "$RVDK_TARGET_SLUG" "$RVDK_MABI"

rvdk_kit_compiler_profile "" "x86_64"
printf 'AMD64=%s|%s\\n' "$RVDK_TARGET_SLUG" "$RVDK_MABI"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == [
            "P4=espressif-esp32p4||ilp32f||rv32imafc_zicsr_zifencei|-O3 -pipe -march=rv32imafc_zicsr_zifencei -mabi=ilp32f|",
            "GEN32=riscv32-generic|rv32imafc_zicsr_zifencei rv32imac|ilp32f|",
            "RV64=sifive-p550|lp64d",
            "AMD64=linux-amd64|",
        ]

    def test_kit_env_cache_persists_and_loads_arch_mmu(self, tmp_path: Path) -> None:
        cache_file = tmp_path / "kit.env"
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/kit.sh"
export RVDK_KIT_CACHE_FILE="{cache_file}"
rvdk_kv_write "{cache_file}" 0644 "test" \\
    "RVDK_KIT_SCHEMA=1" \\
    "RVDK_DT_MODEL=Waveshare ESP32-P4-WIFI6-DEV-KIT" \\
    "RVDK_SOC=espressif/esp32p4" \\
    "RVDK_SOC_SLUG=espressif-esp32p4" \\
    "RVDK_BOARD=waveshare/esp32-p4-wifi6" \\
    "RVDK_BOARD_TAG=p4" \\
    "RVDK_ARCH=riscv32" \\
    "RVDK_MMU=none" \\
    "RVDK_FACTORY_USER=" \\
    "RVDK_OS_ID=esp-idf" \\
    "RVDK_OS_VERSION_ID=5.4" \\
    "RVDK_PRIMARY_NIC=wlan0" \\
    "RVDK_CPU_HARTS=2"
rvdk_kit_resolve
printf 'SRC=%s|ARCH=%s|MMU=%s|SOC=%s|BOARD=%s\\n' \\
    "$RVDK_KIT_SOURCE" "$RVDK_ARCH" "$RVDK_MMU" "$RVDK_SOC" "$RVDK_BOARD"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert (
            proc.stdout.strip()
            == "SRC=cache|ARCH=riscv32|MMU=none|SOC=espressif/esp32p4|BOARD=waveshare/esp32-p4-wifi6"
        )

    def test_kit_resolve_and_normalize_cover_all_17_media_manifests(self) -> None:
        manifest_paths = sorted((REPO_ROOT / "boards").glob("*/*/media.json"))
        assert len(manifest_paths) == 17

        checks: list[str] = []
        expected_lines: list[str] = []
        for m_path in manifest_paths:
            doc = json.loads(m_path.read_text(encoding="utf-8"))
            board = str(doc["board"])
            tag = str(doc["tag"])
            soc = str(doc["soc"])
            arch = str(doc.get("arch") or "riscv64")
            os_arg = "esp-idf" if arch == "riscv32" else "debian"
            checks.append(
                f'n_tag="$(rvdk_normalize_board_id "{tag}")"\n'
                f'n_brd="$(rvdk_normalize_board_id "{board}")"\n'
                f'rvdk_kit_resolve --no-cache --board "{tag}" --os "{os_arg}"\n'
                f'printf "%s|%s|%s|%s|%s|%s\\n" "$n_tag" "$n_brd" "$RVDK_BOARD" "$RVDK_BOARD_TAG" "$RVDK_SOC" "$RVDK_ARCH"'
            )
            expected_lines.append(f"{board}|{board}|{board}|{tag}|{soc}|{arch}")

        script = (
            "set -Eeuo pipefail\n"
            'export RVDK_KIT_CACHE_FILE="/nonexistent"\n'
            f'source "{REPO_ROOT}/lib/common.sh"\n'
            f'source "{REPO_ROOT}/lib/kit.sh"\n'
            + "\n".join(checks)
            + "\n"
        )
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == expected_lines


class TestLibBspAndMotdRiscv32:
    def test_protect_dpkg_and_mmc_labels_skip_cleanly_on_riscv32(self, tmp_path: Path) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/bsp.sh"
export RVDK_ARCH="riscv32"
export RVDK_MMU="none"
export RVDK_SOC="espressif/esp32p4"
rvdk_bsp_protect_dpkg "{tmp_path}/90-test" "ESP32-P4"
rvdk_bsp_converge_mmc_root_labels
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.count("[SKIP]") == 2

    def test_motd_renders_riscv32_without_riscv64_fallback_and_iot_badge(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        _write_exe(
            bin_dir / "uname",
            """#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Linux\\n' ;;
    -o) printf 'GNU/Linux\\n' ;;
    -r) printf '6.12-nommu\\n' ;;
    -m) exit 1 ;;
    *)  exit 1 ;;
esac
""",
        )
        kit_env = tmp_path / "kit.env"
        kit_env.write_text(
            'RVDK_KIT_SCHEMA="1"\n'
            'RVDK_DT_MODEL="Waveshare ESP32-P4-WIFI6-DEV-KIT"\n'
            'RVDK_SOC="espressif/esp32p4"\n'
            'RVDK_SOC_SLUG="espressif-esp32p4"\n'
            'RVDK_BOARD="waveshare/esp32-p4-wifi6"\n'
            'RVDK_BOARD_TAG="p4"\n'
            'RVDK_ARCH="riscv32"\n'
            'RVDK_MMU="none"\n'
            'RVDK_OS_ID="linux-nommu"\n'
            'RVDK_OS_VERSION_ID=""\n'
            'RVDK_PRIMARY_NIC="wlan0"\n'
            'RVDK_CPU_HARTS="2"\n',
            encoding="utf-8",
        )
        dt_env = tmp_path / "deeptune.env"
        dt_env.write_text('RVDK_TUNE="iot"\nRVDK_TUNE_MODE="iot"\n', encoding="utf-8")

        motd_sh = tmp_path / "motd_render.sh"
        gen = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/motd.sh"
{{
    printf '#!/bin/sh\\n'
    _rvdk_emit_motd_renderer_body
    printf '_rvdk_motd_render\\n'
}} > "{motd_sh}"
chmod +x "{motd_sh}"
"""
        )
        assert gen.returncode == 0, gen.stderr

        run = subprocess.run(
            ["/bin/sh", str(motd_sh)],
            capture_output=True,
            text=True,
            env={
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "RVDK_KIT_CACHE_FILE": str(kit_env),
                "RVDK_DEEPTUNE_ENV": str(dt_env),
                "RVDK_ENGINE_DIR": str(tmp_path / "no_engine"),
            },
            check=False,
        )
        assert run.returncode == 0, run.stderr
        assert "riscv32" in run.stdout
        assert "riscv64" not in run.stdout
        assert "Arch / MMU        : riscv32 (mmu: none)" in run.stdout
        assert "(active: iot)" in run.stdout


class TestBootstrapRiscv32AndTuneIot:
    def _make_staged_repo(self, tmp_path: Path) -> tuple[Path, Path]:
        repo = tmp_path / "rvdk"
        shutil.copytree(REPO_ROOT / "lib", repo / "lib")
        shutil.copy2(REPO_ROOT / "bootstrap.sh", repo / "bootstrap.sh")
        (repo / "bootstrap.sh").chmod(0o755)

        spy_log = tmp_path / "spy.log"
        for rel in (
            "os/bootstrap-apt.sh",
            "os/deeptune.sh",
            "bsp/espressif/esp32p4/forge.sh",
            "bsp/espressif/esp32p4/deeptune.sh",
            "boards/waveshare/esp32-p4-wifi6/deeptune.sh",
        ):
            _write_exe(
                repo / rel,
                f"""#!/usr/bin/env bash
printf '%s %s\\n' "{rel}" "$*" >> "{spy_log}"
exit 0
""",
            )
        return repo, spy_log

    @pytest.mark.parametrize(
        "args",
        [
            ["postgresql", "--board", "p4", "--os", "esp-idf"],
            ["mods/nvme-4kn", "--board", "p4", "--os", "esp-idf"],
            ["mods/btrfs-raid", "--board", "p4", "--os", "esp-idf"],
            ["mods/nfs-vault", "--board", "p4", "--os", "esp-idf"],
            ["mods/tailscale", "--board", "p4", "--os", "esp-idf"],
            ["mods/ntfy", "--board", "p4", "--os", "esp-idf"],
            ["day0", "--board", "p4", "--os", "esp-idf", "--with-tailscale", "--stage-dir", "/tmp/rvdk_unused"],
        ],
    )
    def test_riscv32_nommu_fails_fast_on_unsupported_modules(
        self, tmp_path: Path, args: list[str]
    ) -> None:
        repo, _ = self._make_staged_repo(tmp_path)
        proc = subprocess.run(
            [BASH_BIN, str(repo / "bootstrap.sh"), *args],
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env")},
            check=False,
        )
        assert proc.returncode != 0
        assert "riscv32 / nommu" in proc.stderr

    def test_day0_skips_bootstrap_apt_and_chains_esp32p4_stage_dir(self, tmp_path: Path) -> None:
        repo, spy_log = self._make_staged_repo(tmp_path)
        stage_dir = tmp_path / "stage"
        proc = subprocess.run(
            [
                BASH_BIN,
                str(repo / "bootstrap.sh"),
                "day0",
                "--board",
                "p4",
                "--os",
                "esp-idf",
                "--tune",
                "iot",
                "--stage-dir",
                str(stage_dir),
                "--noprogbar",
            ],
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env")},
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        assert "[SKIP]" in proc.stdout
        assert "Skipping os/bootstrap-apt.sh" in proc.stdout
        calls = spy_log.read_text(encoding="utf-8").splitlines()
        assert not any(c.startswith("os/bootstrap-apt.sh") for c in calls)
        assert not any(c.startswith("os/deeptune.sh") for c in calls)
        assert calls == [
            f"bsp/espressif/esp32p4/forge.sh --noprogbar --stage-dir {stage_dir}",
            f"bsp/espressif/esp32p4/deeptune.sh --tune iot --noprogbar --stage-dir {stage_dir}",
            f"boards/waveshare/esp32-p4-wifi6/deeptune.sh --tune iot --noprogbar --stage-dir {stage_dir}",
        ]
        assert (stage_dir / "config" / "deeptune.env").is_file()

    @pytest.mark.parametrize("alias", ["iot", "edge-iot", "sensor", "mcu"])
    def test_deeptune_normalizes_iot_aliases_with_stage_dir(
        self, tmp_path: Path, alias: str
    ) -> None:
        repo, spy_log = self._make_staged_repo(tmp_path)
        stage_dir = tmp_path / f"stage_{alias}"
        proc = subprocess.run(
            [
                BASH_BIN,
                str(repo / "bootstrap.sh"),
                "deeptune",
                "--board",
                "p4",
                "--os",
                "linux-nommu",
                "--tune",
                alias,
                "--stage-dir",
                str(stage_dir),
                "--noprogbar",
            ],
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env")},
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        calls = spy_log.read_text(encoding="utf-8").splitlines()
        assert calls == [
            f"bsp/espressif/esp32p4/deeptune.sh --tune iot --noprogbar --stage-dir {stage_dir}",
            f"boards/waveshare/esp32-p4-wifi6/deeptune.sh --tune iot --noprogbar --stage-dir {stage_dir}",
        ]

    def test_direct_bsp_and_board_script_dispatch_unprivileged(self, tmp_path: Path) -> None:
        stage_dir = tmp_path / "stage_direct"
        env = {
            "PATH": os.environ["PATH"],
            "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env"),
            "RVDK_DEEPTUNE_ENV": str(tmp_path / "none_dt.env"),
        }
        cmds = [
            ["bsp/espressif/esp32p4/forge.sh", "--stage-dir", str(stage_dir), "--noprogbar"],
            ["bsp/espressif/esp32p4/deeptune.sh", "--tune", "iot", "--stage-dir", str(stage_dir), "--noprogbar"],
            ["boards/waveshare/esp32-p4-wifi6/deeptune.sh", "--tune", "iot", "--stage-dir", str(stage_dir), "--noprogbar"],
            ["boards/waveshare/esp32-p4-wifi6/quirks/c6-sdio.sh", "enable", "--stage-dir", str(stage_dir), "--noprogbar"],
            ["bsp/espressif/esp32p4/deeptune.sh", "status", "--stage-dir", str(stage_dir)],
            ["boards/waveshare/esp32-p4-wifi6/flash-sd.sh", "--dry-run"],
            ["bsp/espressif/esp32p4/forge.sh", "--help"],
        ]
        for args in cmds:
            proc = subprocess.run(
                [BASH_BIN, str(REPO_ROOT / "bootstrap.sh"), *args],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            assert proc.returncode == 0, f"{args}: stdout={proc.stdout}\nstderr={proc.stderr}"
            if args[1] == "status":
                assert "sdkconfig.rvdk.iot.defaults" in proc.stdout

        assert (stage_dir / "config" / "rvdk-kit.env").is_file()
        assert 'RVDK_ARCH="riscv32"' in (stage_dir / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert (stage_dir / "config" / "sdkconfig.rvdk.iot.defaults").is_file()
        assert (stage_dir / "config" / "board-waveshare-p4.defaults").is_file()
        assert (stage_dir / "config" / "c6-sdio.env").is_file()

        # Pass 2 via direct forge.sh emits [SKIP] unprivileged
        p2 = subprocess.run(
            [BASH_BIN, str(REPO_ROOT / "bootstrap.sh"), "bsp/espressif/esp32p4/forge.sh", "--stage-dir", str(stage_dir), "--noprogbar"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert p2.returncode == 0, p2.stderr
        assert "[SKIP]" in p2.stdout

    @pytest.mark.parametrize(
        "bad_subcmd",
        [
            "/etc/passwd",
            "/bsp/espressif/esp32p4/forge.sh",
            "/boards/waveshare/esp32-p4-wifi6/deeptune.sh",
            "bsp/../../etc/passwd",
            "bsp/espressif/../esp32p4/forge.sh",
            "boards/waveshare/esp32-p4-wifi6/quirks/../../deeptune.sh",
            "bsp/./espressif/esp32p4/forge.sh",
            "bsp//espressif/esp32p4/forge.sh",
            "bsp/espressif/esp32p4/nonexistent.sh",
            "boards/waveshare/esp32-p4-wifi6/media.json",
            "install/../../etc/passwd",
        ],
    )
    def test_direct_script_dispatch_rejects_traversal_leading_slash_and_missing(
        self, tmp_path: Path, bad_subcmd: str
    ) -> None:
        proc = subprocess.run(
            [BASH_BIN, str(REPO_ROOT / "bootstrap.sh"), bad_subcmd, "--stage-dir", str(tmp_path)],
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env")},
            check=False,
        )
        assert proc.returncode != 0, f"Expected failure for {bad_subcmd}, got rc=0 stdout={proc.stdout}"

    def test_direct_script_dispatch_rejects_symlink_escape(self, tmp_path: Path) -> None:
        repo, _ = self._make_staged_repo(tmp_path)
        outside = tmp_path / "outside.sh"
        _write_exe(outside, "#!/usr/bin/env bash\necho ESCAPED\n")
        (repo / "bsp" / "espressif" / "esp32p4" / "escape.sh").symlink_to(outside)

        proc = subprocess.run(
            [BASH_BIN, str(repo / "bootstrap.sh"), "bsp/espressif/esp32p4/escape.sh", "--stage-dir", str(tmp_path / "s")],
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env")},
            check=False,
        )
        assert proc.returncode != 0
        assert "ESCAPED" not in proc.stdout

    def test_deeptune_p4_data_tune_pass1_pass2_idempotency_preserves_sdkconfig_fragment(
        self, tmp_path: Path
    ) -> None:
        stage_dir = tmp_path / "stage_data_p4"
        env = {
            "PATH": os.environ["PATH"],
            "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env"),
            "RVDK_DEEPTUNE_ENV": str(tmp_path / "none_dt.env"),
        }
        cmd = [
            BASH_BIN,
            str(REPO_ROOT / "bootstrap.sh"),
            "deeptune",
            "--board",
            "p4",
            "--os",
            "esp-idf",
            "--tune",
            "data",
            "--stage-dir",
            str(stage_dir),
            "--noprogbar",
        ]
        p1 = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
        assert p1.returncode == 0, f"stdout={p1.stdout}\nstderr={p1.stderr}"

        dt_env_path = stage_dir / "config" / "deeptune.env"
        iot_cfg_path = stage_dir / "config" / "sdkconfig.rvdk.iot.defaults"
        board_cfg_path = stage_dir / "config" / "board-waveshare-p4.defaults"
        assert dt_env_path.is_file()
        assert iot_cfg_path.is_file()
        assert board_cfg_path.is_file()

        dt_env_text = dt_env_path.read_text(encoding="utf-8")
        assert 'RVDK_TUNE="iot"' in dt_env_text
        assert 'RVDK_SDKCONFIG_FRAGMENT="sdkconfig.rvdk.iot.defaults"' in dt_env_text
        snap_before = {
            p.name: p.read_bytes() for p in sorted((stage_dir / "config").iterdir()) if p.is_file()
        }

        p2 = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
        assert p2.returncode == 0, f"stdout={p2.stdout}\nstderr={p2.stderr}"
        assert "[SKIP]" in p2.stdout
        assert "Flipping Kit DeepTune" not in p2.stdout
        snap_after = {
            p.name: p.read_bytes() for p in sorted((stage_dir / "config").iterdir()) if p.is_file()
        }
        assert snap_after == snap_before

    def test_bsp_deeptune_alias_still_runs_orchestrated_deeptune(self, tmp_path: Path) -> None:
        repo, spy_log = self._make_staged_repo(tmp_path)
        stage_dir = tmp_path / "stage_bsp_dt"
        proc = subprocess.run(
            [
                BASH_BIN,
                str(repo / "bootstrap.sh"),
                "bsp/deeptune",
                "--board",
                "p4",
                "--os",
                "esp-idf",
                "--tune",
                "iot",
                "--stage-dir",
                str(stage_dir),
                "--noprogbar",
            ],
            capture_output=True,
            text=True,
            env={"PATH": os.environ["PATH"], "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env")},
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        assert spy_log.read_text(encoding="utf-8").splitlines() == [
            f"bsp/espressif/esp32p4/deeptune.sh --tune iot --noprogbar --stage-dir {stage_dir}",
            f"boards/waveshare/esp32-p4-wifi6/deeptune.sh --tune iot --noprogbar --stage-dir {stage_dir}",
        ]


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


class TestRvdkJoinBy:
    def test_empty_single_multichar_and_format_char_safety(self) -> None:
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
printf 'ZERO=<%s>\\n' "$(rvdk_join_by " -> ")"
printf 'ONE=<%s>\\n' "$(rvdk_join_by " -> " "alpha")"
printf 'THREE=<%s>\\n' "$(rvdk_join_by " -> " "os/deeptune.sh" "bsp/k1/deeptune.sh" "boards/rv2/deeptune.sh")"
printf 'FMT=<%s>\\n' "$(rvdk_join_by "%s%n" "%s_one" "%x_two" "plain\\\\three")"
printf 'NOARGS=<%s>\\n' "$(rvdk_join_by)"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == [
            "ZERO=<>",
            "ONE=<alpha>",
            "THREE=<os/deeptune.sh -> bsp/k1/deeptune.sh -> boards/rv2/deeptune.sh>",
            r"FMT=<%s_one%s%n%x_two%s%nplain\three>",
            "NOARGS=<>",
        ]


class TestRvdkSudoPreserve:
    def _make_sudo_mock(
        self,
        tmp_path: Path,
        *,
        deny_setenv: bool = False,
        simulate_env_reset: bool = True,
    ) -> tuple[Path, Path, Path]:
        bin_dir = tmp_path / "bin"
        sudo_log = tmp_path / "sudo_invocations.log"
        target_log = tmp_path / "target_runs.log"

        _write_exe(
            bin_dir / "sudo",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{sudo_log}"
non_interactive=0
validate_only=0
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
if [[ "{1 if simulate_env_reset else 0}" == "1" ]]; then
    clean_env=("PATH=/usr/bin:/bin")
    if [[ -n "$preserve_csv" ]]; then
        IFS=',' read -r -a keep_vars <<< "$preserve_csv"
        for k in "${{keep_vars[@]}}"; do
            if [[ -n "${{!k+x}}" ]]; then
                clean_env+=("${{k}}=${{!k}}")
            fi
        done
    fi
    exec env -i "${{clean_env[@]}}" "$@"
fi
exec "$@"
""",
        )
        return bin_dir, sudo_log, target_log

    def test_excludes_dangerous_vars_and_preserves_allowlisted_rvdk_vars(self, tmp_path: Path) -> None:
        bin_dir, sudo_log, _ = self._make_sudo_mock(tmp_path, deny_setenv=False)
        probe_script = tmp_path / "probe.sh"
        _write_exe(
            probe_script,
            """#!/usr/bin/env bash
printf 'XDG=%s|LD=%s|BASH_ENV=%s|PROGBAR_LIB=%s|BOARD=%s|TUNE=%s|CACHE=%s\\n' \\
    "${XDG_CACHE_HOME:-UNSET}" "${LD_PRELOAD:-UNSET}" "${BASH_ENV:-UNSET}" \\
    "${RVDK_PROGBAR_LIB:-UNSET}" "${RVDK_BOARD:-UNSET}" "${RVDK_TUNE:-UNSET}" "${RVDK_CACHE_DIR:-UNSET}"
""",
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "XDG_CACHE_HOME": "/tmp/evil_xdg",
            "LD_PRELOAD": "/tmp/evil.so",
            "LD_LIBRARY_PATH": "/tmp/evil_lib",
            "BASH_ENV": "/tmp/evil_bashenv.sh",
            "RVDK_PROGBAR_LIB": "/tmp/evil_progbar.sh",
            "RVDK_APT_LIB": "/tmp/evil_apt.sh",
            "RVDK_BOARD": "waveshare/esp32-p4-wifi6",
            "RVDK_TUNE": "iot",
            "RVDK_CACHE_DIR": "/var/cache/rvdk",
        }
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_sudo_preserve "{BASH_BIN}" "{probe_script}"
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == (
            "XDG=UNSET|LD=UNSET|BASH_ENV=UNSET|PROGBAR_LIB=UNSET|"
            "BOARD=waveshare/esp32-p4-wifi6|TUNE=iot|CACHE=/var/cache/rvdk"
        )
        sudo_calls = sudo_log.read_text(encoding="utf-8").splitlines()
        assert len(sudo_calls) == 2
        assert "--preserve-env=" in sudo_calls[0]
        assert "--preserve-env=" in sudo_calls[1]
        for forbidden in ("XDG_CACHE_HOME", "LD_PRELOAD", "LD_LIBRARY_PATH", "BASH_ENV", "PATH", "RVDK_PROGBAR_LIB", "RVDK_APT_LIB"):
            assert forbidden not in sudo_calls[1]
        assert "RVDK_BOARD" in sudo_calls[1]
        assert "RVDK_TUNE" in sudo_calls[1]
        assert "RVDK_CACHE_DIR" in sudo_calls[1]

    def test_no_double_execution_on_real_command_failure_when_setenv_allowed(self, tmp_path: Path) -> None:
        bin_dir, _, target_log = self._make_sudo_mock(tmp_path, deny_setenv=False)
        failing_script = tmp_path / "fail_once.sh"
        _write_exe(
            failing_script,
            f"""#!/usr/bin/env bash
printf 'RAN\\n' >> "{target_log}"
exit 42
""",
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_TUNE": "iot",
        }
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rc=0
rvdk_sudo_preserve "{BASH_BIN}" "{failing_script}" || rc=$?
printf 'RC=%d\\n' "$rc"
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "RC=42"
        assert target_log.read_text(encoding="utf-8").splitlines() == ["RAN"]

    def test_setenv_fallback_runs_plain_sudo_once_even_on_command_failure(self, tmp_path: Path) -> None:
        bin_dir, sudo_log, target_log = self._make_sudo_mock(tmp_path, deny_setenv=True)
        failing_script = tmp_path / "fail_after_fallback.sh"
        _write_exe(
            failing_script,
            f"""#!/usr/bin/env bash
printf 'RAN\\n' >> "{target_log}"
exit 17
""",
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_TUNE": "iot",
            "XDG_CACHE_HOME": "/tmp/evil_xdg",
        }
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rc=0
rvdk_sudo_preserve "{BASH_BIN}" "{failing_script}" || rc=$?
printf 'RC=%d\\n' "$rc"
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "RC=17"
        assert target_log.read_text(encoding="utf-8").splitlines() == ["RAN"]
        calls = sudo_log.read_text(encoding="utf-8").splitlines()
        assert "--preserve-env=" in calls[0]
        assert calls[-1] == f"{BASH_BIN} {failing_script}"

    def test_adopted_in_require_root_bootstrap_and_install_cli(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        sudo_log = tmp_path / "escalate.log"
        _write_exe(
            bin_dir / "sudo",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{sudo_log}"
exit 0
""",
        )
        if os.geteuid() == 0:
            pytest.skip("Unprivileged escalation path requires non-root UID")

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "XDG_CACHE_HOME": "/tmp/evil_xdg",
            "LD_PRELOAD": "/tmp/evil.so",
            "RVDK_TUNE": "iot",
            "RVDK_BOARD": "sifive/p550",
        }

        dummy_target = tmp_path / "dummy.sh"
        _write_exe(dummy_target, "#!/usr/bin/env bash\nexit 0\n")

        # 1. lib/common.sh rvdk_require_root
        p_req = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_require_root "{dummy_target}" --flag
""",
            env=env,
        )
        assert p_req.returncode == 0, p_req.stderr

        # 2. bootstrap.sh _escalate_root_if_needed (via `day0` unprivileged invocation)
        p_boot = subprocess.run(
            [BASH_BIN, str(REPO_ROOT / "bootstrap.sh"), "day0", "--board", "p550", "--os", "debian"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert p_boot.returncode == 0, p_boot.stderr

        # 3. install-cli.sh privilege escalation
        p_inst = subprocess.run(
            [BASH_BIN, str(REPO_ROOT / "install-cli.sh"), "--quiet"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert p_inst.returncode == 0, p_inst.stderr

        log_lines = sudo_log.read_text(encoding="utf-8").splitlines()
        assert len(log_lines) == 6  # 3 probes + 3 escalated invocations
        for line in log_lines:
            assert " -E " not in f" {line} "
            assert "XDG_CACHE_HOME" not in line
            assert "LD_PRELOAD" not in line
            assert "--preserve-env=" in line
            assert "RVDK_TUNE" in line
            assert "RVDK_BOARD" in line


class TestRvdkBackupFile:
    def test_first_touch_orig_and_path_sidecar_idempotency_and_symlink_rejection(self, tmp_path: Path) -> None:
        backup_root = tmp_path / "backups"
        target_dir = tmp_path / "etc__like" / "sub__dir"
        target_dir.mkdir(parents=True)
        src_file = target_dir / "test__mod.conf"
        src_file.write_text("original-content\n", encoding="utf-8")
        src_file.chmod(0o640)

        sym_file = target_dir / "sym.conf"
        sym_file.symlink_to(src_file)

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
export RVDK_BACKUP_ROOT="{backup_root}"
rvdk_backup_file "{src_file}"
printf 'MUTATED\n' > "{src_file}"
rvdk_backup_file "{src_file}"
! rvdk_backup_file "{sym_file}"
! rvdk_backup_file "relative/path.conf"
! rvdk_backup_file "{src_file}" "../evil"
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr

        encoded = str(src_file).lstrip("/").replace("/", "__")
        orig_path = backup_root / "deeptune" / f"{encoded}.orig"
        sidecar_path = backup_root / "deeptune" / f"{encoded}.path"

        assert orig_path.is_file() and not orig_path.is_symlink()
        assert orig_path.read_text(encoding="utf-8") == "original-content\n"
        assert sidecar_path.is_file() and not sidecar_path.is_symlink()
        assert (sidecar_path.stat().st_mode & 0o777) == 0o644
        assert sidecar_path.read_text(encoding="utf-8") == f"{src_file}\n"


class TestMotdSecurityAndRendering:
    def _render_motd_script(self, tmp_path: Path) -> Path:
        motd_sh = tmp_path / "motd_render.sh"
        gen = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/motd.sh"
{{
    printf '#!/bin/sh\\n'
    _rvdk_emit_motd_renderer_body
    printf '_rvdk_motd_render\\n'
}} > "{motd_sh}"
chmod +x "{motd_sh}"
"""
        )
        assert gen.returncode == 0, gen.stderr
        return motd_sh

    @pytest.mark.parametrize("bad_board", ["../../tmp", "../etc", "foo/..", "./foo", "foo/.", "a/b/c", "foo/bar;id"])
    def test_rejects_traversal_in_kit_board_before_motd_quirks_exec(
        self, tmp_path: Path, bad_board: str
    ) -> None:
        motd_sh = self._render_motd_script(tmp_path)
        eng_dir = tmp_path / "engine"
        pwn_flag = tmp_path / "pwned_motd"

        # Place canary scripts at every target the traversal could reach
        for canary_dir in (
            tmp_path / "tmp",
            tmp_path / "etc",
            eng_dir / "boards",
            eng_dir / "boards" / "foo",
            eng_dir / "boards" / "a" / "b" / "c",
            eng_dir / "boards" / "foo" / "bar;id",
            eng_dir / "boards" / ".." / ".." / "tmp",
            eng_dir / "boards" / ".." / "etc",
            eng_dir / "boards" / "foo" / "..",
        ):
            canary_dir.mkdir(parents=True, exist_ok=True)
            _write_exe(
                canary_dir / "motd-quirks.sh",
                f"#!/bin/sh\ntouch '{pwn_flag}'\necho PWNED\n",
            )
        # Also place directly under tmp_path / "motd-quirks.sh" for engine/boards/../../.. escapes
        _write_exe(tmp_path / "motd-quirks.sh", f"#!/bin/sh\ntouch '{pwn_flag}'\necho PWNED\n")

        kit_env = tmp_path / "kit.env"
        kit_env.write_text(
            'RVDK_KIT_SCHEMA="1"\n'
            'RVDK_DT_MODEL="Test Board"\n'
            'RVDK_SOC="spacemit/k1"\n'
            f'RVDK_BOARD="{bad_board}"\n'
            'RVDK_ARCH="riscv64"\n'
            'RVDK_MMU="sv39"\n'
            'RVDK_OS_ID="debian"\n',
            encoding="utf-8",
        )

        run = subprocess.run(
            ["/bin/sh", str(motd_sh)],
            capture_output=True,
            text=True,
            env={
                "PATH": os.environ["PATH"],
                "RVDK_KIT_CACHE_FILE": str(kit_env),
                "RVDK_DEEPTUNE_ENV": str(tmp_path / "no_dt.env"),
                "RVDK_ENGINE_DIR": str(eng_dir),
            },
            check=False,
        )
        assert run.returncode == 0, run.stderr
        assert not pwn_flag.exists()
        assert "PWNED" not in run.stdout
        assert "Board Quirks      : none" in run.stdout

    def test_environ_awk_rendering_preserves_backslashes_and_escapes(self, tmp_path: Path) -> None:
        motd_sh = self._render_motd_script(tmp_path)
        eng_dir = tmp_path / "engine"
        quirk_script = eng_dir / "boards" / "acme" / "board_1.2" / "motd-quirks.sh"
        _write_exe(
            quirk_script,
            r"""#!/bin/sh
printf '%s\n' 'hdmi:off\nfusb:on\tirq\\040\x41'
""",
        )
        kit_path = tmp_path / "kit\\npath\\test.env"
        kit_path.write_text(
            'RVDK_KIT_SCHEMA="1"\n'
            'RVDK_DT_MODEL="Acme Backslash\\\\Model"\n'
            'RVDK_SOC="spacemit/k1"\n'
            'RVDK_SOC_SLUG="spacemit-k1"\n'
            'RVDK_BOARD="acme/board_1.2"\n'
            'RVDK_BOARD_TAG="b12"\n'
            'RVDK_ARCH="riscv64"\n'
            'RVDK_MMU="sv39"\n'
            'RVDK_OS_ID="debian"\n'
            'RVDK_OS_VERSION_ID="12"\n'
            'RVDK_PRIMARY_NIC="end0"\n'
            'RVDK_CPU_HARTS="8"\n'
            r'RVDK_DEEPTUNE_CHAIN="os\ndeeptune.sh -> bsp\tlayer\\1"' + "\n",
            encoding="utf-8",
        )

        run = subprocess.run(
            ["/bin/sh", str(motd_sh)],
            capture_output=True,
            text=True,
            env={
                "PATH": os.environ["PATH"],
                "RVDK_KIT_CACHE_FILE": str(kit_path),
                "RVDK_DEEPTUNE_ENV": str(tmp_path / "no_dt.env"),
                "RVDK_ENGINE_DIR": str(eng_dir),
            },
            check=False,
        )
        assert run.returncode == 0, run.stderr
        assert f"  • Kit Cache File    : {kit_path} (cached)" in run.stdout
        assert r"  • Device Tree Model : Acme Backslash\Model" in run.stdout
        assert r"  • DeepTune Chain    : os\ndeeptune.sh -> bsp\tlayer\\1" in run.stdout
        assert r"  • Board Quirks      : hdmi:off\nfusb:on\tirq\\040\x41" in run.stdout


class TestBootstrapCapabilitiesAndEsp32P4Board:
    def test_deeptune_status_joins_layers_with_multichar_arrow(self, tmp_path: Path) -> None:
        repo = tmp_path / "rvdk"
        shutil.copytree(REPO_ROOT / "lib", repo / "lib")
        shutil.copy2(REPO_ROOT / "bootstrap.sh", repo / "bootstrap.sh")
        (repo / "bootstrap.sh").chmod(0o755)
        for rel in (
            "os/deeptune.sh",
            "bsp/spacemit/k1/deeptune.sh",
            "boards/orangepi/rv2/deeptune.sh",
        ):
            _write_exe(repo / rel, "#!/usr/bin/env bash\necho \"status:$*\"\n")

        dt_env = tmp_path / "deeptune.env"
        dt_env.write_text('RVDK_TUNE="data"\n', encoding="utf-8")
        proc = subprocess.run(
            [
                BASH_BIN,
                str(repo / "bootstrap.sh"),
                "deeptune",
                "status",
                "--board",
                "rv2",
                "--os",
                "debian",
            ],
            capture_output=True,
            text=True,
            env={
                "PATH": os.environ["PATH"],
                "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env"),
                "RVDK_DEEPTUNE_ENV": str(dt_env),
            },
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        assert (
            "  • DeepTune Chain    : os/deeptune.sh -> bsp/spacemit/k1/deeptune.sh -> boards/orangepi/rv2/deeptune.sh"
            in proc.stdout
        )

    def test_capability_based_nommu_and_riscv32_checks_without_esp32p4_soc(self, tmp_path: Path) -> None:
        repo = tmp_path / "rvdk"
        shutil.copytree(REPO_ROOT / "lib", repo / "lib")
        shutil.copy2(REPO_ROOT / "bootstrap.sh", repo / "bootstrap.sh")
        (repo / "bootstrap.sh").chmod(0o755)

        spy_log = tmp_path / "cap_spy.log"
        _write_exe(
            repo / "os" / "bootstrap-apt.sh",
            f"#!/usr/bin/env bash\necho OS_BOOTSTRAP >> '{spy_log}'\nexit 1\n",
        )
        _write_exe(
            repo / "os" / "deeptune.sh",
            f"#!/usr/bin/env bash\necho OS_DEEPTUNE >> '{spy_log}'\nexit 1\n",
        )
        _write_exe(
            repo / "bsp" / "acme" / "nommu-soc" / "forge.sh",
            f"#!/usr/bin/env bash\necho BSP_FORGE $* >> '{spy_log}'\n",
        )
        _write_exe(
            repo / "bsp" / "acme" / "nommu-soc" / "deeptune.sh",
            f"""#!/usr/bin/env bash
echo BSP_DT $* >> '{spy_log}'
stage_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir) stage_dir="$2"; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "${{stage_dir}}/config"
cat > "${{stage_dir}}/config/deeptune.env" <<'EOF'
RVDK_TUNE="iot"
RVDK_SDKCONFIG_FRAGMENT="custom.nommu.defaults"
EOF
""",
        )

        # Mock uname -m -> riscv32 on Linux so capability check triggers even with --os buildroot
        bin_dir = tmp_path / "bin"
        real_uname = shutil.which("uname") or "/usr/bin/uname"
        _write_exe(
            bin_dir / "uname",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-m" ]]; then
    printf 'riscv32\\n'
    exit 0
fi
if [[ "${{1:-}}" == "-s" ]]; then
    printf 'Linux\\n'
    exit 0
fi
exec "{real_uname}" "$@"
""",
        )

        stage_dir = tmp_path / "stage_nommu"
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_KIT_CACHE_FILE": str(tmp_path / "none.env"),
            "RVDK_DEEPTUNE_ENV": str(tmp_path / "none_dt.env"),
        }

        # 1. day0 with non-esp32p4 SoC + --tune data + --os linux-nommu
        p_day0 = subprocess.run(
            [
                BASH_BIN,
                str(repo / "bootstrap.sh"),
                "day0",
                "--soc",
                "acme/nommu-soc",
                "--board",
                "acme/nommu-board",
                "--os",
                "linux-nommu",
                "--tune",
                "data",
                "--stage-dir",
                str(stage_dir),
                "--noprogbar",
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert p_day0.returncode == 0, p_day0.stderr
        assert "Skipping os/bootstrap-apt.sh" in p_day0.stdout
        dt_env_text = (stage_dir / "config" / "deeptune.env").read_text(encoding="utf-8")
        assert 'RVDK_SDKCONFIG_FRAGMENT="custom.nommu.defaults"' in dt_env_text
        assert 'RVDK_TUNE="iot"' in dt_env_text
        calls = spy_log.read_text(encoding="utf-8").splitlines()
        assert not any(c.startswith("OS_") for c in calls)
        assert any(c.startswith("BSP_FORGE") for c in calls)
        assert any(c.startswith("BSP_DT") for c in calls)

        # 2. `os` stage skips os/bootstrap-apt.sh based on capability (arch=riscv32 / mmu=none)
        boot_os_copy = repo / "bootstrap_os_unpriv.sh"
        boot_src = (REPO_ROOT / "bootstrap.sh").read_text(encoding="utf-8")
        assert 'NEED_ROOT="true"' in boot_src
        boot_os_copy.write_text(boot_src.replace('NEED_ROOT="true"', 'NEED_ROOT="false"', 1), encoding="utf-8")
        boot_os_copy.chmod(0o755)
        p_os = subprocess.run(
            [
                BASH_BIN,
                str(boot_os_copy),
                "os",
                "--soc",
                "acme/nommu-soc",
                "--board",
                "acme/nommu-board",
                "--os",
                "buildroot",
                "--noprogbar",
            ],
            capture_output=True,
            text=True,
            env={
                **env,
                "RVDK_APT_STAMP_FILE": str(tmp_path / "apt.stamp"),
            },
            check=False,
        )
        assert p_os.returncode == 0, p_os.stderr
        assert "Skipping os/bootstrap-apt.sh" in p_os.stdout
        assert not spy_log.exists() or "OS_BOOTSTRAP" not in spy_log.read_text(encoding="utf-8")

    def test_esp32p4_forge_respects_rvdk_board_and_cli_board_with_default_fallback(
        self, tmp_path: Path
    ) -> None:
        forge = REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "forge.sh"

        # 1. RVDK_BOARD override
        stage_env = tmp_path / "stage_env"
        p_env = subprocess.run(
            [BASH_BIN, str(forge), "--stage-dir", str(stage_env), "--noprogbar"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env={
                "PATH": f"{Path(BASH_BIN).parent}:{os.environ['PATH']}",
                "RVDK_BOARD": "acme/p4-sensor-node",
            },
            check=False,
        )
        assert p_env.returncode == 0, p_env.stderr
        kit_env = (stage_env / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert 'RVDK_BOARD="acme/p4-sensor-node"' in kit_env
        assert 'RVDK_BOARD_TAG="p4-sensor-node"' in kit_env

        # 2. Explicit --board overrides RVDK_BOARD
        stage_cli = tmp_path / "stage_cli"
        p_cli = subprocess.run(
            [BASH_BIN, str(forge), "--board", "acme/p4-cli-kit", "--stage-dir", str(stage_cli), "--noprogbar"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env={
                "PATH": f"{Path(BASH_BIN).parent}:{os.environ['PATH']}",
                "RVDK_BOARD": "acme/p4-sensor-node",
            },
            check=False,
        )
        assert p_cli.returncode == 0, p_cli.stderr
        kit_cli = (stage_cli / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert 'RVDK_BOARD="acme/p4-cli-kit"' in kit_cli
        assert 'RVDK_BOARD_TAG="p4-cli-kit"' in kit_cli

        # 3. Neither set -> default waveshare/esp32-p4-wifi6
        stage_def = tmp_path / "stage_def"
        p_def = subprocess.run(
            [BASH_BIN, str(forge), "--stage-dir", str(stage_def), "--noprogbar"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env={"PATH": f"{Path(BASH_BIN).parent}:{os.environ['PATH']}"},
            check=False,
        )
        assert p_def.returncode == 0, p_def.stderr
        kit_def = (stage_def / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert 'RVDK_BOARD="waveshare/esp32-p4-wifi6"' in kit_def
        assert 'RVDK_BOARD_TAG="p4"' in kit_def

        # 4. Malformed traversal board rejected
        p_bad = subprocess.run(
            [BASH_BIN, str(forge), "--stage-dir", str(tmp_path / "stage_bad"), "--noprogbar"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            env={
                "PATH": f"{Path(BASH_BIN).parent}:{os.environ['PATH']}",
                "RVDK_BOARD": "../../etc",
            },
            check=False,
        )
        assert p_bad.returncode != 0
