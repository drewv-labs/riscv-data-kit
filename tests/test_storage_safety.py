"""Mocked-subprocess safety regression tests for WP-03 storage hardening.

Covers:
  - utils/storage.sh: multi-device/degraded/mismatched Btrfs online shrink refusal,
    exact devid resolution & resize/rollback targeting, and weight <= 0 / sum <= 0 guards.
  - mods/btrfs-raid/forge.sh: non-btrfs EXISTING_DEV/mount rejection, explicit .devices[]
    UUID & member parity validation, and removal of non-btrfs /etc/fstab fallback.
  - mods/nvme-4kn/forge.sh: removal of implicit /dev/nvme0n1 default, missing --device
    candidate diagnostic, NVME_DEV config.env support, and --force-wipe --yes / TTY gate.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
STORAGE_SH = REPO_ROOT / "utils" / "storage.sh"
BTRFS_RAID_FORGE = REPO_ROOT / "mods" / "btrfs-raid" / "forge.sh"
NVME_4KN_FORGE = REPO_ROOT / "mods" / "nvme-4kn" / "forge.sh"


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
    pytest.skip("Bash >= 4.0 is required for RVDK storage safety tests")
    raise AssertionError("unreachable")


BASH_BIN = _find_bash()


def _run_bash(
    script: str,
    env: dict[str, str] | None = None,
    stdin_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [BASH_BIN, "-c", script],
        input=stdin_text,
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


def _make_linux_uname_shim(bin_dir: Path) -> None:
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


def _load_rvdk_ci() -> ModuleType:
    ci_path = REPO_ROOT / "tools" / "rvdk_ci.py"
    spec = importlib.util.spec_from_file_location("rvdk_ci", ci_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _make_jq_shim(bin_dir: Path) -> None:
    _write_exe(
        bin_dir / "jq",
        f"""#!{sys.executable}
import json
import sys

args = sys.argv[1:]
raw = False
argjson: dict[str, int] = {{}}
i = 0
while i < len(args):
    a = args[i]
    if a == "-r":
        raw = True
        i += 1
    elif a == "--argjson":
        argjson[args[i + 1]] = int(args[i + 2])
        i += 3
    else:
        expr = a
        i += 1

data = json.load(sys.stdin)
if 'if type=="array"' in expr:
    print(len(data) if isinstance(data, list) else -1)
    sys.exit(0)

idx = argjson["idx"]
item = data[idx]
fields = [
    item.get("name") or f"array_{{idx}}",
    item.get("type") or "data",
    str(item.get("profile") or "raid10").lower(),
    item.get("label") or "",
    item.get("mount") or "",
    str(item.get("disks") if item.get("disks") is not None else 4),
    str(item.get("min_bytes") if item.get("min_bytes") is not None else 0),
    str(item.get("max_bytes") if item.get("max_bytes") is not None else 0),
    "\x1f".join(str(x) for x in (item.get("devices") or [])),
    "\x1f".join(str(x) for x in (item.get("subdirs") or [])),
    str(len(item.get("devices") or [])),
]
for f in fields:
    print(f if raw else json.dumps(f))
""",
    )


def _run_with_pty(cmd: list[str], env: dict[str, str], reply: str) -> tuple[int, str]:
    master_fd, slave_fd = pty.openpty()
    output_chunks: list[bytes] = []
    sent_reply = False
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
            close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1

        deadline = time.monotonic() + 15.0
        while True:
            rlist, _, _ = select.select([master_fd], [], [], 0.05)
            if rlist:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    output_chunks.append(chunk)
                    joined = b"".join(output_chunks)
                    if not sent_reply and b"[CONFIRM]" in joined:
                        os.write(master_fd, reply.encode("utf-8"))
                        sent_reply = True
                elif proc.poll() is not None:
                    break
            elif proc.poll() is not None:
                while True:
                    r_tail, _, _ = select.select([master_fd], [], [], 0.02)
                    if not r_tail:
                        break
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output_chunks.append(chunk)
                break
            elif time.monotonic() > deadline:
                proc.kill()
                proc.wait(timeout=5)
                raise TimeoutError("Timed out waiting for PTY command")

        rc = proc.wait(timeout=5)
        return rc, b"".join(output_chunks).decode("utf-8", errors="replace")
    finally:
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)


class TestOnlineBtrfsShrinkSafety:
    def _setup_storage_env(
        self,
        tmp_path: Path,
        btrfs_show_stdout: str,
        *,
        btrfs_show_rc: int = 0,
        lvreduce_rc: int = 0,
    ) -> tuple[dict[str, str], Path, Path]:
        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)

        btrfs_log = tmp_path / "btrfs.log"
        lvreduce_log = tmp_path / "lvreduce.log"

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
    printf '  lv_sec\\n'
    exit 0
fi
if [[ "${1:-}" == "vg_rvdk/lv_sec" ]]; then
    exit 0
fi
if [[ "$*" == *"lv_size"* ]]; then
    printf '32212254720\\n'
    exit 0
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "findmnt",
            """#!/usr/bin/env bash
case "$*" in
    *"-S /dev/vg_rvdk/lv_sec -o TARGET"*) printf '/mnt/lv_sec\\n' ;;
    *"-M /mnt/lv_sec -o FSTYPE"*) printf 'btrfs\\n' ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "df",
            """#!/usr/bin/env bash
printf '1B-blocks Used Avail\\n'
printf '32212254720 1073741824 31138512896\\n'
exit 0
""",
        )
        _write_exe(
            bin_dir / "lvreduce",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{lvreduce_log}"
exit {lvreduce_rc}
""",
        )
        _write_exe(
            bin_dir / "btrfs",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{btrfs_log}"
if [[ "${{1:-}}" == "filesystem" && "${{2:-}}" == "show" ]]; then
    cat <<'EOF'
{btrfs_show_stdout.rstrip()}
EOF
    exit {btrfs_show_rc}
fi
exit 0
""",
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(tmp_path / "nonexistent.env"),
        }
        return env, btrfs_log, lvreduce_log

    def test_shrink_refuses_multi_device_and_degraded_btrfs(self, tmp_path: Path) -> None:
        multi_out = """Label: 'RVDK_SEC'  uuid: 11111111-2222-3333-4444-555555555555
\tTotal devices 2 FS bytes used 1.00GiB
\tdevid    1 size 30.00GiB used 2.02GiB path /dev/mapper/vg_rvdk-lv_sec
\tdevid    2 size 30.00GiB used 2.02GiB path /dev/sdb"""
        env, btrfs_log, lvreduce_log = self._setup_storage_env(tmp_path, multi_out)

        for extra_flag in ("--dry-run", ""):
            btrfs_log.unlink(missing_ok=True)
            lvreduce_log.unlink(missing_ok=True)
            proc = _run_bash(
                f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main shrink --lv lv_sec --gb 5 {extra_flag}
""",
                env=env,
            )
            assert proc.returncode != 0
            assert "2 devices" in proc.stderr
            assert not lvreduce_log.exists()
            if btrfs_log.exists():
                assert "resize" not in btrfs_log.read_text(encoding="utf-8")

        degraded_out = """Label: 'RVDK_SEC'  uuid: 11111111-2222-3333-4444-555555555555
\tTotal devices 2 FS bytes used 1.00GiB
\tdevid    1 size 30.00GiB used 2.02GiB path /dev/mapper/vg_rvdk-lv_sec
\t*** Some devices missing"""
        env_deg, btrfs_log_deg, lvreduce_log_deg = self._setup_storage_env(tmp_path, degraded_out)
        proc_deg = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main shrink --lv lv_sec --gb 5
""",
            env=env_deg,
        )
        assert proc_deg.returncode != 0
        assert "missing/degraded" in proc_deg.stderr
        assert not lvreduce_log_deg.exists()
        assert "resize" not in btrfs_log_deg.read_text(encoding="utf-8")

    def test_shrink_refuses_mismatched_member_device_and_empty_show(self, tmp_path: Path) -> None:
        wrong_dev_out = """Label: 'RVDK_SEC'  uuid: 11111111-2222-3333-4444-555555555555
\tTotal devices 1 FS bytes used 1.00GiB
\tdevid    1 size 30.00GiB used 2.02GiB path /dev/sdb1"""
        env, btrfs_log, lvreduce_log = self._setup_storage_env(tmp_path, wrong_dev_out)
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main shrink --lv lv_sec --gb 5
""",
            env=env,
        )
        assert proc.returncode != 0
        assert "does not match target LV" in proc.stderr
        assert not lvreduce_log.exists()
        assert "resize" not in btrfs_log.read_text(encoding="utf-8")

        env_fail, btrfs_log_fail, lvreduce_log_fail = self._setup_storage_env(
            tmp_path, "", btrfs_show_rc=1
        )
        proc_fail = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main shrink --lv lv_sec --gb 5
""",
            env=env_fail,
        )
        assert proc_fail.returncode != 0
        assert "unable to inspect Btrfs member devices" in proc_fail.stderr
        assert not lvreduce_log_fail.exists()
        assert "resize" not in btrfs_log_fail.read_text(encoding="utf-8")

    def test_shrink_passes_exact_devid_for_resize_and_rollback(self, tmp_path: Path) -> None:
        single_out = """Label: 'RVDK_SEC'  uuid: 11111111-2222-3333-4444-555555555555
\tTotal devices 1 FS bytes used 1.00GiB
\tdevid    3 size 30.00GiB used 2.02GiB path /dev/mapper/vg_rvdk-lv_sec"""
        env, btrfs_log, lvreduce_log = self._setup_storage_env(
            tmp_path / "ok", single_out, lvreduce_rc=0
        )

        proc_ok = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main shrink --lv lv_sec --gb 5
""",
            env=env,
        )
        assert proc_ok.returncode == 0, proc_ok.stderr
        expected_pre = 32212254720 - 5 * 1073741824 - 64 * 1048576
        btrfs_calls = btrfs_log.read_text(encoding="utf-8").splitlines()
        assert btrfs_calls == [
            "filesystem show /mnt/lv_sec",
            f"filesystem resize 3:{expected_pre} /mnt/lv_sec",
            "filesystem resize 3:max /mnt/lv_sec",
        ]
        assert lvreduce_log.read_text(encoding="utf-8").strip() == "-f -y -l 6400 /dev/vg_rvdk/lv_sec"

        env_rb, btrfs_log_rb, _ = self._setup_storage_env(
            tmp_path / "rb", single_out, lvreduce_rc=1
        )
        proc_rb = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main shrink --lv lv_sec --gb 5
""",
            env=env_rb,
        )
        assert proc_rb.returncode != 0
        assert "Online LV shrink aborted safely" in proc_rb.stderr
        assert btrfs_log_rb.read_text(encoding="utf-8").splitlines() == [
            "filesystem show /mnt/lv_sec",
            f"filesystem resize 3:{expected_pre} /mnt/lv_sec",
            "filesystem resize 3:max /mnt/lv_sec",
        ]


class TestAutotuneWeightAndDivByZeroGuards:
    def _setup_autotune_env(self, tmp_path: Path) -> dict[str, str]:
        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
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
printf '42949672960 36507222016 6442450944\\n'
exit 0
""",
        )
        return {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(tmp_path / "nonexistent.env"),
        }

    @pytest.mark.parametrize(
        "bad_weights",
        [
            "lv_a:0",
            "lv_a:0.0",
            "lv_a:00.000",
            "lv_a:-1",
            "lv_a",
            "lv_a:1.5,lv_b:0",
            "unmounted_lv:0",
        ],
    )
    def test_autotune_rejects_nonpositive_and_malformed_weights(
        self, tmp_path: Path, bad_weights: str
    ) -> None:
        env = self._setup_autotune_env(tmp_path)
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main autotune --vg vg_rvdk --weights "{bad_weights}" --dry-run
""",
            env=env,
        )
        assert proc.returncode != 0
        assert "--weights" in proc.stderr

    def test_lv_weight_for_rejects_zero_directly(self) -> None:
        storage_src = STORAGE_SH.read_text(encoding="utf-8")
        parse_match = re.search(
            r"(?ms)^    _parse_weight_pair\(\)\s*\{.*?^    \}",
            storage_src,
        )
        fn_match = re.search(
            r"(?ms)^    lv_weight_for\(\)\s*\{.*?^    \}",
            storage_src,
        )
        assert parse_match is not None and fn_match is not None
        proc = _run_bash(
            f"""
set -Eeuo pipefail
log_fatal() {{ printf '%s\\n' "$1" >&2; exit 1; }}
weights_csv="lv_a:0"
primary_lv="lv_data"
{parse_match.group(0)}
{fn_match.group(0)}
lv_weight_for lv_a
"""
        )
        assert proc.returncode != 0
        assert "greater than 0" in proc.stderr

    def test_autotune_awk_blocks_guard_sum_lte_zero_before_division(self) -> None:
        storage_text = STORAGE_SH.read_text(encoding="utf-8")
        dist_match = re.search(
            r'dist_out="\$\(awk -v alloc="\$alloc_ext" -v specs="\$score_args" \'(.*?)\'\)"',
            storage_text,
            flags=re.DOTALL,
        )
        grant_match = re.search(
            r'grant_out="\$\(awk -v alloc="\$alloc_ext" -v specs="\$w_specs" \'(.*?)\'\)"',
            storage_text,
            flags=re.DOTALL,
        )
        assert dist_match is not None, "Could not locate dist_out awk block in utils/storage.sh"
        assert grant_match is not None, "Could not locate grant_out awk block in utils/storage.sh"

        for label, awk_prog in (("dist_out", dist_match.group(1)), ("grant_out", grant_match.group(1))):
            proc_two = subprocess.run(
                ["awk", "-v", "alloc=50", "-v", "specs=40:0 60:0", awk_prog],
                capture_output=True,
                text=True,
                check=False,
            )
            assert proc_two.returncode == 0, f"{label} failed: {proc_two.stderr}"
            assert "division by zero" not in proc_two.stderr.lower()
            assert proc_two.stdout.strip() == "0 0"

            proc_one = subprocess.run(
                ["awk", "-v", "alloc=50", "-v", "specs=1073741824:0", awk_prog],
                capture_output=True,
                text=True,
                check=False,
            )
            assert proc_one.returncode == 0, f"{label} single failed: {proc_one.stderr}"
            assert "division by zero" not in proc_one.stderr.lower()
            assert proc_one.stdout.strip() == "0"

    def test_storage_status_json_schema_v1(self, tmp_path: Path) -> None:
        env = self._setup_autotune_env(tmp_path)
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{STORAGE_SH}"
rvdk_require_root() {{ :; }}
main status --vg vg_rvdk --json
""",
            env=env,
        )
        assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        doc = json.loads(proc.stdout)
        assert doc["schema_version"] == 1
        assert doc["vg_name"] == "vg_rvdk"
        assert doc["vg_size_bytes"] == 107374182400
        assert doc["vg_free_bytes"] == 21474836480
        assert doc["vg_extent_bytes"] == 4194304
        assert doc["vg_extents_total"] == 25600
        assert doc["vg_extents_free"] == 5120
        assert doc["vg_reserve_pct"] == 20
        assert len(doc["lvs"]) == 2
        lv_a = doc["lvs"][0]
        assert lv_a["name"] == "lv_a"
        assert lv_a["path"] == "/dev/vg_rvdk/lv_a"
        assert lv_a["mounted"] is True
        assert lv_a["mount_point"] == "/mnt/lv_a"
        assert lv_a["fstype"] == "xfs"
        assert lv_a["fs_util_pct"] == 85


class TestBtrfsRaidSafety:
    def _prepare_btrfs_raid_script(self, tmp_path: Path, fstab_path: Path) -> Path:
        rvdk_ci = _load_rvdk_ci()
        rendered = rvdk_ci.render_standalone_script(
            BTRFS_RAID_FORGE.read_text(encoding="utf-8"),
            REPO_ROOT,
        )
        # Only relax -b to -e, root check, apt_ensure, and /etc/fstab path in temp copy
        patched = (
            rendered.replace('rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}', "true", 1)
            .replace("rvdk_apt_ensure btrfs-progs jq util-linux", "true", 1)
            .replace('[[ -b "$_arr_src" ]]', '[[ -e "$_arr_src" ]]')
            .replace('[[ -b "$explicit_dev" ]]', '[[ -e "$explicit_dev" ]]')
            .replace('[[ -b "$_canon_dev" ]]', '[[ -e "$_canon_dev" ]]')
            .replace('[[ ! -b "$dev" ]]', '[[ ! -e "$dev" ]]')
            .replace('[[ -b "$dev" ]]', '[[ -e "$dev" ]]')
            .replace("/etc/fstab", str(fstab_path))
            .replace("mountpoint -q", "_rvdk_test_mountpoint_q")
        )
        script_path = tmp_path / "btrfs_raid_test.sh"
        script_path.write_text(patched, encoding="utf-8")
        return script_path

    def test_no_non_btrfs_fstab_fallback_in_forge(self) -> None:
        text = BTRFS_RAID_FORGE.read_text(encoding="utf-8")
        assert 'FSTAB_RAID="${EFFECTIVE_ARR_SPEC}  ${ARR_MOUNT}  ${ARR_FSTYPE}' not in text
        assert 'rvdk_converge_fstab_entry "$EFFECTIVE_ARR_SPEC" "$ARR_MOUNT" "btrfs" "$FSTAB_RAID"' in text

    def test_rejects_non_btrfs_existing_device_and_non_btrfs_mount(self, tmp_path: Path) -> None:
        fstab = tmp_path / "fstab"
        fstab.write_text("# fstab\n", encoding="utf-8")
        script_path = self._prepare_btrfs_raid_script(tmp_path, fstab)
        bin_dir = tmp_path / "bin"
        _make_jq_shim(bin_dir)
        fake_sda = tmp_path / "sda"
        fake_sda.write_text("", encoding="utf-8")

        _write_exe(bin_dir / "btrfs", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "mount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
case "$*" in
    "-L RVDK_RAID10") printf '%s\\n' "{fake_sda}" ;;
    "-s TYPE -o value {fake_sda}") printf 'ext4\\n' ;;
    "-s UUID -o value {fake_sda}") printf 'uuid-ext4\\n' ;;
esac
exit 0
""",
        )

        array_json = json.dumps(
            [
                {
                    "name": "vault_warm",
                    "label": "RVDK_RAID10",
                    "mount": str(tmp_path / "mnt_warm"),
                    "profile": "raid10",
                    "devices": [str(fake_sda)],
                }
            ]
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(tmp_path / "none.env"),
            "RVDK_NO_PROGBAR": "1",
        }
        proc_ext4 = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{array_json}'
""",
            env=env,
        )
        assert proc_ext4.returncode != 0
        assert "expected 'btrfs'" in proc_ext4.stderr
        assert "ext4" in proc_ext4.stderr
        assert fstab.read_text(encoding="utf-8") == "# fstab\n"

        # Also test mountpoint already mounted with non-btrfs (blkid -L empty, findmnt returns fake_sda as xfs)
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
case "$*" in
    "-L RVDK_RAID10") exit 2 ;;
    "-s TYPE -o value {fake_sda}") printf 'xfs\\n' ;;
    "-s UUID -o value {fake_sda}") printf 'uuid-xfs\\n' ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "findmnt",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-rn -o SOURCE -M"* ]]; then
    printf '%s\\n' "{fake_sda}"
fi
exit 0
""",
        )
        proc_mnt_xfs = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 0; }}
source "{script_path}" --json '{array_json}'
""",
            env=env,
        )
        assert proc_mnt_xfs.returncode != 0
        assert "expected 'btrfs'" in proc_mnt_xfs.stderr
        assert "xfs" in proc_mnt_xfs.stderr
        assert fstab.read_text(encoding="utf-8") == "# fstab\n"

    def test_rejects_mismatched_explicit_device_uuids_and_missing_members(self, tmp_path: Path) -> None:
        fstab = tmp_path / "fstab"
        fstab.write_text("# fstab\n", encoding="utf-8")
        script_path = self._prepare_btrfs_raid_script(tmp_path, fstab)
        bin_dir = tmp_path / "bin"
        _make_jq_shim(bin_dir)

        fake_sda = tmp_path / "sda"
        fake_sdb = tmp_path / "sdb"
        fake_sdc = tmp_path / "sdc"
        for f in (fake_sda, fake_sdb, fake_sdc):
            f.write_text("", encoding="utf-8")

        sdb_uuid_file = tmp_path / "sdb_uuid"
        sdb_uuid_file.write_text("uuid-other", encoding="utf-8")
        btrfs_show_file = tmp_path / "btrfs_show"
        btrfs_show_file.write_text("", encoding="utf-8")

        _write_exe(bin_dir / "mount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
case "$*" in
    "-L RVDK_RAID1") printf '%s\\n' "{fake_sda}" ;;
    "-s TYPE -o value {fake_sda}") printf 'btrfs\\n' ;;
    "-s TYPE -o value {fake_sdb}") printf 'btrfs\\n' ;;
    "-s LABEL -o value {fake_sda}") printf 'RVDK_RAID1\\n' ;;
    "-s UUID -o value {fake_sda}") printf 'uuid-1111\\n' ;;
    "-s UUID -o value {fake_sdb}") cat "{sdb_uuid_file}"; printf '\\n' ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "btrfs",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "filesystem" && "${{2:-}}" == "show" ]]; then
    cat "{btrfs_show_file}"
fi
exit 0
""",
        )

        mnt_path = tmp_path / "mnt_raid1"
        array_json = json.dumps(
            [
                {
                    "name": "vault_raid1",
                    "label": "RVDK_RAID1",
                    "mount": str(mnt_path),
                    "profile": "raid1",
                    "devices": [str(fake_sda), str(fake_sdb)],
                }
            ]
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(tmp_path / "none.env"),
            "RVDK_NO_PROGBAR": "1",
        }

        # 1. Explicit device UUID mismatch -> fail closed
        proc_uuid_mismatch = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{array_json}'
""",
            env=env,
        )
        assert proc_uuid_mismatch.returncode != 0
        assert "does not match existing Btrfs filesystem" in proc_uuid_mismatch.stderr

        # 2. Same filesystem UUID on sda/sdb, but btrfs filesystem show reveals 3rd member sdc -> fail closed
        sdb_uuid_file.write_text("uuid-1111", encoding="utf-8")
        btrfs_show_file.write_text(
            f"Label: 'RVDK_RAID1'  uuid: uuid-1111\n"
            f"\tTotal devices 3 FS bytes used 1.00GiB\n"
            f"\tdevid    1 size 10GiB used 1GiB path {fake_sda}\n"
            f"\tdevid    2 size 10GiB used 1GiB path {fake_sdb}\n"
            f"\tdevid    3 size 10GiB used 1GiB path {fake_sdc}\n",
            encoding="utf-8",
        )
        proc_missing_member = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{array_json}'
""",
            env=env,
        )
        assert proc_missing_member.returncode != 0
        assert "spans 3 member device(s)" in proc_missing_member.stderr

        # 3. Matching 2-device Btrfs array -> converges cleanly with [SKIP] and btrfs fstab entry
        btrfs_show_file.write_text(
            f"Label: 'RVDK_RAID1'  uuid: uuid-1111\n"
            f"\tTotal devices 2 FS bytes used 1.00GiB\n"
            f"\tdevid    1 size 10GiB used 1GiB path {fake_sda}\n"
            f"\tdevid    2 size 10GiB used 1GiB path {fake_sdb}\n",
            encoding="utf-8",
        )
        proc_ok = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{
    [[ "$1" == "{mnt_path}" ]] && return 0
    return 1
}}
source "{script_path}" --json '{array_json}'
""",
            env=env,
        )
        assert proc_ok.returncode == 0, proc_ok.stderr
        assert "[SKIP]" in proc_ok.stdout
        fstab_lines = fstab.read_text(encoding="utf-8").splitlines()
        assert len(fstab_lines) == 2
        assert fstab_lines[1].startswith(f"LABEL=RVDK_RAID1  {mnt_path}  btrfs  ")

    def test_force_wipe_hardening_ignores_config_env_blocks_autodiscovery_and_requires_yes(
        self, tmp_path: Path
    ) -> None:
        fstab = tmp_path / "fstab"
        fstab.write_text("# fstab\n", encoding="utf-8")
        script_path = self._prepare_btrfs_raid_script(tmp_path, fstab)
        bin_dir = tmp_path / "bin"
        _make_jq_shim(bin_dir)

        fake_sda = tmp_path / "sda"
        fake_sdb = tmp_path / "sdb"
        fake_sda.write_text("", encoding="utf-8")
        fake_sdb.write_text("", encoding="utf-8")

        wipefs_log = tmp_path / "wipefs.log"
        mkfs_log = tmp_path / "mkfs.log"
        _write_exe(bin_dir / "wipefs", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{wipefs_log}"\nexit 0\n')
        _write_exe(bin_dir / "mkfs.btrfs", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{mkfs_log}"\nexit 0\n')
        _write_exe(bin_dir / "btrfs", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "mount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "umount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "udevadm", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "partprobe", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
case "$*" in
    "-L RVDK_RAID1") exit 2 ;;
    "-s TYPE -o value {fake_sda}"|"-s TYPE -o value {fake_sdb}") printf 'ext4\\n' ;;
    "-s UUID -o value {fake_sda}"|"-s UUID -o value {fake_sdb}") printf 'uuid-existing\\n' ;;
    *) exit 2 ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-rn -o PATH,TYPE"*) printf '%s disk\\n' "${{@: -1}}" ;;
    *"-dn -o FSTYPE"*) printf 'ext4\\n' ;;
    *"-dn -o PTTYPE"*) printf 'gpt\\n' ;;
    *"-dn -o MOUNTPOINTS"*) printf '\\n' ;;
    *"-b -dn -o PATH,SIZE,TYPE"*)
        printf '%s 100000000000 disk\\n' "{fake_sda}"
        printf '%s 100000000000 disk\\n' "{fake_sdb}"
        ;;
esac
exit 0
""",
        )

        mnt_path = tmp_path / "mnt_raid1"
        explicit_json = json.dumps(
            [
                {
                    "name": "vault_raid1",
                    "label": "RVDK_RAID1",
                    "mount": str(mnt_path),
                    "profile": "raid1",
                    "devices": [str(fake_sda), str(fake_sdb)],
                }
            ]
        )
        autodisc_json = json.dumps(
            [
                {
                    "name": "vault_auto",
                    "label": "RVDK_RAID1",
                    "mount": str(mnt_path),
                    "profile": "raid1",
                    "disks": 2,
                    "min_bytes": 50000000000,
                    "max_bytes": 200000000000,
                }
            ]
        )

        # 1. FORCE_WIPE_RAID=true in config.env MUST be ignored (no silent persistence)
        cfg_env = tmp_path / "config.env"
        cfg_env.write_text("FORCE_WIPE_RAID=true\n", encoding="utf-8")
        base_env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(cfg_env),
            "RVDK_NO_PROGBAR": "1",
        }
        p_cfg = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{explicit_json}' --yes
""",
            env=base_env,
        )
        assert p_cfg.returncode != 0
        assert "not blank" in p_cfg.stderr.lower() or "force-wipe" in p_cfg.stderr.lower()
        assert not wipefs_log.exists()
        assert not mkfs_log.exists()

        # 2. --force-wipe without explicit .devices[] (auto-discovery) MUST fail closed
        p_auto = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{autodisc_json}' --force-wipe --yes
""",
            env=base_env,
        )
        assert p_auto.returncode != 0
        assert "without explicit .devices[]" in p_auto.stderr
        assert not wipefs_log.exists()
        assert not mkfs_log.exists()

        # 3. --force-wipe with explicit .devices[] in non-TTY without --yes MUST fail closed
        p_nontty = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{explicit_json}' --force-wipe
""",
            env=base_env,
            stdin_text="y\n",
        )
        assert p_nontty.returncode != 0
        assert "not a TTY" in p_nontty.stderr
        assert "--yes" in p_nontty.stderr
        assert not wipefs_log.exists()
        assert not mkfs_log.exists()

        # 4. --force-wipe --yes with explicit .devices[] passes confirmation gate and invokes wipefs + mkfs.btrfs
        p_ok = _run_bash(
            f"""
set -Eeuo pipefail
_rvdk_test_mountpoint_q() {{ return 1; }}
source "{script_path}" --json '{explicit_json}' --force-wipe --yes
""",
            env=base_env,
        )
        assert p_ok.returncode == 0, f"stdout={p_ok.stdout}\nstderr={p_ok.stderr}"
        assert wipefs_log.exists() and str(fake_sda) in wipefs_log.read_text(encoding="utf-8")
        assert mkfs_log.exists() and "RVDK_RAID1" in mkfs_log.read_text(encoding="utf-8")


class TestNvme4knTargetAndWipeConfirmation:
    def _prepare_nvme_script(self, tmp_path: Path) -> Path:
        rvdk_ci = _load_rvdk_ci()
        rendered = rvdk_ci.render_standalone_script(
            NVME_4KN_FORGE.read_text(encoding="utf-8"),
            REPO_ROOT,
        )
        # Keep the confirmation gate and arg validation verbatim; only stub root, block -b, OS check, and apt/disk tail
        patched = (
            rendered.replace('rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}', "true", 1)
            .replace('[[ ! -b "$NVME_DEV" ]]', '[[ ! -e "$NVME_DEV" ]]')
            .replace("if rvdk_device_backs_os_or_swap \"$NVME_DEV\"; then", "if false; then", 1)
        )
        script_path = tmp_path / "nvme_4kn_test.sh"
        script_path.write_text(patched, encoding="utf-8")
        return script_path

    def test_omitted_device_fails_fast_with_candidate_list(self, tmp_path: Path) -> None:
        raw_text = NVME_4KN_FORGE.read_text(encoding="utf-8")
        assert 'NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"' not in raw_text
        assert "default: /dev/nvme0n1" not in raw_text

        help_proc = _run_bash(f'bash "{NVME_4KN_FORGE}" --help')
        assert help_proc.returncode == 0, help_proc.stderr
        assert "-y, --yes" in help_proc.stdout
        assert "default: /dev/nvme0n1" not in help_proc.stdout

        script_path = self._prepare_nvme_script(tmp_path)
        bin_dir = tmp_path / "bin"
        apt_log = tmp_path / "apt.log"
        _write_exe(bin_dir / "apt-get", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{apt_log}"\nexit 0\n')
        _write_exe(
            bin_dir / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"PATH,SIZE,TYPE,MODEL"* ]]; then
    printf '/dev/nvme0n1 931.5G disk Samsung_990_PRO\\n'
    printf '/dev/nvme1n1 1.8T disk WD_Black\\n'
    printf '/dev/sda 4.0T disk Seagate_SATA\\n'
fi
exit 0
""",
        )
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(tmp_path / "empty_config.env"),
            "RVDK_NO_PROGBAR": "1",
        }
        proc = _run_bash(f'bash "{script_path}"', env=env)
        assert proc.returncode != 0
        assert "--device <dev>" in proc.stderr
        assert "/dev/nvme0n1 (931.5G Samsung_990_PRO)" in proc.stderr
        assert "/dev/nvme1n1 (1.8T WD_Black)" in proc.stderr
        assert "/dev/sda" not in proc.stderr
        assert not apt_log.exists()

        # Empty lsblk still fails fast cleanly
        _write_exe(bin_dir / "lsblk", "#!/usr/bin/env bash\nexit 0\n")
        proc_none = _run_bash(f'bash "{script_path}"', env=env)
        assert proc_none.returncode != 0
        assert "none detected" in proc_none.stderr

        # config.env NVME_DEV satisfies target requirement (fails later on missing fake device node)
        cfg_env_file = tmp_path / "config.env"
        cfg_env_file.write_text('NVME_DEV="/dev/nonexistent_nvme_cfg"\n', encoding="utf-8")
        proc_cfg = _run_bash(
            f'bash "{script_path}"',
            env={**env, "RVDK_ENV_FILE": str(cfg_env_file)},
        )
        assert proc_cfg.returncode != 0
        assert "NVMe block device not found: /dev/nonexistent_nvme_cfg" in proc_cfg.stderr

    def test_force_wipe_requires_yes_in_non_tty_and_confirms_in_tty(self, tmp_path: Path) -> None:
        script_path = self._prepare_nvme_script(tmp_path)
        fake_nvme = tmp_path / "nvme1n1"
        fake_nvme.write_text("", encoding="utf-8")

        bin_dir = tmp_path / "bin"
        apt_log = tmp_path / "apt.log"
        nvme_log = tmp_path / "nvme.log"
        wipefs_log = tmp_path / "wipefs.log"
        _write_exe(bin_dir / "apt-get", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{apt_log}"\nexit 1\n')
        _write_exe(bin_dir / "dpkg-query", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "nvme", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{nvme_log}"\nexit 0\n')
        _write_exe(bin_dir / "wipefs", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{wipefs_log}"\nexit 0\n')

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_ENV_FILE": str(tmp_path / "empty_config.env"),
            "RVDK_NO_APT_UPDATE": "1",
            "RVDK_NO_PROGBAR": "1",
        }

        # 1. Non-TTY stdin (even with piped "y\n") without --yes MUST fail closed before apt/disk commands
        for piped_in in (None, "y\n"):
            proc_nontty = _run_bash(
                f'bash "{script_path}" --device "{fake_nvme}" --force-wipe',
                env=env,
                stdin_text=piped_in,
            )
            assert proc_nontty.returncode != 0
            assert "--yes" in proc_nontty.stderr
            assert "not a TTY" in proc_nontty.stderr
            assert not apt_log.exists()
            assert not nvme_log.exists()
            assert not wipefs_log.exists()

        # 2. FORCE_WIPE_NVME=true in config.env in non-TTY without --yes ALSO fails closed
        cfg_wipe = tmp_path / "wipe_config.env"
        cfg_wipe.write_text(f'NVME_DEV="{fake_nvme}"\nFORCE_WIPE_NVME=true\n', encoding="utf-8")
        proc_cfg_wipe = _run_bash(
            f'bash "{script_path}"',
            env={**env, "RVDK_ENV_FILE": str(cfg_wipe)},
        )
        assert proc_cfg_wipe.returncode != 0
        assert "--yes" in proc_cfg_wipe.stderr
        assert not apt_log.exists()

        # 3. Non-TTY WITH --yes passes confirmation gate (reaches sentinel apt-get call)
        proc_yes = _run_bash(
            f'bash "{script_path}" --device "{fake_nvme}" --force-wipe --yes',
            env=env,
        )
        assert proc_yes.returncode != 0
        assert "not a TTY" not in proc_yes.stderr
        assert apt_log.exists()

        # 4. TTY stdin answering 'n' aborts before apt-get/wipe
        apt_log.unlink()
        rc_tty_no, out_tty_no = _run_with_pty(
            [BASH_BIN, str(script_path), "--device", str(fake_nvme), "--force-wipe"],
            env=env,
            reply="n\n",
        )
        assert rc_tty_no != 0
        assert "Aborted by user." in out_tty_no
        assert not apt_log.exists()
        assert not nvme_log.exists()

        # 5. TTY stdin answering 'y' passes confirmation gate (reaches sentinel apt-get call)
        rc_tty_yes, out_tty_yes = _run_with_pty(
            [BASH_BIN, str(script_path), "--device", str(fake_nvme), "--force-wipe"],
            env=env,
            reply="y\n",
        )
        assert rc_tty_yes != 0
        assert "Aborted by user." not in out_tty_yes
        assert "not a TTY" not in out_tty_yes
        assert apt_log.exists()
