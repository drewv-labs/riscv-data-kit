"""Mocked-subprocess regression tests for lib/flash.sh, lib/bsp.sh, and lib/storage_guard.sh."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from types import ModuleType

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


def _write_exe(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


def _make_darwin_uname_shim(bin_dir: Path) -> None:
    real_uname = shutil.which("uname") or "/usr/bin/uname"
    _write_exe(
        bin_dir / "uname",
        f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-s" ]]; then
    printf 'Darwin\\n'
    exit 0
fi
exec "{real_uname}" "$@"
""",
    )


def _make_diskutil_shim(bin_dir: Path, info_output: str, call_log: Path | None = None) -> None:
    log_stmt = f'printf "%s\\n" "$*" >> "{call_log}"' if call_log else ":"
    _write_exe(
        bin_dir / "diskutil",
        f"""#!/usr/bin/env bash
{log_stmt}
case "${{1:-}}" in
    info)
        cat <<'EOF'
{info_output}
EOF
        exit 0
        ;;
    unmountDisk|eject)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
""",
    )


class TestFlashMacosDiskutilInterlock:
    @pytest.mark.parametrize(
        ("label", "disk_arg", "diskutil_info"),
        [
            (
                "apple_silicon_apfs_synthesized_internal",
                "/dev/disk3",
                """   Device Identifier:         disk3
   Device Node:               /dev/disk3
   Device / Media Name:       APPLE SSD AP1024Q
   Device Location:           Internal
   Removable Media:           Fixed
   Virtual:                   Yes
   Disk Size:                 1.0 TB (1000204886016 Bytes)""",
            ),
            (
                "external_virtual_yes",
                "/dev/disk4",
                """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       Virtual Disk Image
   Device Location:           External
   Removable Media:           Removable
   Virtual:                   Yes
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
            ),
            (
                "external_fixed_non_removable",
                "/dev/disk4",
                """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       USB NVMe Enclosure
   Device Location:           External
   Removable Media:           Fixed
   Virtual:                   No
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
            ),
            (
                "missing_fields_fail_closed",
                "/dev/disk4",
                """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       Unknown Device
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
            ),
        ],
    )
    def test_macos_diskutil_rejects_unsafe_or_missing_metadata(
        self, tmp_path: Path, label: str, disk_arg: str, diskutil_info: str
    ) -> None:
        bin_dir = tmp_path / "bin"
        _make_darwin_uname_shim(bin_dir)
        _make_diskutil_shim(bin_dir, diskutil_info)

        tiny_img = tmp_path / "tiny.img"
        tiny_img.write_bytes(b"small")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main vf2 sd "{disk_arg}" --image "{tiny_img}" -y
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode != 0, f"{label} unexpectedly succeeded: {proc.stdout}"
        assert "Safety Interlock:" in proc.stderr, proc.stderr
        assert "rejected" in proc.stderr, proc.stderr

    def test_macos_diskutil_allows_external_removable_non_virtual(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        _make_darwin_uname_shim(bin_dir)
        _make_diskutil_shim(
            bin_dir,
            """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       SanDisk SDDR-B531
   Device Location:           External
   Removable Media:           Removable
   Virtual:                   No
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
        )

        # Tiny custom image stops cleanly AFTER passing the diskutil interlock and size ceiling check
        tiny_img = tmp_path / "tiny.img"
        tiny_img.write_bytes(b"small")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main vf2 sd /dev/disk4 --image "{tiny_img}" -y
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode != 0
        assert "Target macOS Media : /dev/disk4 -> /dev/rdisk4" in proc.stdout
        assert "Using custom image" in proc.stdout
        assert "is only 5 bytes (< 100 MiB)" in proc.stderr
        assert "requires External, non-Virtual, Removable media" not in proc.stderr


class TestUbootExt4AtomicStaging:
    def _setup_p550_uboot_ext4_env(
        self, tmp_path: Path
    ) -> tuple[dict[str, str], Path, Path, Path, str, Path, Path, Path, Path]:
        bin_dir = tmp_path / "bin"
        _make_darwin_uname_shim(bin_dir)
        _make_diskutil_shim(
            bin_dir,
            """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       SanDisk USB Stick
   Device Location:           External
   Removable Media:           Removable
   Virtual:                   No
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
        )

        e2fs_prefix = tmp_path / "e2fsprogs"
        mkfs_log = tmp_path / "mkfs.log"
        mkfs_contents_log = tmp_path / "mkfs_contents.log"
        _write_exe(
            e2fs_prefix / "sbin" / "mkfs.ext4",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{mkfs_log}"
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-d" ]]; then
        ls -A "$arg" >> "{mkfs_contents_log}"
    fi
    prev="$arg"
done
exit 0
""",
        )
        _write_exe(
            bin_dir / "brew",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "--prefix" && "${{2:-}}" == "e2fsprogs" ]]; then
    printf '%s\\n' "{e2fs_prefix}"
    exit 0
fi
exit 1
""",
        )
        _write_exe(
            bin_dir / "sudo",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    exit 0
fi
exec "$@"
""",
        )
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")

        zstd_log = tmp_path / "zstd.log"
        _write_exe(
            bin_dir / "zstd",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{zstd_log}"
printf 'UBOOT_EXT4_STAGED_PAYLOAD_BYTES\\n'
""",
        )

        # 100 MiB + 1 byte sparse source archive passes the >= 100 MiB size check in <1ms
        src_img = tmp_path / "p550-test.img.zst"
        with src_img.open("wb") as fh:
            fh.seek(104857600)
            fh.write(b"\x00")
        src_sha = hashlib.sha256(src_img.read_bytes()).hexdigest()

        cache_dir = tmp_path / "cache"
        stage_dir = cache_dir / "p550-usb-stage"
        staged_img = stage_dir / "ubuntu-24.04-preinstalled-server-riscv64.img"
        stage_stamp = cache_dir / "p550-usb-stage.rvdk-stage.sha256"

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_CACHE_DIR": str(cache_dir),
        }
        return env, src_img, stage_dir, staged_img, src_sha, stage_stamp, zstd_log, mkfs_log, mkfs_contents_log

    def test_uboot_ext4_atomic_staging_create_reuse_and_recover(self, tmp_path: Path) -> None:
        env, src_img, stage_dir, staged_img, src_sha, stage_stamp, zstd_log, mkfs_log, mkfs_contents_log = (
            self._setup_p550_uboot_ext4_env(tmp_path)
        )
        expected_staged_sha = hashlib.sha256(b"UBOOT_EXT4_STAGED_PAYLOAD_BYTES\n").hexdigest()
        payload_name = "ubuntu-24.04-preinstalled-server-riscv64.img"
        legacy_internal_stamp = stage_dir / f"{payload_name}.rvdk-stage.sha256"

        flash_cmd = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main p550 usb /dev/disk4 --image "{src_img}" --sha256 "{src_sha}" -y
"""
        # 1. Initial atomic decompression writes external .rvdk-stage.sha256 and leaves ONLY .img in stage_dir
        run1 = _run_bash(flash_cmd, env=env)
        assert run1.returncode == 0, run1.stderr
        assert staged_img.is_file()
        assert stage_stamp.is_file()
        assert stage_stamp.parent != stage_dir
        assert not legacy_internal_stamp.exists()
        assert [p.name for p in stage_dir.iterdir()] == [payload_name]
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 1
        assert "-O ^metadata_csum_seed,^orphan_file" in mkfs_log.read_text(encoding="utf-8")

        # 2. Valid re-run reuses cached image without re-decompressing and purges any stale internal stamp
        legacy_internal_stamp.write_text("stale\n", encoding="utf-8")
        run2 = _run_bash(flash_cmd, env=env)
        assert run2.returncode == 0, run2.stderr
        assert "Reusing verified decompressed staging payload" in run2.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 1
        assert [p.name for p in stage_dir.iterdir()] == [payload_name]

        # 3. Tampered/truncated staged image is rejected with warning and atomically re-decompressed
        staged_img.write_bytes(b"CORRUPT")
        run3 = _run_bash(flash_cmd, env=env)
        assert run3.returncode == 0, run3.stderr
        assert "failed SHA-256 verification" in run3.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 2
        assert staged_img.read_bytes() == b"UBOOT_EXT4_STAGED_PAYLOAD_BYTES\n"
        assert [p.name for p in stage_dir.iterdir()] == [payload_name]
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"

        # 4. Missing sidecar is rejected with warning and atomically re-decompressed
        stage_stamp.unlink()
        run4 = _run_bash(flash_cmd, env=env)
        assert run4.returncode == 0, run4.stderr
        assert "is missing verification sidecar" in run4.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 3
        assert [p.name for p in stage_dir.iterdir()] == [payload_name]
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"

        # 5. Mismatched sidecar is rejected with warning and atomically re-decompressed
        stage_stamp.write_text(f"{'0' * 64} {expected_staged_sha}\n", encoding="utf-8")
        run5 = _run_bash(flash_cmd, env=env)
        assert run5.returncode == 0, run5.stderr
        assert "does not match source archive SHA-256" in run5.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 4
        assert [p.name for p in stage_dir.iterdir()] == [payload_name]
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"
        assert mkfs_contents_log.read_text(encoding="utf-8").splitlines() == [payload_name] * 5


class TestRewriteLabelToken:
    @pytest.mark.parametrize(
        ("lib_rel", "fn_name"),
        [
            ("lib/flash.sh", "_rvdk_flash_rewrite_label_token"),
            ("lib/bsp.sh", "_rvdk_bsp_rewrite_label_token"),
        ],
    )
    def test_token_bounded_label_rewrite_and_regex_metachar_safety(
        self, lib_rel: str, fn_name: str
    ) -> None:
        sample = (
            "LABEL=armbi_root\n"
            "root=LABEL=armbi_root,ro console=ttyS0\n"
            'append="root=LABEL=armbi_root rw"\n'
            "opt='LABEL=armbi_root'\n"
            "LABEL=armbi_root2\n"
            "LABEL=armbi_root_bak\n"
            "root=LABEL=my_armbi_root\n"
        )
        expected = (
            "LABEL=rvdk_sd_root\n"
            "root=LABEL=rvdk_sd_root,ro console=ttyS0\n"
            'append="root=LABEL=rvdk_sd_root rw"\n'
            "opt='LABEL=rvdk_sd_root'\n"
            "LABEL=armbi_root2\n"
            "LABEL=armbi_root_bak\n"
            "root=LABEL=my_armbi_root\n"
        )
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/{lib_rel}"
{fn_name} "armbi_root" "rvdk_sd_root" <<'EOF'
{sample.rstrip()}
EOF
"""
        proc = _run_bash(script)
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout == expected

        # Regex metacharacters in old/new labels must be treated as literals, never regex/backrefs
        meta_in = (
            "root=LABEL=a.b+c[1](x)*,ro\n"
            "LABEL=aXb+c[1](x)*\n"
            "LABEL=a.b+c[1](x)*_extra\n"
        )
        meta_expected = (
            "root=LABEL=new&\\1$lbl,ro\n"
            "LABEL=aXb+c[1](x)*\n"
            "LABEL=a.b+c[1](x)*_extra\n"
        )
        meta_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/{lib_rel}"
{fn_name} 'a.b+c[1](x)*' 'new&\\1$lbl' <<'EOF'
{meta_in.rstrip()}
EOF
"""
        meta_proc = _run_bash(meta_script)
        assert meta_proc.returncode == 0, meta_proc.stderr
        assert meta_proc.stdout == meta_expected


class TestStorageGuard:
    def _load_guard_without_blk_dev_stat(self, tmp_path: Path) -> Path:
        guard_src = (REPO_ROOT / "lib" / "storage_guard.sh").read_text(encoding="utf-8")
        needle = '[[ -b "$dev" ]] || log_fatal "Block device not found: ${dev}"'
        assert needle in guard_src
        # Only relax -b to -e in the temp test copy so Interlock 1/2/3 run verbatim without root block nodes
        patched = tmp_path / "storage_guard_test.sh"
        patched.write_text(
            guard_src.replace(needle, '[[ -e "$dev" ]] || log_fatal "Block device not found: ${dev}"', 1),
            encoding="utf-8",
        )
        return patched

    def test_lsblk_mountpoints_multiline_escaped_and_legacy_fallback(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"

        # Case 1: Multi-line MOUNTPOINTS with '/' on second line
        _write_exe(
            bin_dir / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"MOUNTPOINTS"* ]]; then
    printf '/mnt/data\\n/\\n'
    exit 0
fi
exit 0
""",
        )
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
_rvdk_lsblk_mountpoints /dev/nvme0n1
rvdk_device_backs_os_or_swap /dev/nvme0n1
"""
        proc = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.splitlines() == ["/mnt/data", "/"]

        # Case 2: Escaped \\n and \\x0a separators in MOUNTPOINTS
        _write_exe(
            bin_dir / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"MOUNTPOINTS"* ]]; then
    printf '%s\\n' '/mnt/data\\n/mnt/extra\\x0a/var'
    exit 0
fi
exit 0
""",
        )
        proc2 = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc2.returncode == 0, proc2.stderr
        assert proc2.stdout.splitlines() == ["/mnt/data", "/mnt/extra", "/var"]

        # Case 3: MOUNTPOINTS unsupported (exits non-zero), fallback to MOUNTPOINT
        _write_exe(
            bin_dir / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"MOUNTPOINTS"* ]]; then
    exit 1
fi
if [[ "$*" == *"MOUNTPOINT"* ]]; then
    printf '/boot\\n'
    exit 0
fi
exit 0
""",
        )
        proc3 = _run_bash(script, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        assert proc3.returncode == 0, proc3.stderr
        assert proc3.stdout.splitlines() == ["/boot"]

        # Case 4: Non-OS mountpoint only -> rvdk_device_backs_os_or_swap returns 1
        _write_exe(
            bin_dir / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"MOUNTPOINTS"* ]]; then
    printf '/mnt/scratch\\n'
    exit 0
fi
exit 0
""",
        )
        proc4 = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
if rvdk_device_backs_os_or_swap /dev/nvme0n1; then
    exit 1
fi
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc4.returncode == 0, proc4.stderr

    def test_interlock3_lsblk_p_parsing_child_blkid_and_no_force_wipe_bypass(
        self, tmp_path: Path
    ) -> None:
        # Real storage_guard.sh still fails closed when dev is not a block device
        non_blk = tmp_path / "not_a_block_dev"
        non_blk.write_text("", encoding="utf-8")
        real_fail = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
rvdk_assert_device_safe_to_wipe "{non_blk}" "false" "RVDK_NVME"
"""
        )
        assert real_fail.returncode != 0
        assert "Block device not found" in real_fail.stderr

        # Parse check: empty FSTYPE="" and spaces in LABEL="My Data Drive"
        parse_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
_rvdk_storage_parse_lsblk_line 'PATH="/dev/nvme0n1p1" TYPE="part" FSTYPE="" LABEL="My Data Drive"'
printf '%s|%s|%s|%s\\n' "$_RVDK_SG_PATH" "$_RVDK_SG_TYPE" "$_RVDK_SG_FSTYPE" "$_RVDK_SG_LABEL"
"""
        )
        assert parse_proc.returncode == 0, parse_proc.stderr
        assert parse_proc.stdout.strip() == "/dev/nvme0n1p1|part||My Data Drive"

        patched_guard = self._load_guard_without_blk_dev_stat(tmp_path)
        bin_dir = tmp_path / "bin"
        fake_dev = tmp_path / "fake_nvme0n1"
        fake_dev.write_text("", encoding="utf-8")

        # Scenario A: lsblk reports empty FSTYPE on parent & child, but blkid on child catches RVDK_NVME.
        # Even with RVDK_NVME passed as the 3rd arg and force_wipe=false, it MUST fail closed.
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-P -o PATH,TYPE,FSTYPE,LABEL"*)
        printf 'PATH="%s" TYPE="disk" FSTYPE="" LABEL="My Data Drive"\\n' "{fake_dev}"
        printf 'PATH="%sp1" TYPE="part" FSTYPE="" LABEL=""\\n' "{fake_dev}"
        ;;
    *"-nr -o PATH"*)
        printf '%s\\n%sp1\\n' "{fake_dev}" "{fake_dev}"
        ;;
    *)
        ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
if [[ "$node" == "{fake_dev}p1" ]]; then
    case "$*" in
        *"-s TYPE"*) printf 'ext4\\n' ;;
        *"-s LABEL"*) printf 'RVDK_NVME\\n' ;;
    esac
fi
exit 0
""",
        )

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        child_blkid_fail = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_guard}"
rvdk_assert_device_safe_to_wipe "{fake_dev}" "false" "RVDK_NVME"
""",
            env=env,
        )
        assert child_blkid_fail.returncode != 0
        assert "contains existing 'ext4' superblock" in child_blkid_fail.stderr
        assert "label=RVDK_NVME" in child_blkid_fail.stderr

        # Scenario B: lsblk -P sees FSTYPE="xfs" with spaced LABEL="My Data Drive" -> fails closed even if 3rd arg matches
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-P -o PATH,TYPE,FSTYPE,LABEL"*)
        printf 'PATH="%s" TYPE="disk" FSTYPE="" LABEL=""\\n' "{fake_dev}"
        printf 'PATH="%sp1" TYPE="part" FSTYPE="xfs" LABEL="My Data Drive"\\n' "{fake_dev}"
        ;;
    *)
        ;;
esac
exit 0
""",
        )
        lsblk_fail = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_guard}"
rvdk_assert_device_safe_to_wipe "{fake_dev}" "false" "My Data Drive"
""",
            env=env,
        )
        assert lsblk_fail.returncode != 0
        assert "already contains 'xfs' signature (label=My Data Drive)" in lsblk_fail.stderr

    def test_rvdk_converge_fstab_entry_idempotent_and_in_place_update(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        systemctl_log = tmp_path / "systemctl.log"
        _write_exe(
            bin_dir / "systemctl",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{systemctl_log}"
exit 1
""",
        )
        fstab = tmp_path / "fstab"
        fstab.write_text(
            "# /etc/fstab\n"
            "UUID=root-1111  /  ext4  defaults  0  1\n"
            "UUID=boot-2222  /boot  vfat  defaults  0  2\n",
            encoding="utf-8",
        )

        entry1 = "LABEL=RVDK_NVME  /mnt/nvme_data  xfs  rw,noatime,nodiratime,nofail  0  2"
        entry2 = "LABEL=RVDK_NVME  /mnt/nvme_data  xfs  rw,noatime,nodiratime,logbufs=8,nofail  0  2"

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}

        # Pass 1: add -> [OK]
        run1 = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
rvdk_converge_fstab_entry "LABEL=RVDK_NVME" "/mnt/nvme_data" "xfs" "{entry1}" "{fstab}"
""",
            env=env,
        )
        assert run1.returncode == 0, run1.stderr
        assert "[OK]" in run1.stdout
        assert not systemctl_log.exists()
        expected1 = (
            "# /etc/fstab\n"
            "UUID=root-1111  /  ext4  defaults  0  1\n"
            "UUID=boot-2222  /boot  vfat  defaults  0  2\n"
            f"{entry1}\n"
        )
        assert fstab.read_text(encoding="utf-8") == expected1

        # Pass 2: unchanged -> [SKIP], zero systemctl calls
        run2 = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
rvdk_converge_fstab_entry "LABEL=RVDK_NVME" "/mnt/nvme_data" "xfs" "{entry1}" "{fstab}"
""",
            env=env,
        )
        assert run2.returncode == 0, run2.stderr
        assert "[SKIP]" in run2.stdout
        assert "[OK]" not in run2.stdout
        assert fstab.read_text(encoding="utf-8") == expected1
        assert not systemctl_log.exists()

        # Pass 3: matching mount with trailing slash updates existing line in-place
        run3 = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
rvdk_converge_fstab_entry "LABEL=NEW_SPEC" "/mnt/nvme_data/" "xfs" "{entry2}" "{fstab}"
""",
            env=env,
        )
        assert run3.returncode == 0, run3.stderr
        assert "[OK]" in run3.stdout
        assert not systemctl_log.exists()
        expected2 = (
            "# /etc/fstab\n"
            "UUID=root-1111  /  ext4  defaults  0  1\n"
            "UUID=boot-2222  /boot  vfat  defaults  0  2\n"
            f"{entry2}\n"
        )
        assert fstab.read_text(encoding="utf-8") == expected2


class TestFlashP4AndMinImageMib:
    def _make_p4_boards_dir(
        self,
        tmp_path: Path,
        *,
        min_image_mib: int | None = 4,
    ) -> tuple[Path, Path]:
        boards_dir = tmp_path / "boards"
        p4_dir = boards_dir / "waveshare" / "esp32-p4-wifi6"
        p4_dir.mkdir(parents=True)
        spy_log = tmp_path / "flash_sd_spy.log"
        _write_exe(
            p4_dir / "flash-sd.sh",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" > "{spy_log}"
exit 0
""",
        )
        sd_spec: dict[str, object] = {
            "mode": "sd_bootstrap",
            "script": "flash-sd.sh",
            "description": "Waveshare ESP32-P4 SD provisioning",
            "root_label": "RVDK_P4_SD",
            "min_size_gib": 4,
        }
        if min_image_mib is not None:
            sd_spec["min_image_mib"] = min_image_mib

        manifest = {
            "schema_version": 1,
            "board": "waveshare/esp32-p4-wifi6",
            "tag": "p4",
            "name": "Waveshare ESP32-P4-WIFI6-DEV-KIT",
            "soc": "espressif/esp32p4",
            "arch": "riscv32",
            "default_os": "esp-idf",
            "media": {"sd": sd_spec},
            "quirks": [],
        }
        (p4_dir / "media.json").write_text(json.dumps(manifest), encoding="utf-8")
        return boards_dir, spy_log

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
    def test_resolve_manifest_all_13_esp32p4_aliases(self, tmp_path: Path, alias: str) -> None:
        boards_dir, _ = self._make_p4_boards_dir(tmp_path)
        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
_rvdk_flash_resolve_manifest "{alias}"
"""
        proc = _run_bash(script, env={"RVDK_BOARDS_DIR": str(boards_dir)})
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == str(boards_dir / "waveshare" / "esp32-p4-wifi6" / "media.json")

    def test_sd_bootstrap_on_sd_forwards_extra_args_to_flash_sd(self, tmp_path: Path) -> None:
        boards_dir, spy_log = self._make_p4_boards_dir(tmp_path)
        stage_dir = tmp_path / "stage"
        img_file = tmp_path / "app.img"
        img_file.write_bytes(b"img")

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main p4 sd /dev/disk4 \\
    --tune iot \\
    --hostname sensor-01 \\
    --stage-dir "{stage_dir}" \\
    --stage-only \\
    --image "{img_file}" \\
    -n -y
"""
        proc = _run_bash(script, env={"RVDK_BOARDS_DIR": str(boards_dir)})
        assert proc.returncode == 0, proc.stderr
        recorded = spy_log.read_text(encoding="utf-8").strip()
        assert recorded == (
            f"--device /dev/disk4 --image {img_file} --root-label RVDK_P4_SD "
            f"--hostname sensor-01 --tune iot --stage-dir {stage_dir} --stage-only --dry-run --yes"
        )

        # Also test `--stage-only <dir>` syntax without positional disk
        spy_log.unlink()
        script2 = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main p4 sd --stage-only "{stage_dir}" --tune iot
"""
        proc2 = _run_bash(script2, env={"RVDK_BOARDS_DIR": str(boards_dir)})
        assert proc2.returncode == 0, proc2.stderr
        assert (
            spy_log.read_text(encoding="utf-8").strip()
            == f"--root-label RVDK_P4_SD --tune iot --stage-dir {stage_dir} --stage-only"
        )

    def test_min_image_mib_enforces_custom_threshold_and_default_100mib(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        _make_darwin_uname_shim(bin_dir)
        _make_diskutil_shim(
            bin_dir,
            """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       SanDisk MicroSD
   Device Location:           External
   Removable Media:           Removable
   Virtual:                   No
   Disk Size:                 16.0 GB (16000000000 Bytes)""",
        )

        boards_dir_4mib, _ = self._make_p4_boards_dir(tmp_path / "m4", min_image_mib=4)
        boards_dir_def, _ = self._make_p4_boards_dir(tmp_path / "mdef", min_image_mib=None)

        img_1m = tmp_path / "small.img"
        with img_1m.open("wb") as fh:
            fh.seek(1024 * 1024 - 1)
            fh.write(b"\x00")

        img_5m = tmp_path / "valid5m.img"
        with img_5m.open("wb") as fh:
            fh.seek(5 * 1024 * 1024 - 1)
            fh.write(b"\x00")

        base_env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_FLASH_FORCE_RAW": "1",
        }

        dd_log = tmp_path / "dd.log"
        _write_exe(
            bin_dir / "dd",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{dd_log}"
exit 0
""",
        )
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "sleep", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "brew", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(
            bin_dir / "sudo",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    exit 0
fi
exec "$@"
""",
        )

        # 1 MiB image fails `< 4 MiB` check
        fail_1m = _run_bash(
            f'set -Eeuo pipefail; source "{REPO_ROOT}/lib/flash.sh"; rvdk_flash_main p4 sd /dev/disk4 --image "{img_1m}" -y',
            env={**base_env, "RVDK_BOARDS_DIR": str(boards_dir_4mib)},
        )
        assert fail_1m.returncode != 0
        assert "(< 4 MiB)" in fail_1m.stderr
        assert not dd_log.exists()

        # 5 MiB image passes `< 4 MiB` check and executes dd
        pass_5m = subprocess.run(
            [
                BASH_BIN,
                "-c",
                f'set -Eeuo pipefail; source "{REPO_ROOT}/lib/flash.sh"; rvdk_flash_main p4 sd /dev/disk4 --image "{img_5m}" -y',
            ],
            capture_output=True,
            text=True,
            env={**os.environ, **base_env, "RVDK_BOARDS_DIR": str(boards_dir_4mib)},
            timeout=15,
            check=False,
        )
        assert pass_5m.returncode == 0, pass_5m.stderr
        assert "Refusing to write!" not in pass_5m.stderr
        assert f"if={img_5m} of=/dev/rdisk4" in dd_log.read_text(encoding="utf-8")

        # Without explicit min_image_mib, default 100 MiB interlock still rejects 5 MiB image
        fail_def = _run_bash(
            f'set -Eeuo pipefail; source "{REPO_ROOT}/lib/flash.sh"; rvdk_flash_main p4 sd /dev/disk4 --image "{img_5m}" -y',
            env={**base_env, "RVDK_BOARDS_DIR": str(boards_dir_def)},
        )
        assert fail_def.returncode != 0
        assert "(< 100 MiB)" in fail_def.stderr


def _load_rvdk_ci() -> ModuleType:
    ci_path = REPO_ROOT / "tools" / "rvdk_ci.py"
    spec = importlib.util.spec_from_file_location("rvdk_ci", ci_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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


class TestFlashPrefixGlobAndLinuxOsGuards:
    def test_mmcblk1_never_unmounts_or_skips_uuid_collision_for_mmcblk10p1(
        self, tmp_path: Path
    ) -> None:
        dev_dir = tmp_path / "dev"
        dev_dir.mkdir()
        mmc1 = dev_dir / "mmcblk1"
        mmc1p1 = dev_dir / "mmcblk1p1"
        mmc10 = dev_dir / "mmcblk10"
        mmc10p1 = dev_dir / "mmcblk10p1"
        for node in (mmc1, mmc1p1, mmc10, mmc10p1):
            node.write_text("", encoding="utf-8")

        rvdk_ci = _load_rvdk_ci()
        flash_rendered = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "lib" / "flash.sh").read_text(encoding="utf-8"),
            REPO_ROOT,
        )
        needle = '[[ -n "$lp_path" && -b "$lp_path" ]]'
        assert needle in flash_rendered
        patched_flash = tmp_path / "flash_standalone.sh"
        patched_flash.write_text(
            flash_rendered.replace(needle, '[[ -n "$lp_path" && -e "$lp_path" ]]', 1),
            encoding="utf-8",
        )

        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        umount_log = tmp_path / "umount.log"
        tune2fs_log = tmp_path / "tune2fs.log"
        blkid_mode_file = tmp_path / "blkid_mode"
        blkid_mode_file.write_text("collide", encoding="utf-8")
        cur_label_file = tmp_path / "cur_label"
        cur_label_file.write_text("armbi_root", encoding="utf-8")

        _write_exe(bin_dir / "sudo", '#!/usr/bin/env bash\nexec "$@"\n')
        _write_exe(bin_dir / "partprobe", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "blockdev", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "udevadm", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "mount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "e2fsck", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "debugfs", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "uuidgen",
            "#!/usr/bin/env bash\nprintf '22222222-3333-4444-5555-666666666666\\n'\n",
        )
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{umount_log}"
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"PATH,TYPE"* ]]; then
    printf '%s disk\\n%s part\\n' "{mmc1}" "{mmc1p1}"
    exit 0
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{tune2fs_log}"
if [[ "${{1:-}}" == "-l" ]]; then
    lbl="$(cat "{cur_label_file}")"
    cat <<EOF
Filesystem volume name:   ${{lbl}}
Filesystem magic number:  0xEF53
Filesystem features:      has_journal ext_attr resize_inode metadata_csum
Default mount options:    user_xattr acl
Block count:              131072
Block size:               4096
EOF
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ $# -ge 2 ]]; then
    printf '%s' "$2" > "{cur_label_file}"
    exit 0
fi
cat "{cur_label_file}"
printf '\\n'
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-s UUID -o value"*)
        printf '11111111-2222-3333-4444-555555555555\\n'
        ;;
    *"-s LABEL -o value"*)
        cat "{cur_label_file}"
        printf '\\n'
        ;;
    *"-t UUID=11111111-2222-3333-4444-555555555555 -o device"*)
        if [[ "$(cat "{blkid_mode_file}")" == "collide" ]]; then
            printf '%s\\n%s\\n' "{mmc1p1}" "{mmc10p1}"
        else
            printf '%s\\n%s\\n' "{mmc1}" "{mmc1p1}"
        fi
        ;;
esac
exit 0
""",
        )

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        proc_collide = _run_bash(
            f"""
set -Eeuo pipefail
source "{patched_flash}"
_rvdk_flash_unmount_dev_children "{mmc1}" "true"
_rvdk_flash_postprocess_raw "Linux" "{mmc1}" "1" "rvdk_sd_root" "false" "false" "riscv64"
""",
            env=env,
        )
        assert proc_collide.returncode == 0, proc_collide.stderr
        umounted = umount_log.read_text(encoding="utf-8").splitlines()
        assert str(mmc1p1) in umounted
        assert str(mmc1) in umounted
        assert all("mmcblk10" not in entry for entry in umounted), umounted
        assert (
            f"Assigned unique ext4 UUID on {mmc1p1}: 22222222-3333-4444-5555-666666666666"
            in proc_collide.stdout
        )
        assert (
            f"-U 22222222-3333-4444-5555-666666666666 {mmc1p1}"
            in tune2fs_log.read_text(encoding="utf-8")
        )

        # Sibling partition/base device on the same disk does NOT trigger false collision
        tune2fs_log.unlink()
        cur_label_file.write_text("rvdk_sd_root", encoding="utf-8")
        blkid_mode_file.write_text("self_only", encoding="utf-8")
        proc_self = _run_bash(
            f"""
set -Eeuo pipefail
source "{patched_flash}"
_rvdk_flash_postprocess_raw "Linux" "{mmc1}" "1" "rvdk_sd_root" "false" "false" "riscv64"
""",
            env=env,
        )
        assert proc_self.returncode == 0, proc_self.stderr
        assert "Assigned unique ext4 UUID" not in proc_self.stdout
        assert "-U " not in tune2fs_log.read_text(encoding="utf-8")

    def test_flash_emmc_and_flash_sd_never_unmount_mmcblk10p1_for_mmcblk1(
        self, tmp_path: Path
    ) -> None:
        dev_dir = tmp_path / "dev"
        dev_dir.mkdir()
        mmc1 = dev_dir / "mmcblk1"
        mmc1p1 = dev_dir / "mmcblk1p1"
        mmc10p1 = dev_dir / "mmcblk10p1"
        sd_root = dev_dir / "mmcblk0p1"
        for node in (mmc1, mmc1p1, mmc10p1, sd_root):
            node.write_text("", encoding="utf-8")

        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        umount_log = tmp_path / "umount.log"
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{umount_log}"
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-rn -o PATH,TYPE"*)
        printf '%s disk\\n%s part\\n' "{mmc1}" "{mmc1p1}"
        ;;
    *"-no PKNAME"*)
        printf 'mmcblk0\\n'
        ;;
    *"-dn -o TYPE"*)
        printf 'disk\\n'
        ;;
    *"-dn -o RM"*)
        printf '1\\n'
        ;;
    *"-dn -o HOTPLUG"*)
        printf '1\\n'
        ;;
    *"-dn -o TRAN"*)
        printf 'mmc\\n'
        ;;
    *"-b -dn -o SIZE"*)
        printf '8589934592\\n'
        ;;
    *"-dn -o SIZE"*)
        printf '8G\\n'
        ;;
    *"-dn -o VENDOR,MODEL,SIZE"*)
        printf 'Fake MMC 8G\\n'
        ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "findmnt",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-n -o SOURCE /"* && "$*" != *"/boot"* && "$*" != *"/usr"* && "$*" != *"/var"* && "$*" != *"/home"* && "$*" != *"/etc"* && "$*" != *"/opt"* && "$*" != *"/root"* && "$*" != *"/srv"* ]]; then
    printf '%s\\n' "{sd_root}"
fi
exit 0
""",
        )
        for cmd_name in ("partprobe", "blockdev", "udevadm", "wipefs", "parted", "mkfs.vfat", "mkfs.ext4", "mount", "cp", "sync", "eject", "rsync", "dd", "blkid", "e2label"):
            _write_exe(bin_dir / cmd_name, "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "df", "#!/usr/bin/env bash\nprintf 'Filesystem 1M-blocks Used\\n/dev/root 8000 1000\\n'\n")
        _write_exe(bin_dir / "sudo", '#!/usr/bin/env bash\nexec "$@"\n')
        _write_exe(bin_dir / "id", '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "0\\n"; else printf "root\\n"; fi\n')

        rvdk_ci = _load_rvdk_ci()
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_NO_PROGBAR": "1"}

        # 1. boards/waveshare/esp32-p4-wifi6/flash-sd.sh unmount isolation
        p4_src = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh").read_text(
                encoding="utf-8"
            ),
            REPO_ROOT,
        )
        p4_patched = tmp_path / "p4_flash_sd.sh"
        p4_text = (
            p4_src.replace('[[ -b "$arg" ]]', '[[ -e "$arg" ]]')
            .replace('[[ -b "$PART_DEV" ]]', '[[ -e "$PART_DEV" ]]')
            .replace('_stage_p4_tree "$STAGE_SOURCE"', 'mkdir -p "${STAGE_SOURCE}/config"')
        )
        p4_patched.write_text(p4_text, encoding="utf-8")
        proc_p4 = _run_bash(f'bash "{p4_patched}" "{mmc1}" -y', env=env)
        assert proc_p4.returncode == 0, proc_p4.stderr
        p4_umounts = umount_log.read_text(encoding="utf-8").splitlines()
        assert str(mmc1p1) in p4_umounts
        assert str(mmc1) in p4_umounts
        assert all("mmcblk10" not in entry for entry in p4_umounts), p4_umounts

        # 2. boards/orangepi/rv2/flash-emmc.sh unmount isolation (stops cleanly at blkid empty UUID after unmount)
        umount_log.unlink()
        uboot_dir = tmp_path / "uboot"
        uboot_dir.mkdir()
        for fn in ("bootinfo_emmc.bin", "bootinfo_sd.bin", "FSBL.bin", "u-boot-opensbi.itb"):
            (uboot_dir / fn).write_bytes(b"uboot")

        emmc_src = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "boards" / "orangepi" / "rv2" / "flash-emmc.sh").read_text(
                encoding="utf-8"
            ),
            REPO_ROOT,
        )
        emmc_patched = tmp_path / "rv2_flash_emmc.sh"
        emmc_text = (
            emmc_src.replace(
                'rvdk_require_root "${BASH_SOURCE[0]:-}" ${orig_args[@]+"${orig_args[@]}"}',
                "true",
                1,
            )
            .replace('! -b "$live_root"', '! -e "$live_root"')
            .replace('! -b "$target_dev"', '! -e "$target_dev"')
            .replace('! -b "$emmc_part"', '! -e "$emmc_part"')
            .replace("/usr/lib/u-boot/platform_install.sh", str(tmp_path / "no_platform_install.sh"))
            .replace("/usr/lib/linux-u-boot-*", str(uboot_dir))
            .replace("/etc/fstab", str(tmp_path / "no_fstab"))
        )
        emmc_patched.write_text(emmc_text, encoding="utf-8")
        proc_emmc = _run_bash(f'bash "{emmc_patched}" --force -y "{mmc1}"', env=env)
        # Fails later at empty blkid UUID, AFTER executing the unmount + parted steps
        assert proc_emmc.returncode != 0
        emmc_umounts = umount_log.read_text(encoding="utf-8").splitlines()
        assert str(mmc1p1) in emmc_umounts
        assert str(mmc1) in emmc_umounts
        assert all("mmcblk10" not in entry for entry in emmc_umounts), emmc_umounts

    def test_linux_flashers_reject_x0a_multimount_boot_bypass(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        _write_exe(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "lsblk",
            r"""#!/usr/bin/env bash
if [[ "$*" == *"MOUNTPOINTS"* ]]; then
    printf '%s\n' '/mnt/tmp\x0a/boot'
    exit 0
fi
if [[ "$*" == *"-dn -o TYPE"* ]]; then
    printf 'disk\n'
    exit 0
fi
exit 0
""",
        )

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        tiny_img = tmp_path / "dummy.img"
        tiny_img.write_bytes(b"dummy")

        # 1. lib/flash.sh rejects \x0a-separated /mnt/tmp\x0a/boot
        proc_flash = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main vf2 sd /dev/sdb --image "{tiny_img}" -y
""",
            env=env,
        )
        assert proc_flash.returncode != 0
        assert "Safety Interlock:" in proc_flash.stderr
        assert "backs a critical OS filesystem or active SWAP" in proc_flash.stderr

        # 2. boards/waveshare/esp32-p4-wifi6/flash-sd.sh rejects \x0a-separated /mnt/tmp\x0a/boot
        flash_sd = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh"
        proc_sd = _run_bash(f'bash "{flash_sd}" /dev/sdb --dry-run', env=env)
        assert proc_sd.returncode != 0
        assert "Safety Interlock:" in proc_sd.stderr
        assert "backs critical system mount" in proc_sd.stderr

        # Verify flash-sd.sh does NOT trigger "${arg}"* false positive when '/' is /dev/mmcblk10p1 and arg is /dev/mmcblk1
        bin_dir_pfx = tmp_path / "bin_pfx"
        _make_linux_uname_shim(bin_dir_pfx)
        _write_exe(
            bin_dir_pfx / "findmnt",
            """#!/usr/bin/env bash
if [[ "$*" == *"-rn -o TARGET,SOURCE"* ]]; then
    printf '/ /dev/mmcblk10p1\\n'
elif [[ "$*" == *"-n -o SOURCE /"* && "$*" != *"/boot"* && "$*" != *"/usr"* && "$*" != *"/var"* && "$*" != *"/home"* && "$*" != *"/etc"* && "$*" != *"/opt"* && "$*" != *"/root"* && "$*" != *"/srv"* ]]; then
    printf '/dev/mmcblk10p1\\n'
fi
exit 0
""",
        )
        _write_exe(
            bin_dir_pfx / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"PKNAME"* ]]; then
    printf 'mmcblk10\\n'
fi
exit 0
""",
        )
        pfx_env = {"PATH": f"{bin_dir_pfx}:{os.environ['PATH']}"}
        proc_sd_mmc1 = _run_bash(f'bash "{flash_sd}" /dev/mmcblk1 --dry-run', env=pfx_env)
        assert proc_sd_mmc1.returncode != 0
        assert "backs critical system mount" not in proc_sd_mmc1.stderr
        assert "Block device not found: /dev/mmcblk1" in proc_sd_mmc1.stderr

        proc_sd_mmc10 = _run_bash(f'bash "{flash_sd}" /dev/mmcblk10 --dry-run', env=pfx_env)
        assert proc_sd_mmc10.returncode != 0
        assert "Safety Interlock:" in proc_sd_mmc10.stderr
        assert "backs critical system mount" in proc_sd_mmc10.stderr

        # 3. boards/orangepi/rv2/flash-emmc.sh rejects \x0a-separated /mnt/tmp\x0a/boot
        fake_sd_p1 = tmp_path / "mmcblk0p1"
        fake_sd_p1.write_text("", encoding="utf-8")
        bin_dir_emmc = tmp_path / "bin_emmc"
        _make_linux_uname_shim(bin_dir_emmc)
        _write_exe(
            bin_dir_emmc / "findmnt",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-n -o SOURCE /"* && "$*" != *"/boot"* && "$*" != *"/usr"* && "$*" != *"/var"* && "$*" != *"/home"* && "$*" != *"/etc"* && "$*" != *"/opt"* && "$*" != *"/root"* && "$*" != *"/srv"* ]]; then
    printf '%s\\n' "{fake_sd_p1}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir_emmc / "lsblk",
            r"""#!/usr/bin/env bash
if [[ "$*" == *"PKNAME"* ]]; then
    printf 'mmcblk0\n'
    exit 0
fi
if [[ "$*" == *"MOUNTPOINTS"* ]]; then
    printf '%s\n' '/mnt/tmp\x0a/boot'
    exit 0
fi
exit 0
""",
        )
        rvdk_ci = _load_rvdk_ci()
        emmc_rendered = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "boards" / "orangepi" / "rv2" / "flash-emmc.sh").read_text(
                encoding="utf-8"
            ),
            REPO_ROOT,
        )
        emmc_check = tmp_path / "emmc_x0a.sh"
        emmc_check.write_text(
            emmc_rendered.replace('! -b "$live_root"', '! -e "$live_root"'),
            encoding="utf-8",
        )
        proc_emmc = _run_bash(
            f'bash "{emmc_check}" --force --dry-run /dev/mmcblk2',
            env={"PATH": f"{bin_dir_emmc}:{os.environ['PATH']}"},
        )
        assert proc_emmc.returncode != 0
        assert "Safety Interlock:" in proc_emmc.stderr
        assert "backs a critical OS filesystem or active SWAP" in proc_emmc.stderr

    def test_flash_emmc_literal_etc_hosts_replacement_regex_metachars(
        self, tmp_path: Path
    ) -> None:
        emmc_script = REPO_ROOT / "boards" / "orangepi" / "rv2" / "flash-emmc.sh"

        # 1. host.1 in hostname must replace ONLY literal host.1, never hostX1, host.1.local, host.10, or comments
        hosts1 = tmp_path / "hosts1"
        hosts1.write_text(
            "127.0.0.1\tlocalhost hostX1\n"
            "10.0.0.2\thost.1 host.1.local host.10\n"
            "# host.1 comment\n",
            encoding="utf-8",
        )
        proc1 = _run_bash(
            f"""
set -Eeuo pipefail
source "{emmc_script}"
_rvdk_emmc_update_etc_hosts "{hosts1}" "host.1" "rv2-node-01"
""",
        )
        assert proc1.returncode == 0, proc1.stderr
        assert hosts1.read_text(encoding="utf-8") == (
            "127.0.0.1\tlocalhost hostX1\n"
            "10.0.0.2\trv2-node-01 host.1.local host.10\n"
            "# host.1 comment\n"
        )

        # 2. When only hostX1 exists (no literal host.1), hostX1 is untouched and 127.0.1.1 entry is appended
        hosts2 = tmp_path / "hosts2"
        hosts2.write_text("127.0.0.1\tlocalhost hostX1\n", encoding="utf-8")
        proc2 = _run_bash(
            f"""
set -Eeuo pipefail
source "{emmc_script}"
_rvdk_emmc_update_etc_hosts "{hosts2}" "host.1" "rv2-node-01"
""",
        )
        assert proc2.returncode == 0, proc2.stderr
        assert hosts2.read_text(encoding="utf-8") == (
            "127.0.0.1\tlocalhost hostX1\n"
            "127.0.1.1\trv2-node-01\n"
        )

        # 3. Existing 127.0.1.1 line is updated cleanly without regex/backref corruption
        hosts3 = tmp_path / "hosts3"
        hosts3.write_text("127.0.0.1\tlocalhost\n127.0.1.1\thost.1\n", encoding="utf-8")
        proc3 = _run_bash(
            f"""
set -Eeuo pipefail
source "{emmc_script}"
_rvdk_emmc_update_etc_hosts "{hosts3}" "host.1" "rv2-node-02"
""",
        )
        assert proc3.returncode == 0, proc3.stderr
        assert hosts3.read_text(encoding="utf-8") == (
            "127.0.0.1\tlocalhost\n"
            "127.0.1.1\trv2-node-02\n"
        )

    @pytest.mark.parametrize(
        "rel_path",
        [
            "lib/flash.sh",
            "boards/orangepi/rv2/flash-emmc.sh",
            "boards/waveshare/esp32-p4-wifi6/flash-sd.sh",
        ],
    )
    def test_flashers_inline_storage_guard_and_have_no_prefix_globs(
        self, rel_path: str
    ) -> None:
        raw = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
        for bad_glob in ('"${block_dev}"*', '"${target_dev}"*', '"${RESOLVED_BLOCK_DEV}"*', '"${arg}"*'):
            assert bad_glob not in raw, f"{rel_path} still contains prefix glob {bad_glob}"

        rvdk_ci = _load_rvdk_ci()
        rendered = rvdk_ci.render_standalone_script(raw, REPO_ROOT)
        assert "# --- BEGIN INLINED lib/storage_guard.sh ---" in rendered
        assert 'source "${_FLASH_LIB_DIR}/storage_guard.sh"' not in rendered
        assert 'source "${_REPO_ROOT}/lib/storage_guard.sh"' not in rendered
        syn = subprocess.run([BASH_BIN, "-n"], input=rendered, capture_output=True, text=True, check=False)
        assert syn.returncode == 0, syn.stderr


class TestFlashSha256AndResume:
    def test_local_image_preserved_on_sha256_mismatch_and_malformed_digest(
        self, tmp_path: Path
    ) -> None:
        bin_dir = tmp_path / "bin"
        _make_darwin_uname_shim(bin_dir)
        _make_diskutil_shim(
            bin_dir,
            """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       SanDisk MicroSD
   Device Location:           External
   Removable Media:           Removable
   Virtual:                   No
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
        )

        local_img = tmp_path / "user-provided.img"
        payload = b"LOCAL_USER_IMAGE_DO_NOT_DELETE\n"
        local_img.write_bytes(payload)
        wrong_sha = "0" * 64
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}

        # 1. --image with wrong --sha256 aborts and preserves local file
        proc_mismatch = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main vf2 sd /dev/disk4 --image "{local_img}" --sha256 "{wrong_sha}" -y
""",
            env=env,
        )
        assert proc_mismatch.returncode != 0
        assert "SHA-256 MISMATCH" in proc_mismatch.stderr
        assert "Leaving source file untouched" in proc_mismatch.stderr
        assert local_img.is_file()
        assert local_img.read_bytes() == payload

        # 2. --image with malformed --sha256 aborts and preserves local file
        proc_malformed = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main vf2 sd /dev/disk4 --image "{local_img}" --sha256 "not-valid-hex" -y
""",
            env=env,
        )
        assert proc_malformed.returncode != 0
        assert "Invalid SHA-256 digest format" in proc_malformed.stderr
        assert local_img.is_file()
        assert local_img.read_bytes() == payload

        # 3. Direct _rvdk_flash_verify_sha256 default allow_purge=false preserves image and sidecar
        local_sha = tmp_path / "user-provided.img.sha256"
        local_sha.write_text(f"{wrong_sha}  user-provided.img\n", encoding="utf-8")
        proc_default_keep = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
_rvdk_flash_verify_sha256 "{local_img}" "{local_sha}" "" "{wrong_sha}" "false" "root" "false"
""",
            env=env,
        )
        assert proc_default_keep.returncode != 0
        assert local_img.is_file()
        assert local_sha.is_file()

        # 4. Managed $cache_dir verification (allow_purge=true) purges untrusted cached artifacts
        cached_img = tmp_path / "cached.img"
        cached_sha = tmp_path / "cached.img.sha256"
        cached_img.write_bytes(payload)
        cached_sha.write_text(f"{wrong_sha}  cached.img\n", encoding="utf-8")
        proc_purge = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
_rvdk_flash_verify_sha256 "{cached_img}" "{cached_sha}" "" "{wrong_sha}" "false" "root" "false" "true"
""",
            env=env,
        )
        assert proc_purge.returncode != 0
        assert "Purged untrusted image" in proc_purge.stderr
        assert not cached_img.exists()
        assert not cached_sha.exists()

    @pytest.mark.parametrize("use_fallback", [False, True])
    def test_curl_resume_failure_purges_stale_part_and_retries_from_byte_zero(
        self, tmp_path: Path, use_fallback: bool
    ) -> None:
        bin_dir = tmp_path / "bin"
        _make_darwin_uname_shim(bin_dir)
        _make_diskutil_shim(
            bin_dir,
            """   Device Identifier:         disk4
   Device Node:               /dev/disk4
   Device / Media Name:       SanDisk MicroSD
   Device Location:           External
   Removable Media:           Removable
   Virtual:                   No
   Disk Size:                 32.0 GB (32000000000 Bytes)""",
        )
        _write_exe(bin_dir / "dd", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "sudo", '#!/usr/bin/env bash\nif [[ "${1:-}" == "-v" ]]; then exit 0; fi\nexec "$@"\n')
        _write_exe(bin_dir / "brew", "#!/usr/bin/env bash\nexit 1\n")

        good_payload = b"FRESH_VALID_IMAGE_HEADER\n" + (b"\x00" * (1024 * 1024))
        good_sha = hashlib.sha256(good_payload).hexdigest()
        payload_src = tmp_path / "upstream_payload.img"
        payload_src.write_bytes(good_payload)

        boards_dir = tmp_path / "boards"
        demo_dir = boards_dir / "demo" / "testboard"
        demo_dir.mkdir(parents=True)
        _write_exe(demo_dir / "flash-sd.sh", "#!/usr/bin/env bash\nexit 0\n")

        primary_url = "https://primary.example/demo.img"
        fallback_url = "https://fallback.example/fallback.img"
        manifest = {
            "schema_version": 1,
            "board": "demo/testboard",
            "tag": "testboard",
            "name": "Demo Test Board",
            "soc": "demo/soc",
            "default_os": "debian-13",
            "media": {
                "sd": {
                    "mode": "raw",
                    "script": "flash-sd.sh",
                    "image": "demo.img",
                    "url": primary_url,
                    "sha256": good_sha,
                    "fallback_url": fallback_url,
                    "fallback_sha256": good_sha,
                    "min_image_mib": 1,
                    "min_size_gib": 8,
                }
            },
            "quirks": [],
        }
        (demo_dir / "media.json").write_text(json.dumps(manifest), encoding="utf-8")

        cache_dir = tmp_path / "cache"
        cache_dir.mkdir()
        stale_part = cache_dir / ("fallback.img.part" if use_fallback else "demo.img.part")
        stale_part.write_bytes(b"STALE_CORRUPT_PARTIAL_BYTES_CAUSING_416")

        curl_log = tmp_path / "curl.log"
        fail_primary_line = (
            f'if [[ "$url" == "{primary_url}" ]]; then exit 22; fi'
            if use_fallback
            else ""
        )
        _write_exe(
            bin_dir / "curl",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{curl_log}"
out=""
has_resume="false"
url=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out="$arg"
        prev=""
        continue
    fi
    if [[ "$prev" == "-C" && "$arg" == "-" ]]; then
        has_resume="true"
        prev=""
        continue
    fi
    prev="$arg"
    url="$arg"
done
{fail_primary_line}
if [[ "$has_resume" == "true" ]]; then
    # Simulate HTTP 416 Range Not Satisfiable on stale .part
    exit 33
fi
if [[ -e "$out" ]]; then
    printf 'stale .part was not removed before clean retry: %s\\n' "$out" >&2
    exit 99
fi
cp "{payload_src}" "$out"
exit 0
""",
        )

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_BOARDS_DIR": str(boards_dir),
            "RVDK_CACHE_DIR": str(cache_dir),
        }
        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main testboard sd /dev/disk4 -y
""",
            env=env,
        )
        assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        assert "Resumed download failed" in proc.stdout
        assert not stale_part.exists()

        cached_target = cache_dir / ("fallback.img" if use_fallback else "demo.img")
        assert cached_target.is_file()
        assert cached_target.read_bytes() == good_payload

        curl_calls = curl_log.read_text(encoding="utf-8").splitlines()
        if use_fallback:
            assert len(curl_calls) == 3
            assert primary_url in curl_calls[0] and "-C -" not in curl_calls[0]
            assert fallback_url in curl_calls[1] and "-C -" in curl_calls[1]
            assert fallback_url in curl_calls[2] and "-C -" not in curl_calls[2]
        else:
            assert len(curl_calls) == 2
            assert primary_url in curl_calls[0] and "-C -" in curl_calls[0]
            assert primary_url in curl_calls[1] and "-C -" not in curl_calls[1]


class TestBspConvergeMmcPeerSafety:
    def _prepare_bsp_harness(
        self, tmp_path: Path
    ) -> tuple[Path, Path, Path, Path, Path, Path]:
        sys_block = tmp_path / "sys_block"
        dev_dir = tmp_path / "dev"
        mnt_tmp = tmp_path / "mnt_tmp"
        bin_dir = tmp_path / "bin"
        for d in (sys_block, dev_dir, mnt_tmp, bin_dir):
            d.mkdir(parents=True)

        bsp_src = (REPO_ROOT / "lib" / "bsp.sh").read_text(encoding="utf-8")
        patched_bsp = tmp_path / "bsp_test.sh"
        patched_text = (
            bsp_src.replace('source "${_RVDK_BSP_LIB_DIR}/common.sh"', f'source "{REPO_ROOT}/lib/common.sh"')
            .replace("for sys_mmc in /sys/block/mmcblk*; do", f'for sys_mmc in "{sys_block}"/mmcblk*; do')
            .replace('"/dev/${mmc_name}p"*', f'"{dev_dir}/${{mmc_name}}p"*')
            .replace('"/dev/${mmc_name}"', f'"{dev_dir}/${{mmc_name}}"')
            .replace('[[ -n "$live_root" && -b "$live_root" ]]', '[[ -n "$live_root" && -e "$live_root" ]]')
            .replace('[[ -n "$root_part" && -b "$root_part" ]]', '[[ -n "$root_part" && -e "$root_part" ]]')
            .replace("/tmp/rvdk_mmc_uuid.XXXXXX", f"{mnt_tmp}/rvdk_mmc_uuid.XXXXXX")
        )
        patched_bsp.write_text(patched_text, encoding="utf-8")
        return patched_bsp, sys_block, dev_dir, mnt_tmp, bin_dir, tmp_path

    def _add_mmc_node(self, sys_block: Path, dev_dir: Path, name: str, dev_type: str, parts: list[str]) -> None:
        node_dir = sys_block / name / "device"
        node_dir.mkdir(parents=True)
        (node_dir / "type").write_text(f"{dev_type}\n", encoding="utf-8")
        (dev_dir / name).write_text("", encoding="utf-8")
        for p in parts:
            (dev_dir / p).write_text("", encoding="utf-8")

    def test_peer_uuid_mount_failure_aborts_with_zero_tune2fs_or_e2label_and_no_leaked_tmpdir(
        self, tmp_path: Path
    ) -> None:
        patched_bsp, sys_block, dev_dir, mnt_tmp, bin_dir, _ = self._prepare_bsp_harness(tmp_path)
        self._add_mmc_node(sys_block, dev_dir, "mmcblk0", "SD", ["mmcblk0p1"])
        self._add_mmc_node(sys_block, dev_dir, "mmcblk2", "MMC", ["mmcblk2p1"])

        sd_p1 = dev_dir / "mmcblk0p1"
        emmc_p1 = dev_dir / "mmcblk2p1"
        shared_uuid = "11111111-2222-3333-4444-555555555555"

        tune2fs_log = tmp_path / "tune2fs.log"
        e2label_write_log = tmp_path / "e2label_write.log"
        _write_exe(
            bin_dir / "findmnt",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-n -o SOURCE /"* ]]; then
    printf '%s\\n' "{sd_p1}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"{dev_dir}/mmcblk2"* ]]; then
    printf 'PATH="%s" TYPE="disk" FSTYPE="" SIZE="16000000000" LABEL=""\\n' "{dev_dir}/mmcblk2"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="15000000000" LABEL="armbi_root"\\n' "{emmc_p1}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
case "$*" in
    *"-s TYPE -o value"*) printf 'ext4\\n' ;;
    *"-s UUID -o value"*) printf '%s\\n' "{shared_uuid}" ;;
    *"-s LABEL -o value"*)
        if [[ "$node" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'; else printf 'armbi_root\\n'; fi
        ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ $# -ge 2 ]]; then
    printf '%s\\n' "$*" >> "{e2label_write_log}"
    exit 0
fi
if [[ "${{1:-}}" == "{sd_p1}" ]]; then
    printf 'rvdk_sd_root\\n'
else
    printf 'armbi_root\\n'
fi
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{tune2fs_log}"
if [[ "${{1:-}}" == "-l" ]]; then
    printf 'Default mount options:    user_xattr acl\\n'
    exit 0
fi
exit 0
""",
        )
        _write_exe(bin_dir / "e2fsck", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "uuidgen", "#!/usr/bin/env bash\nprintf '22222222-3333-4444-5555-666666666666\\n'\n")
        _write_exe(bin_dir / "mount", "#!/usr/bin/env bash\nexit 32\n")
        _write_exe(bin_dir / "umount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "mountpoint", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_bsp}"
rvdk_bsp_converge_mmc_root_labels
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, proc.stderr
        assert "[WARN]" in proc.stdout
        assert "Failed to mount peer" in proc.stdout
        assert "De-collided" not in proc.stdout
        assert "Labeled" not in proc.stdout
        tune2fs_calls = tune2fs_log.read_text(encoding="utf-8").splitlines() if tune2fs_log.exists() else []
        assert all("-U" not in line and str(emmc_p1) not in line for line in tune2fs_calls), tune2fs_calls
        assert not e2label_write_log.exists()
        assert list(mnt_tmp.iterdir()) == []

    def test_dual_partition_peer_rewrites_uuid_and_label_and_aborts_on_boot_mount_failure(
        self, tmp_path: Path
    ) -> None:
        patched_bsp, sys_block, dev_dir, mnt_tmp, bin_dir, _ = self._prepare_bsp_harness(tmp_path)
        self._add_mmc_node(sys_block, dev_dir, "mmcblk0", "SD", ["mmcblk0p1"])
        self._add_mmc_node(sys_block, dev_dir, "mmcblk2", "MMC", ["mmcblk2p1", "mmcblk2p2"])

        sd_p1 = dev_dir / "mmcblk0p1"
        emmc_boot = dev_dir / "mmcblk2p1"
        emmc_root = dev_dir / "mmcblk2p2"
        old_uuid = "11111111-2222-3333-4444-555555555555"
        new_uuid = "22222222-3333-4444-5555-666666666666"

        peer_root_backing = tmp_path / "peer_root_backing"
        (peer_root_backing / "etc").mkdir(parents=True)
        (peer_root_backing / "boot").mkdir(parents=True)
        (peer_root_backing / "etc" / "fstab").write_text(
            f"UUID={old_uuid}\t/\text4\tdefaults\t0\t1\n"
            "LABEL=armbi_root\t/mnt/clone\text4\tro\t0\t2\n"
            "LABEL=armbi_root2\t/mnt/extra\text4\tdefaults\t0\t2\n",
            encoding="utf-8",
        )

        peer_boot_backing = tmp_path / "peer_boot_backing"
        (peer_boot_backing / "extlinux").mkdir(parents=True)
        (peer_boot_backing / "spacemit").mkdir(parents=True)
        (peer_boot_backing / "orangepiEnv.txt").write_text(
            f"rootdev=UUID={old_uuid}\nrootfstype=ext4\n", encoding="utf-8"
        )
        (peer_boot_backing / "armbianEnv.txt").write_text(
            "rootdev=LABEL=armbi_root\n", encoding="utf-8"
        )
        (peer_boot_backing / "extlinux" / "extlinux.conf").write_text(
            f'append="root=UUID={old_uuid} root=LABEL=armbi_root rw"\n', encoding="utf-8"
        )
        (peer_boot_backing / "spacemit" / "env_k1-x.txt").write_text(
            f"root=LABEL=armbi_root\nuuid={old_uuid}\n", encoding="utf-8"
        )

        state_dir = tmp_path / "state"
        state_dir.mkdir()
        (state_dir / "emmc_uuid").write_text(old_uuid, encoding="utf-8")
        (state_dir / "emmc_label").write_text("armbi_root", encoding="utf-8")
        (state_dir / "fail_boot_mount").write_text("1", encoding="utf-8")
        ops_log = tmp_path / "ops.log"
        mnt_map = tmp_path / "mnt_map"
        mnt_map.mkdir()

        _write_exe(
            bin_dir / "findmnt",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-n -o SOURCE /"* ]]; then
    printf '%s\\n' "{sd_p1}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"{dev_dir}/mmcblk2"* ]]; then
    lbl="$(cat "{state_dir}/emmc_label")"
    printf 'PATH="%s" TYPE="disk" FSTYPE="" SIZE="16000000000" LABEL=""\\n' "{dev_dir}/mmcblk2"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="134217728" LABEL="armbi_boot"\\n' "{emmc_boot}"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="15000000000" LABEL="%s"\\n' "{emmc_root}" "$lbl"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
case "$*" in
    *"-s TYPE -o value"*) printf 'ext4\\n' ;;
    *"-s UUID -o value"*)
        if [[ "$node" == "{sd_p1}" ]]; then
            printf '%s\\n' "{old_uuid}"
        elif [[ "$node" == "{emmc_root}" ]]; then
            cat "{state_dir}/emmc_uuid"
            printf '\\n'
        fi
        ;;
    *"-s LABEL -o value"*)
        if [[ "$node" == "{sd_p1}" ]]; then
            printf 'rvdk_sd_root\\n'
        elif [[ "$node" == "{emmc_boot}" ]]; then
            printf 'armbi_boot\\n'
        elif [[ "$node" == "{emmc_root}" ]]; then
            cat "{state_dir}/emmc_label"
            printf '\\n'
        fi
        ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ $# -ge 2 ]]; then
    printf 'e2label %s\\n' "$*" >> "{ops_log}"
    printf '%s' "$2" > "{state_dir}/emmc_label"
    exit 0
fi
if [[ "${{1:-}}" == "{sd_p1}" ]]; then
    printf 'rvdk_sd_root\\n'
elif [[ "${{1:-}}" == "{emmc_root}" ]]; then
    cat "{state_dir}/emmc_label"
    printf '\\n'
fi
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-l" ]]; then
    printf 'Default mount options:    user_xattr acl\\n'
    exit 0
fi
printf 'tune2fs %s\\n' "$*" >> "{ops_log}"
if [[ "${{1:-}}" == "-U" ]]; then
    target_dev="${{3:-}}"
    if [[ -f "{mnt_map}/root.dev" && "$(cat "{mnt_map}/root.dev")" == "$target_dev" ]]; then
        echo "tune2fs: filesystem is mounted" >&2
        exit 1
    fi
    if [[ ! -f "{state_dir}/fsck_clean" ]]; then
        echo "Please run 'e2fsck -f $target_dev' first." >&2
        exit 1
    fi
    printf '%s' "${{2:-}}" > "{state_dir}/emmc_uuid"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2fsck",
            f"""#!/usr/bin/env bash
printf 'e2fsck %s\\n' "$*" >> "{ops_log}"
if [[ "$*" == *"-pf"* ]]; then
    touch "{state_dir}/fsck_clean"
fi
exit 0
""",
        )
        _write_exe(bin_dir / "uuidgen", f"#!/usr/bin/env bash\nprintf '%s\\n' '{new_uuid}'\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "mountpoint",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
if [[ -f "{mnt_map}/boot.tgt" && "$(cat "{mnt_map}/boot.tgt")" == "$tgt" ]]; then
    exit 0
fi
if [[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]]; then
    exit 0
fi
exit 1
""",
        )
        _write_exe(
            bin_dir / "mount",
            f"""#!/usr/bin/env bash
src="$1"
tgt="$2"
printf 'mount %s %s\\n' "$src" "$tgt" >> "{ops_log}"
if [[ "$src" == "{emmc_root}" ]]; then
    rm -f "{state_dir}/fsck_clean"
    cp -a "{peer_root_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/root.tgt"
    printf '%s' "$src" > "{mnt_map}/root.dev"
    exit 0
elif [[ "$src" == "{emmc_boot}" ]]; then
    if [[ "$(cat "{state_dir}/fail_boot_mount")" == "1" ]]; then
        exit 32
    fi
    [[ -d "$tgt" ]] || exit 1
    cp -a "{peer_boot_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/boot.tgt"
    printf '%s' "$src" > "{mnt_map}/boot.dev"
    exit 0
fi
exit 1
""",
        )
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
printf 'umount %s\\n' "$tgt" >> "{ops_log}"
if [[ -f "{mnt_map}/boot.tgt" && "$(cat "{mnt_map}/boot.tgt")" == "$tgt" ]]; then
    rm -rf "{peer_boot_backing}/"*
    cp -a "$tgt/." "{peer_boot_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/boot.tgt" "{mnt_map}/boot.dev"
    exit 0
fi
if [[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]]; then
    if [[ -f "{mnt_map}/boot.tgt" ]]; then
        echo "umount: target is busy (/boot still mounted)" >&2
        exit 1
    fi
    rm -rf "{peer_root_backing}/"*
    cp -a "$tgt/." "{peer_root_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/root.tgt" "{mnt_map}/root.dev"
    exit 0
fi
exit 1
""",
        )

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        cmd = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_bsp}"
rvdk_bsp_converge_mmc_root_labels
"""

        # 1. Separate /boot mount failure cleans up rootfs mount + tmpdir and performs ZERO superblock writes
        proc_boot_fail = _run_bash(cmd, env=env)
        assert proc_boot_fail.returncode == 0, proc_boot_fail.stderr
        assert "Failed to mount peer eMMC boot partition" in proc_boot_fail.stdout
        ops1 = ops_log.read_text(encoding="utf-8").splitlines()
        assert any(line.startswith(f"mount {emmc_root}") for line in ops1)
        assert any(line.startswith(f"mount {emmc_boot}") for line in ops1)
        assert any(line.startswith("umount ") for line in ops1)
        assert all(not line.startswith(("tune2fs ", "e2label ")) for line in ops1), ops1
        assert (state_dir / "emmc_uuid").read_text(encoding="utf-8") == old_uuid
        assert (state_dir / "emmc_label").read_text(encoding="utf-8") == "armbi_root"
        assert list(mnt_tmp.iterdir()) == []
        assert not (mnt_map / "root.tgt").exists()
        assert not (mnt_map / "boot.tgt").exists()

        # 2. Both rootfs and /boot mount succeed -> rewrite UUID= + LABEL= across /etc/fstab & /boot/*,
        #    sync, unmount /boot then rootfs, then mutate UUID + LABEL
        ops_log.unlink()
        (state_dir / "fail_boot_mount").write_text("0", encoding="utf-8")
        proc_ok = _run_bash(cmd, env=env)
        assert proc_ok.returncode == 0, proc_ok.stderr
        assert f"De-collided duplicate eMMC ext4 UUID on {emmc_root} -> {new_uuid}" in proc_ok.stdout
        assert f"Labeled eMMC ext4 rootfs: {emmc_root} -> rvdk_emmc_root" in proc_ok.stdout
        assert (state_dir / "emmc_uuid").read_text(encoding="utf-8") == new_uuid
        assert (state_dir / "emmc_label").read_text(encoding="utf-8") == "rvdk_emmc_root"
        assert list(mnt_tmp.iterdir()) == []

        ops2 = ops_log.read_text(encoding="utf-8").splitlines()
        # Pre-mount e2fsck -pf, mount root, mount /boot, umount /boot, umount root,
        # post-unmount e2fsck -pf, tune2fs -U, e2label
        assert len(ops2) == 8, ops2
        assert ops2[0] == f"e2fsck -pf {emmc_root}"
        assert ops2[1].startswith(f"mount {emmc_root} ")
        assert ops2[2].startswith(f"mount {emmc_boot} ") and ops2[2].endswith("/boot")
        assert ops2[3].startswith("umount ") and ops2[3].endswith("/boot")
        assert ops2[4].startswith("umount ") and not ops2[4].endswith("/boot")
        assert ops2[5] == f"e2fsck -pf {emmc_root}"
        assert ops2[6] == f"tune2fs -U {new_uuid} {emmc_root}"
        assert ops2[7] == f"e2label {emmc_root} rvdk_emmc_root"

        assert (peer_root_backing / "etc" / "fstab").read_text(encoding="utf-8") == (
            f"UUID={new_uuid}\t/\text4\tdefaults\t0\t1\n"
            "LABEL=rvdk_emmc_root\t/mnt/clone\text4\tro\t0\t2\n"
            "LABEL=armbi_root2\t/mnt/extra\text4\tdefaults\t0\t2\n"
        )
        assert (peer_boot_backing / "orangepiEnv.txt").read_text(encoding="utf-8") == (
            f"rootdev=UUID={new_uuid}\nrootfstype=ext4\n"
        )
        assert (peer_boot_backing / "armbianEnv.txt").read_text(encoding="utf-8") == (
            "rootdev=LABEL=rvdk_emmc_root\n"
        )
        assert (peer_boot_backing / "extlinux" / "extlinux.conf").read_text(encoding="utf-8") == (
            f'append="root=UUID={new_uuid} root=LABEL=rvdk_emmc_root rw"\n'
        )
        assert (peer_boot_backing / "spacemit" / "env_k1-x.txt").read_text(encoding="utf-8") == (
            f"root=LABEL=rvdk_emmc_root\nuuid={new_uuid}\n"
        )

        # 3. Converged re-run emits [SKIP] and performs zero mounts or superblock mutations
        ops_log.unlink()
        proc_skip = _run_bash(cmd, env=env)
        assert proc_skip.returncode == 0, proc_skip.stderr
        assert "[SKIP]" in proc_skip.stdout
        assert "[OK]" not in proc_skip.stdout
        assert not ops_log.exists()

    def test_peer_symlink_escape_aborts_cleanly_and_allows_in_tree_relative_symlinks(
        self, tmp_path: Path
    ) -> None:
        patched_bsp, sys_block, dev_dir, mnt_tmp, bin_dir, _ = self._prepare_bsp_harness(tmp_path)
        self._add_mmc_node(sys_block, dev_dir, "mmcblk0", "SD", ["mmcblk0p1"])
        self._add_mmc_node(sys_block, dev_dir, "mmcblk2", "MMC", ["mmcblk2p1", "mmcblk2p2"])

        sd_p1 = dev_dir / "mmcblk0p1"
        emmc_boot = dev_dir / "mmcblk2p1"
        emmc_root = dev_dir / "mmcblk2p2"
        old_uuid = "11111111-2222-3333-4444-555555555555"
        new_uuid = "22222222-3333-4444-5555-666666666666"

        host_etc = tmp_path / "host_etc"
        host_etc.mkdir()
        host_fstab = host_etc / "fstab"
        host_fstab_orig = f"UUID={old_uuid}\t/\text4\tdefaults\t0\t1\n"
        host_fstab.write_text(host_fstab_orig, encoding="utf-8")

        host_boot = tmp_path / "host_boot"
        host_boot.mkdir()
        host_env = host_boot / "orangepiEnv.txt"
        host_env_orig = f"rootdev=UUID={old_uuid}\n"
        host_env.write_text(host_env_orig, encoding="utf-8")

        peer_root_backing = tmp_path / "peer_root_backing"
        peer_root_backing.mkdir()
        (peer_root_backing / "etc").mkdir()
        (peer_root_backing / "etc" / "fstab").write_text(f"UUID={old_uuid}\t/\text4\tdefaults\t0\t1\n", encoding="utf-8")
        # Escaping symlink on peer rootfs: boot -> live host /boot
        (peer_root_backing / "boot").symlink_to(host_boot)

        state_dir = tmp_path / "state"
        state_dir.mkdir()
        (state_dir / "has_boot_part").write_text("1", encoding="utf-8")
        (state_dir / "emmc_uuid").write_text(old_uuid, encoding="utf-8")
        (state_dir / "emmc_label").write_text("armbi_root", encoding="utf-8")
        ops_log = tmp_path / "ops.log"
        mnt_map = tmp_path / "mnt_map"
        mnt_map.mkdir()

        _write_exe(
            bin_dir / "findmnt",
            f'#!/usr/bin/env bash\nif [[ "$*" == *"-n -o SOURCE /"* ]]; then printf "%s\\n" "{sd_p1}"; fi\nexit 0\n',
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"{dev_dir}/mmcblk2"* ]]; then
    lbl="$(cat "{state_dir}/emmc_label")"
    printf 'PATH="%s" TYPE="disk" FSTYPE="" SIZE="16000000000" LABEL=""\\n' "{dev_dir}/mmcblk2"
    if [[ "$(cat "{state_dir}/has_boot_part")" == "1" ]]; then
        printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="134217728" LABEL="armbi_boot"\\n' "{emmc_boot}"
    fi
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="15000000000" LABEL="%s"\\n' "{emmc_root}" "$lbl"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
case "$*" in
    *"-s TYPE -o value"*) printf 'ext4\\n' ;;
    *"-s UUID -o value"*)
        if [[ "$node" == "{sd_p1}" ]]; then
            printf '%s\\n' "{old_uuid}"
        elif [[ "$node" == "{emmc_root}" ]]; then
            cat "{state_dir}/emmc_uuid"; printf '\\n'
        fi
        ;;
    *"-s LABEL -o value"*)
        if [[ "$node" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'
        elif [[ "$node" == "{emmc_boot}" ]]; then printf 'armbi_boot\\n'
        elif [[ "$node" == "{emmc_root}" ]]; then cat "{state_dir}/emmc_label"; printf '\\n'
        fi
        ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ $# -ge 2 ]]; then
    printf 'e2label %s\\n' "$*" >> "{ops_log}"
    printf '%s' "$2" > "{state_dir}/emmc_label"
    exit 0
fi
if [[ "${{1:-}}" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'; else cat "{state_dir}/emmc_label"; printf '\\n'; fi
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-l" ]]; then printf 'Default mount options:    user_xattr acl\\n'; exit 0; fi
printf 'tune2fs %s\\n' "$*" >> "{ops_log}"
if [[ "${{1:-}}" == "-U" ]]; then printf '%s' "${{2:-}}" > "{state_dir}/emmc_uuid"; fi
exit 0
""",
        )
        _write_exe(bin_dir / "e2fsck", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "uuidgen", f"#!/usr/bin/env bash\nprintf '%s\\n' '{new_uuid}'\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "mountpoint",
            f'#!/usr/bin/env bash\ntgt="${{@: -1}}"\n[[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]]\n',
        )
        _write_exe(
            bin_dir / "mount",
            f"""#!/usr/bin/env bash
src="$1"; tgt="$2"
printf 'mount %s %s\\n' "$src" "$tgt" >> "{ops_log}"
if [[ "$src" == "{emmc_root}" ]]; then
    cp -a "{peer_root_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/root.tgt"
    exit 0
fi
exit 1
""",
        )
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
printf 'umount %s\\n' "$tgt" >> "{ops_log}"
if [[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]]; then
    rm -rf "{peer_root_backing}/"*
    cp -a "$tgt/." "{peer_root_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/root.tgt"
    exit 0
fi
exit 1
""",
        )

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        cmd = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_bsp}"
rvdk_bsp_converge_mmc_root_labels
"""

        # Case A: boot -> host_boot symlink refused BEFORE mounting boot_slice
        proc_boot_sym = _run_bash(cmd, env=env)
        assert proc_boot_sym.returncode == 0, proc_boot_sym.stderr
        assert "[WARN]" in proc_boot_sym.stdout
        assert host_env.read_text(encoding="utf-8") == host_env_orig
        ops_a = ops_log.read_text(encoding="utf-8").splitlines()
        assert all(emmc_boot.name not in line for line in ops_a), ops_a
        assert all(not line.startswith(("tune2fs ", "e2label ")) for line in ops_a), ops_a
        assert list(mnt_tmp.iterdir()) == []

        # Case B: single-partition peer with etc -> host_etc symlink aborts cleanly
        ops_log.unlink()
        (state_dir / "has_boot_part").write_text("0", encoding="utf-8")
        (peer_root_backing / "boot").unlink()
        (peer_root_backing / "boot").mkdir()
        shutil.rmtree(peer_root_backing / "etc")
        (peer_root_backing / "etc").symlink_to(host_etc)
        proc_etc_sym = _run_bash(cmd, env=env)
        assert proc_etc_sym.returncode == 0, proc_etc_sym.stderr
        assert "[WARN]" in proc_etc_sym.stdout
        assert host_fstab.read_text(encoding="utf-8") == host_fstab_orig
        ops_b = ops_log.read_text(encoding="utf-8").splitlines()
        assert all(not line.startswith(("tune2fs ", "e2label ")) for line in ops_b), ops_b
        assert list(mnt_tmp.iterdir()) == []

        # Case C: legitimate in-tree relative symlink (boot/boot -> .) is allowed and rewritten
        ops_log.unlink()
        (peer_root_backing / "etc").unlink()
        (peer_root_backing / "etc").mkdir()
        (peer_root_backing / "etc" / "fstab").write_text(host_fstab_orig, encoding="utf-8")
        (peer_root_backing / "boot" / "extlinux").mkdir(parents=True)
        (peer_root_backing / "boot" / "extlinux" / "extlinux.conf").write_text(
            f"append root=UUID={old_uuid} root=LABEL=armbi_root\n", encoding="utf-8"
        )
        (peer_root_backing / "boot" / "boot").symlink_to(".")
        proc_rel_ok = _run_bash(cmd, env=env)
        assert proc_rel_ok.returncode == 0, proc_rel_ok.stderr
        assert "[WARN]" not in proc_rel_ok.stdout
        assert (peer_root_backing / "boot" / "extlinux" / "extlinux.conf").read_text(encoding="utf-8") == (
            f"append root=UUID={new_uuid} root=LABEL=rvdk_emmc_root\n"
        )
        assert (state_dir / "emmc_uuid").read_text(encoding="utf-8") == new_uuid
        assert (state_dir / "emmc_label").read_text(encoding="utf-8") == "rvdk_emmc_root"

    def test_corrupt_peer_e2fsck_rc4_aborts_without_mount_tune2fs_or_e2label(
        self, tmp_path: Path
    ) -> None:
        patched_bsp, sys_block, dev_dir, mnt_tmp, bin_dir, _ = self._prepare_bsp_harness(tmp_path)
        self._add_mmc_node(sys_block, dev_dir, "mmcblk0", "SD", ["mmcblk0p1"])
        self._add_mmc_node(sys_block, dev_dir, "mmcblk2", "MMC", ["mmcblk2p1"])

        sd_p1 = dev_dir / "mmcblk0p1"
        emmc_p1 = dev_dir / "mmcblk2p1"
        shared_uuid = "11111111-2222-3333-4444-555555555555"
        ops_log = tmp_path / "ops.log"

        _write_exe(
            bin_dir / "findmnt",
            f'#!/usr/bin/env bash\nif [[ "$*" == *"-n -o SOURCE /"* ]]; then printf "%s\\n" "{sd_p1}"; fi\nexit 0\n',
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"{dev_dir}/mmcblk2"* ]]; then
    printf 'PATH="%s" TYPE="disk" FSTYPE="" SIZE="16000000000" LABEL=""\\n' "{dev_dir}/mmcblk2"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="15000000000" LABEL="armbi_root"\\n' "{emmc_p1}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
case "$*" in
    *"-s TYPE -o value"*) printf 'ext4\\n' ;;
    *"-s UUID -o value"*) printf '%s\\n' "{shared_uuid}" ;;
    *"-s LABEL -o value"*) if [[ "$node" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'; else printf 'armbi_root\\n'; fi ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ $# -ge 2 ]]; then printf 'e2label %s\\n' "$*" >> "{ops_log}"; exit 0; fi
if [[ "${{1:-}}" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'; else printf 'armbi_root\\n'; fi
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-l" ]]; then printf 'Default mount options:    user_xattr acl\\n'; exit 0; fi
printf 'tune2fs %s\\n' "$*" >> "{ops_log}"
exit 0
""",
        )
        _write_exe(bin_dir / "e2fsck", "#!/usr/bin/env bash\nexit 4\n")
        _write_exe(bin_dir / "mount", f'#!/usr/bin/env bash\nprintf "mount %s\\n" "$*" >> "{ops_log}"\nexit 0\n')
        _write_exe(bin_dir / "umount", f'#!/usr/bin/env bash\nprintf "umount %s\\n" "$*" >> "{ops_log}"\nexit 0\n')
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_bsp}"
rvdk_bsp_converge_mmc_root_labels
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, proc.stderr
        assert "[WARN]" in proc.stdout
        assert "e2fsck returned 4" in proc.stdout
        assert not ops_log.exists()
        assert list(mnt_tmp.iterdir()) == []


class TestRv2FlashEmmcAndMediaJson:
    @pytest.mark.parametrize(
        "bad_args",
        [
            ["--device"],
            ["-d"],
            ["--device", "-n"],
            ["--root-label"],
            ["--root-label", "--yes"],
            ["--hostname"],
            ["--hostname", "--dry-run"],
            ["--root-label", ""],
        ],
    )
    def test_flash_emmc_missing_or_flag_option_args_rejected(self, bad_args: list[str]) -> None:
        emmc_script = REPO_ROOT / "boards" / "orangepi" / "rv2" / "flash-emmc.sh"
        proc = subprocess.run(
            [BASH_BIN, str(emmc_script), *bad_args],
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode != 0
        assert "requires an argument" in proc.stderr
        assert "shift count out of range" not in proc.stderr

    @pytest.mark.parametrize("use_register_cleanup", [True, False])
    @pytest.mark.parametrize(
        ("sig", "expected_rc"),
        [
            (signal.SIGTERM, 143),
            (signal.SIGINT, 130),
        ],
    )
    def test_flash_emmc_signal_cleanup_runs_once(
        self,
        tmp_path: Path,
        use_register_cleanup: bool,
        sig: signal.Signals,
        expected_rc: int,
    ) -> None:
        dev_dir = tmp_path / "dev"
        dev_dir.mkdir()
        sd_root = dev_dir / "mmcblk0p1"
        emmc_dev = dev_dir / "mmcblk2"
        emmc_p1 = dev_dir / "mmcblk2p1"
        emmc_boot0 = dev_dir / "mmcblk2boot0"
        for node in (sd_root, emmc_dev, emmc_p1, emmc_boot0):
            node.write_text("", encoding="utf-8")

        uboot_dir = tmp_path / "uboot"
        uboot_dir.mkdir()
        for fn in ("bootinfo_emmc.bin", "bootinfo_sd.bin", "FSBL.bin", "u-boot-opensbi.itb"):
            (uboot_dir / fn).write_bytes(b"uboot")

        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        systemctl_log = tmp_path / "systemctl.log"
        umount_log = tmp_path / "umount.log"
        _write_exe(
            bin_dir / "findmnt",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-n -o SOURCE /"* && "$*" != *"/boot"* && "$*" != *"/usr"* && "$*" != *"/var"* && "$*" != *"/home"* && "$*" != *"/etc"* && "$*" != *"/opt"* && "$*" != *"/root"* && "$*" != *"/srv"* ]]; then
    printf '%s\\n' "{sd_root}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-rn -o PATH,TYPE"*) printf '%s disk\\n%s part\\n' "{emmc_dev}" "{emmc_p1}" ;;
    *"-no PKNAME"*) printf 'mmcblk0\\n' ;;
    *"-dn -o TYPE"*) printf 'disk\\n' ;;
    *"-b -dn -o SIZE"*) printf '16000000000\\n' ;;
    *"-dn -o SIZE"*) printf '16G\\n' ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
if [[ "$*" == *"-s UUID -o value"* ]]; then
    if [[ "$node" == "{sd_root}" ]]; then
        printf '11111111-2222-3333-4444-555555555555\\n'
    else
        printf '22222222-3333-4444-5555-666666666666\\n'
    fi
elif [[ "$*" == *"-s LABEL -o value"* ]]; then
    printf 'rvdk_emmc_root\\n'
fi
exit 0
""",
        )
        _write_exe(bin_dir / "df", "#!/usr/bin/env bash\nprintf 'Filesystem 1M-blocks Used\\n/dev/root 8000 500\\n'\n")
        mnt_tmp = tmp_path / "mnt_tmp"
        mnt_tmp.mkdir()
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{umount_log}"
tgt="${{@: -1}}"
if [[ "$tgt" == *"/rvdk_rv2_emmc."* && -d "$tgt" ]]; then
    rm -rf "$tgt/"*
fi
exit 0
""",
        )
        _write_exe(bin_dir / "mountpoint", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "systemctl", f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{systemctl_log}"\nexit 0\n')
        for cmd in ("partprobe", "blockdev", "udevadm", "wipefs", "parted", "dd", "mkfs.ext4", "e2label", "mount", "sync", "rsync"):
            _write_exe(bin_dir / cmd, "#!/usr/bin/env bash\nexit 0\n")

        cleanup_count_log = tmp_path / "cleanup_count.log"
        pid_file = tmp_path / "emmc.pid"
        boot0_ro_file = tmp_path / "force_ro"
        boot0_ro_file.write_text("0\n", encoding="utf-8")

        rvdk_ci = _load_rvdk_ci()
        emmc_src = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "boards" / "orangepi" / "rv2" / "flash-emmc.sh").read_text(encoding="utf-8"),
            REPO_ROOT,
        )
        if not use_register_cleanup:
            emmc_src = emmc_src.replace(
                "if typeset -f rvdk_register_cleanup >/dev/null 2>&1; then",
                "if false; then",
            )

        pause_stub = (
            f'_EMMC_BOOT0_RO_UNLOCKED="{boot0_ro_file}"\n'
            '_STOPPED_SVCS=("postgresql.service")\n'
            f'printf "%s\\n" "$$" > "{pid_file}"\n'
            "sleep 30 >/dev/null 2>&1 &\n"
            "_wait_pid=$!\n"
            'wait "$_wait_pid"'
        )
        emmc_patched = tmp_path / "flash_emmc_sig.sh"
        emmc_text = (
            emmc_src.replace(
                'rvdk_require_root "${BASH_SOURCE[0]:-}" ${orig_args[@]+"${orig_args[@]}"}',
                "true",
                1,
            )
            .replace('! -b "$live_root"', '! -e "$live_root"')
            .replace('! -b "$target_dev"', '! -e "$target_dev"')
            .replace('! -b "$emmc_part"', '! -e "$emmc_part"')
            .replace("/usr/lib/u-boot/platform_install.sh", str(tmp_path / "no_platform_install.sh"))
            .replace("/usr/lib/linux-u-boot-*", str(uboot_dir))
            .replace("/etc/fstab", str(tmp_path / "no_fstab"))
            .replace("/tmp/rvdk_rv2_emmc.XXXXXX", f"{mnt_tmp}/rvdk_rv2_emmc.XXXXXX")
            .replace(
                '_rvdk_emmc_cleanup() {\n',
                f'_rvdk_emmc_cleanup() {{\n    echo "called" >> "{cleanup_count_log}"\n',
                1,
            )
            .replace(
                'rsync -aHAX --numeric-ids --delete "${rsync_excludes[@]}" / "${_EMMC_TMP_MNT}/"',
                pause_stub,
                1,
            )
        )
        emmc_patched.write_text(emmc_text, encoding="utf-8")
        emmc_patched.chmod(0o755)

        proc = subprocess.Popen(
            [BASH_BIN, "-c", '"$1" "$2" --force -y "$3"; exit $?', "_", BASH_BIN, str(emmc_patched), str(emmc_dev)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        try:
            deadline = time.monotonic() + 5.0
            while not pid_file.exists() or not pid_file.read_text(encoding="utf-8").strip():
                if proc.poll() is not None:
                    out, err = proc.communicate(timeout=2.0)
                    raise AssertionError(
                        f"flash-emmc.sh exited early (rc={proc.returncode}):\nstdout={out}\nstderr={err}"
                    )
                assert time.monotonic() < deadline, "Timed out waiting for flash-emmc.sh PID"
                time.sleep(0.02)
            child_pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(child_pid, sig)
            _, stderr = proc.communicate(timeout=5.0)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        assert proc.returncode == expected_rc, stderr
        assert cleanup_count_log.read_text(encoding="utf-8").splitlines() == ["called"]
        assert boot0_ro_file.read_text(encoding="utf-8") == "1\n"
        assert "start postgresql.service" in systemctl_log.read_text(encoding="utf-8").splitlines()
        rv2_umounts = [line for line in umount_log.read_text(encoding="utf-8").splitlines() if "rvdk_rv2_emmc." in line]
        assert len(rv2_umounts) == 1
        assert not Path(rv2_umounts[0]).exists()

    def test_rv2_media_json_aligned_with_debian_trixie_image(self) -> None:
        manifest_path = REPO_ROOT / "boards" / "orangepi" / "rv2" / "media.json"
        doc = json.loads(manifest_path.read_text(encoding="utf-8"))
        assert doc["schema_version"] == 1
        assert doc["default_os"] == "debian-13"
        sd = doc["media"]["sd"]
        assert "trixie" in sd["image"].lower()
        assert "trixie" in sd["description"].lower()



class TestPhase5FlashAndStorageRegressions:
    def test_bsp_converge_rolls_back_configs_when_tune2fs_fails(self, tmp_path: Path) -> None:
        helper = TestBspConvergeMmcPeerSafety()
        patched_bsp, sys_block, dev_dir, mnt_tmp, bin_dir, _ = helper._prepare_bsp_harness(tmp_path)
        helper._add_mmc_node(sys_block, dev_dir, "mmcblk0", "SD", ["mmcblk0p1"])
        helper._add_mmc_node(sys_block, dev_dir, "mmcblk2", "MMC", ["mmcblk2p1", "mmcblk2p2"])

        sd_p1 = dev_dir / "mmcblk0p1"
        emmc_boot = dev_dir / "mmcblk2p1"
        emmc_root = dev_dir / "mmcblk2p2"
        old_uuid = "11111111-2222-3333-4444-555555555555"
        new_uuid = "22222222-3333-4444-5555-666666666666"

        peer_root_backing = tmp_path / "peer_root"
        (peer_root_backing / "etc").mkdir(parents=True)
        (peer_root_backing / "boot").mkdir(parents=True)
        orig_fstab = f"UUID={old_uuid}\t/\text4\tdefaults\t0\t1\nLABEL=armbi_root\t/mnt/clone\text4\tro\t0\t2\n"
        (peer_root_backing / "etc" / "fstab").write_text(orig_fstab, encoding="utf-8")

        peer_boot_backing = tmp_path / "peer_boot"
        peer_boot_backing.mkdir()
        orig_env = f"rootdev=UUID={old_uuid}\nrootfstype=ext4\n"
        (peer_boot_backing / "orangepiEnv.txt").write_text(orig_env, encoding="utf-8")

        mnt_map = tmp_path / "mnt_map"
        mnt_map.mkdir()
        ops_log = tmp_path / "ops.log"

        _write_exe(
            bin_dir / "findmnt",
            f'#!/usr/bin/env bash\nif [[ "$*" == *"-n -o SOURCE /"* ]]; then printf "%s\\n" "{sd_p1}"; fi\nexit 0\n',
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"{dev_dir}/mmcblk2"* ]]; then
    printf 'PATH="%s" TYPE="disk" FSTYPE="" SIZE="16000000000" LABEL=""\\n' "{dev_dir}/mmcblk2"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="134217728" LABEL="armbi_boot"\\n' "{emmc_boot}"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="15000000000" LABEL="armbi_root"\\n' "{emmc_root}"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
case "$*" in
    *"-s TYPE -o value"*) printf 'ext4\\n' ;;
    *"-s UUID -o value"*) printf '%s\\n' "{old_uuid}" ;;
    *"-s LABEL -o value"*)
        if [[ "$node" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'
        elif [[ "$node" == "{emmc_boot}" ]]; then printf 'armbi_boot\\n'
        else printf 'armbi_root\\n'
        fi
        ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ $# -ge 2 ]]; then printf 'e2label %s\\n' "$*" >> "{ops_log}"; exit 0; fi
if [[ "${{1:-}}" == "{sd_p1}" ]]; then printf 'rvdk_sd_root\\n'; else printf 'armbi_root\\n'; fi
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-l" ]]; then printf 'Default mount options:    user_xattr acl\\n'; exit 0; fi
printf 'tune2fs %s\\n' "$*" >> "{ops_log}"
exit 1
""",
        )
        _write_exe(bin_dir / "e2fsck", f'#!/usr/bin/env bash\nprintf "e2fsck %s\\n" "$*" >> "{ops_log}"\nexit 0\n')
        _write_exe(bin_dir / "uuidgen", f"#!/usr/bin/env bash\nprintf '%s\\n' '{new_uuid}'\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "mountpoint",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
[[ -f "{mnt_map}/boot.tgt" && "$(cat "{mnt_map}/boot.tgt")" == "$tgt" ]] && exit 0
[[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]] && exit 0
exit 1
""",
        )
        _write_exe(
            bin_dir / "mount",
            f"""#!/usr/bin/env bash
src="$1"; tgt="$2"
printf 'mount %s %s\\n' "$src" "$tgt" >> "{ops_log}"
if [[ "$src" == "{emmc_root}" ]]; then
    cp -a "{peer_root_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/root.tgt"
    exit 0
elif [[ "$src" == "{emmc_boot}" ]]; then
    cp -a "{peer_boot_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/boot.tgt"
    exit 0
fi
exit 1
""",
        )
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
printf 'umount %s\\n' "$tgt" >> "{ops_log}"
if [[ -f "{mnt_map}/boot.tgt" && "$(cat "{mnt_map}/boot.tgt")" == "$tgt" ]]; then
    rm -rf "{peer_boot_backing}/"*
    cp -a "$tgt/." "{peer_boot_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/boot.tgt"
    exit 0
fi
if [[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]]; then
    rm -rf "{peer_root_backing}/"*
    cp -a "$tgt/." "{peer_root_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/root.tgt"
    exit 0
fi
exit 1
""",
        )

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{patched_bsp}"
rvdk_bsp_converge_mmc_root_labels
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode != 0
        assert "tune2fs -U failed" in proc.stderr
        assert (peer_root_backing / "etc" / "fstab").read_text(encoding="utf-8") == orig_fstab
        assert (peer_boot_backing / "orangepiEnv.txt").read_text(encoding="utf-8") == orig_env
        assert list(mnt_tmp.iterdir()) == []
        ops = ops_log.read_text(encoding="utf-8").splitlines()
        assert all(not line.startswith("e2label ") for line in ops), ops

    def test_flash_postprocess_raw_ordering_boot_fail_symlink_and_rollback(self, tmp_path: Path) -> None:
        dev_dir = tmp_path / "dev"
        dev_dir.mkdir()
        mmc1 = dev_dir / "mmcblk1"
        mmc1p1 = dev_dir / "mmcblk1p1"  # boot
        mmc1p2 = dev_dir / "mmcblk1p2"  # root
        mmc2p2 = dev_dir / "mmcblk2p2"  # colliding peer
        for node in (mmc1, mmc1p1, mmc1p2, mmc2p2):
            node.write_text("", encoding="utf-8")

        old_uuid = "11111111-2222-3333-4444-555555555555"
        new_uuid = "22222222-3333-4444-5555-666666666666"

        root_backing = tmp_path / "root_backing"
        (root_backing / "etc").mkdir(parents=True)
        (root_backing / "boot" / "boot" / "extlinux").mkdir(parents=True)
        boot_backing = tmp_path / "boot_backing"
        (boot_backing / "boot" / "extlinux").mkdir(parents=True)

        orig_fstab = f"UUID={old_uuid}\t/\text4\tdefaults\t0\t1\n"
        orig_uenv = f"root=UUID={old_uuid}\n"
        orig_extlinux = f"append root=UUID={old_uuid} rw\n"
        (root_backing / "etc" / "fstab").write_text(orig_fstab, encoding="utf-8")
        (boot_backing / "uEnv.txt").write_text(orig_uenv, encoding="utf-8")
        (boot_backing / "boot" / "extlinux" / "extlinux.conf").write_text(orig_extlinux, encoding="utf-8")

        state_dir = tmp_path / "state"
        state_dir.mkdir()
        (state_dir / "fail_boot_mount").write_text("1", encoding="utf-8")
        (state_dir / "fail_tune2fs").write_text("0", encoding="utf-8")
        mnt_map = tmp_path / "mnt_map"
        mnt_map.mkdir()
        ops_log = tmp_path / "ops.log"
        mnt_tmp = tmp_path / "mnt_tmp"
        mnt_tmp.mkdir()

        flash_src = (REPO_ROOT / "lib" / "flash.sh").read_text(encoding="utf-8")
        patched_flash = tmp_path / "flash_postproc_test.sh"
        patched_flash.write_text(
            flash_src.replace('[[ -b "$root_slice" ]]', '[[ -e "$root_slice" ]]')
            .replace('[[ -b "$boot_slice" ]]', '[[ -e "$boot_slice" ]]')
            .replace('[[ -n "$lp_path" && -b "$lp_path" ]]', '[[ -n "$lp_path" && -e "$lp_path" ]]')
            .replace('[[ -n "$cand" && -b "$cand" ]]', '[[ -n "$cand" && -e "$cand" ]]')
            .replace('[[ -b "$p" ]]', '[[ -e "$p" ]]')
            .replace("/tmp/rvdk_postflash.XXXXXX", f"{mnt_tmp}/rvdk_postflash.XXXXXX")
            .replace('source "${_FLASH_LIB_DIR}/common.sh"', f'source "{REPO_ROOT}/lib/common.sh"')
            .replace('source "${_FLASH_LIB_DIR}/storage_guard.sh"', f'source "{REPO_ROOT}/lib/storage_guard.sh"'),
            encoding="utf-8",
        )

        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        _write_exe(bin_dir / "sudo", '#!/usr/bin/env bash\nexec "$@"\n')
        _write_exe(bin_dir / "partprobe", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "udevadm", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "uuidgen", f"#!/usr/bin/env bash\nprintf '%s\\n' '{new_uuid}'\n")
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
if [[ "$*" == *"-P -n -o PATH,TYPE,FSTYPE,SIZE"* ]]; then
    printf 'PATH="%s" TYPE="disk" FSTYPE="" SIZE="16000000000"\\n' "{mmc1}"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="134217728"\\n' "{mmc1p1}"
    printf 'PATH="%s" TYPE="part" FSTYPE="ext4" SIZE="15000000000"\\n' "{mmc1p2}"
    exit 0
fi
if [[ "$*" == *"-rn -o PATH,TYPE"* ]]; then
    printf '%s disk\\n%s part\\n%s part\\n' "{mmc1}" "{mmc1p1}" "{mmc1p2}"
    exit 0
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
case "$*" in
    *"-s UUID -o value"*) printf '%s\\n' "{old_uuid}" ;;
    *"-s LABEL -o value"*)
        if [[ "$node" == "{mmc1p1}" ]]; then
            printf 'armbi_boot\\n'
        else
            printf 'armbi_root\\n'
        fi
        ;;
    *"-t UUID={old_uuid} -o device"*) printf '%s\\n%s\\n' "{mmc1p2}" "{mmc2p2}" ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ "$#" -ge 2 ]]; then
    printf '%s' "$2" > "{state_dir}/cur_label"
elif [[ -f "{state_dir}/cur_label" ]]; then
    cat "{state_dir}/cur_label"
    printf '\\n'
else
    printf 'armbi_root\\n'
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "e2fsck",
            f"""#!/usr/bin/env bash
printf 'e2fsck %s\\n' "$*" >> "{ops_log}"
if [[ "$*" == *"-pf"* ]]; then
    touch "{state_dir}/fsck_clean"
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "tune2fs",
            f"""#!/usr/bin/env bash
if [[ "${{1:-}}" == "-l" ]]; then
    dev="${{2:-}}"
    if [[ "$dev" == "{mmc1p1}" ]]; then
        printf 'Filesystem magic number:  0xEF53\\nFilesystem volume name:   armbi_boot\\nBlock count:              32768\\nBlock size:               4096\\nFilesystem features:      has_journal metadata_csum\\n'
    else
        printf 'Filesystem magic number:  0xEF53\\nFilesystem volume name:   armbi_root\\nBlock count:              1048576\\nBlock size:               4096\\nFilesystem features:      has_journal metadata_csum\\n'
    fi
    exit 0
fi
printf 'tune2fs %s\\n' "$*" >> "{ops_log}"
if [[ "${{1:-}}" == "-U" ]]; then
    if [[ "$(cat "{state_dir}/fail_tune2fs")" == "1" ]]; then
        exit 1
    fi
    if [[ ! -f "{state_dir}/fsck_clean" ]]; then
        echo "Please run e2fsck -f first." >&2
        exit 1
    fi
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "mountpoint",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
[[ -f "{mnt_map}/boot.tgt" && "$(cat "{mnt_map}/boot.tgt")" == "$tgt" ]] && exit 0
[[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]] && exit 0
exit 1
""",
        )
        _write_exe(
            bin_dir / "mount",
            f"""#!/usr/bin/env bash
src="$1"; tgt="$2"
printf 'mount %s %s\\n' "$src" "$tgt" >> "{ops_log}"
if [[ "$src" == "{mmc1p2}" ]]; then
    rm -f "{state_dir}/fsck_clean"
    cp -a "{root_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/root.tgt"
    exit 0
elif [[ "$src" == "{mmc1p1}" ]]; then
    if [[ "$(cat "{state_dir}/fail_boot_mount")" == "1" ]]; then
        exit 32
    fi
    cp -a "{boot_backing}/." "$tgt/"
    printf '%s' "$tgt" > "{mnt_map}/boot.tgt"
    exit 0
fi
exit 1
""",
        )
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
printf 'umount %s\\n' "$tgt" >> "{ops_log}"
if [[ -f "{mnt_map}/boot.tgt" && "$(cat "{mnt_map}/boot.tgt")" == "$tgt" ]]; then
    rm -rf "{boot_backing}/"*
    cp -a "$tgt/." "{boot_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/boot.tgt"
    exit 0
fi
if [[ -f "{mnt_map}/root.tgt" && "$(cat "{mnt_map}/root.tgt")" == "$tgt" ]]; then
    rm -rf "{root_backing}/"*
    cp -a "$tgt/." "{root_backing}/"
    rm -rf "$tgt/"*
    rm -f "{mnt_map}/root.tgt"
    exit 0
fi
exit 0
""",
        )

        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        run_cmd = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
source "{REPO_ROOT}/lib/storage_guard.sh"
source "{patched_flash}"
_rvdk_flash_postprocess_raw "Linux" "{mmc1}" "2" "rvdk_sd_root" "false" "false" "riscv64"
"""

        # 1. /boot mount failure must be fatal and perform ZERO tune2fs -U calls
        p_boot_fail = _run_bash(run_cmd, env=env)
        assert p_boot_fail.returncode != 0
        assert "Failed to mount separate /boot partition" in p_boot_fail.stderr
        ops_fail = ops_log.read_text(encoding="utf-8").splitlines()
        assert all(not line.startswith("tune2fs -U") for line in ops_fail), ops_fail

        # 2. Symlinked boot/uEnv.txt is never followed and parent-dir symlink escaping mount root aborts before tune2fs -U
        ops_log.unlink()
        (state_dir / "fail_boot_mount").write_text("0", encoding="utf-8")
        outside_uenv = tmp_path / "outside_uEnv.txt"
        outside_uenv.write_text(orig_uenv, encoding="utf-8")
        (boot_backing / "uEnv.txt").unlink()
        (boot_backing / "uEnv.txt").symlink_to(outside_uenv)
        outside_ext_dir = tmp_path / "outside_extlinux"
        outside_ext_dir.mkdir()
        (outside_ext_dir / "extlinux.conf").write_text(orig_extlinux, encoding="utf-8")
        shutil.rmtree(boot_backing / "boot" / "extlinux")
        (boot_backing / "boot" / "extlinux").symlink_to(outside_ext_dir)
        p_sym = _run_bash(run_cmd, env=env)
        assert p_sym.returncode != 0
        assert "Failed to update target boot configuration files" in p_sym.stderr
        assert outside_uenv.read_text(encoding="utf-8") == orig_uenv
        assert (outside_ext_dir / "extlinux.conf").read_text(encoding="utf-8") == orig_extlinux
        ops_sym = ops_log.read_text(encoding="utf-8").splitlines()
        assert all(not line.startswith("tune2fs -U") for line in ops_sym), ops_sym

        # 3. tune2fs -U failure rolls back rewritten fstab, uEnv.txt, and boot/extlinux/extlinux.conf
        ops_log.unlink()
        (boot_backing / "uEnv.txt").unlink()
        (boot_backing / "uEnv.txt").write_text(orig_uenv, encoding="utf-8")
        ext_path = boot_backing / "boot" / "extlinux"
        if ext_path.is_symlink() or ext_path.is_file():
            ext_path.unlink()
        elif ext_path.is_dir():
            shutil.rmtree(ext_path)
        ext_path.mkdir(parents=True)
        (boot_backing / "boot" / "extlinux" / "extlinux.conf").write_text(orig_extlinux, encoding="utf-8")
        (state_dir / "fail_tune2fs").write_text("1", encoding="utf-8")
        p_rb = _run_bash(run_cmd, env=env)
        assert p_rb.returncode != 0
        assert (root_backing / "etc" / "fstab").read_text(encoding="utf-8") == orig_fstab
        assert (boot_backing / "uEnv.txt").read_text(encoding="utf-8") == orig_uenv
        assert (boot_backing / "boot" / "extlinux" / "extlinux.conf").read_text(encoding="utf-8") == orig_extlinux

        # 4. Happy path: rewrites fstab, uEnv.txt, boot/extlinux/extlinux.conf; runs e2fsck -pf post-unmount before tune2fs -U
        ops_log.unlink()
        (state_dir / "fail_tune2fs").write_text("0", encoding="utf-8")
        p_ok = _run_bash(run_cmd, env=env)
        assert p_ok.returncode == 0, p_ok.stderr
        assert (root_backing / "etc" / "fstab").read_text(encoding="utf-8") == f"UUID={new_uuid}\t/\text4\tdefaults\t0\t1\n"
        assert (boot_backing / "uEnv.txt").read_text(encoding="utf-8") == f"root=UUID={new_uuid}\n"
        assert (boot_backing / "boot" / "extlinux" / "extlinux.conf").read_text(encoding="utf-8") == f"append root=UUID={new_uuid} rw\n"
        ops_ok = ops_log.read_text(encoding="utf-8").splitlines()
        tune_idx = max(i for i, line in enumerate(ops_ok) if line == f"tune2fs -U {new_uuid} {mmc1p2}")
        mount_idx = max(i for i, line in enumerate(ops_ok[:tune_idx]) if line.startswith(f"mount {mmc1p2} "))
        umount_idx = max(i for i, line in enumerate(ops_ok[:tune_idx]) if line.startswith("umount ") and "rvdk_postflash" in line)
        fsck_idx = max(i for i, line in enumerate(ops_ok[:tune_idx]) if line == f"e2fsck -pf {mmc1p2}")
        assert mount_idx < umount_idx < fsck_idx < tune_idx, ops_ok

    def test_esp32p4_linux_flash_sd_vfat_rejects_cp_preserve(self, tmp_path: Path) -> None:
        dev_dir = tmp_path / "dev"
        dev_dir.mkdir()
        sdb = dev_dir / "sdb"
        sdb1 = dev_dir / "sdb1"
        sdb.write_text("", encoding="utf-8")
        sdb1.write_text("", encoding="utf-8")

        stage_dir = tmp_path / "stage_src"
        (stage_dir / "config").mkdir(parents=True)
        (stage_dir / "config" / "rvdk-kit.env").write_text("RVDK_BOARD=waveshare/esp32-p4-wifi6\n", encoding="utf-8")

        vfat_mnt_backing = tmp_path / "vfat_mnt"
        vfat_mnt_backing.mkdir()
        mnt_tmp = tmp_path / "mnt_tmp"
        mnt_tmp.mkdir()
        cp_log = tmp_path / "cp.log"

        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        real_cp = shutil.which("cp") or "/bin/cp"
        _write_exe(
            bin_dir / "cp",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{cp_log}"
for arg in "$@"; do
    case "$arg" in
        -a|-p|--archive|--preserve|--preserve=*)
            echo "cp: failed to preserve ownership on vfat: Operation not permitted" >&2
            exit 1
            ;;
    esac
done
# macOS BSD cp lacks --no-preserve; strip GNU-only --no-preserve=* before delegating
args=()
for arg in "$@"; do
    [[ "$arg" == --no-preserve=* ]] && continue
    args+=("$arg")
done
exec "{real_cp}" "${{args[@]}}"
""",
        )
        _write_exe(bin_dir / "sudo", '#!/usr/bin/env bash\nexec "$@"\n')
        _write_exe(bin_dir / "parted", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "mkfs.vfat", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "wipefs", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "partprobe", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "udevadm", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "sync", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "eject", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-rn -o PATH,TYPE"*) printf '%s disk\\n%s part\\n' "{sdb}" "{sdb1}" ;;
    *"-dn -o TYPE"*) printf 'disk\\n' ;;
    *"-dn -o RM"*) printf '1\\n' ;;
    *"-dn -o HOTPLUG"*) printf '1\\n' ;;
    *"-dn -o TRAN"*) printf 'usb\\n' ;;
    *"-b -dn -o SIZE"*) printf '32000000000\\n' ;;
    *"-dn -o VENDOR,MODEL,SIZE"*) printf 'USB SD 32G\\n' ;;
    *"-dn -o SIZE,MODEL"*) printf '32G USB_SD\\n' ;;
    *"-dn -o MOUNTPOINTS"*) printf '\\n' ;;
esac
exit 0
""",
        )
        _write_exe(bin_dir / "mount", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
if [[ "$tgt" == *"/rvdk_p4_sd_mnt."* && -d "$tgt" ]]; then
    "{real_cp}" -R "$tgt/." "{vfat_mnt_backing}/"
    rm -rf "$tgt/"*
fi
exit 0
""",
        )

        rvdk_ci = _load_rvdk_ci()
        flash_sd_src = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh").read_text(encoding="utf-8"),
            REPO_ROOT,
        )
        fake_board_dir = tmp_path / "repo" / "boards" / "waveshare" / "esp32-p4-wifi6"
        fake_board_dir.mkdir(parents=True)
        (tmp_path / "repo" / "bsp").symlink_to(REPO_ROOT / "bsp")
        (tmp_path / "repo" / "lib").symlink_to(REPO_ROOT / "lib")
        (fake_board_dir / "deeptune.sh").symlink_to(REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh")
        (fake_board_dir / "media.json").symlink_to(REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "media.json")
        (fake_board_dir / "quirks").symlink_to(REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "quirks")
        patched_sd = fake_board_dir / "p4_flash_sd_linux.sh"
        patched_sd.write_text(
            flash_sd_src.replace('[[ -b "$arg" ]]', '[[ -e "$arg" ]]')
            .replace('! -b "$RESOLVED_BLOCK_DEV"', '! -e "$RESOLVED_BLOCK_DEV"')
            .replace('[[ -b "$PART_DEV" ]]', '[[ -e "$PART_DEV" ]]')
            .replace("/tmp/rvdk_p4_sd_mnt.XXXXXX", f"{mnt_tmp}/rvdk_p4_sd_mnt.XXXXXX"),
            encoding="utf-8",
        )

        proc = _run_bash(
            f'bash "{patched_sd}" "{sdb}" --stage-dir "{stage_dir}" -y --noprogbar',
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        assert (vfat_mnt_backing / "config" / "rvdk-kit.env").is_file()
        cp_calls = cp_log.read_text(encoding="utf-8").splitlines()
        assert any("--no-preserve=mode,ownership" in c for c in cp_calls), cp_calls

    def test_rv2_flash_emmc_preserves_custom_fstab_mounts_and_creates_dirs(self, tmp_path: Path) -> None:
        dev_dir = tmp_path / "dev"
        dev_dir.mkdir()
        sd_root = dev_dir / "mmcblk0p1"
        emmc_dev = dev_dir / "mmcblk2"
        emmc_p1 = dev_dir / "mmcblk2p1"
        for node in (sd_root, emmc_dev, emmc_p1):
            node.write_text("", encoding="utf-8")

        uboot_dir = tmp_path / "uboot"
        uboot_dir.mkdir()
        for fn in ("bootinfo_emmc.bin", "bootinfo_sd.bin", "FSBL.bin", "u-boot-opensbi.itb"):
            (uboot_dir / fn).write_bytes(b"uboot")

        host_fstab = tmp_path / "host_fstab"
        host_fstab.write_text(
            "# Host fstab\n"
            "UUID=11111111-2222-3333-4444-555555555555\t/\text4\tdefaults\t0\t1\n"
            "UUID=aaaa-bbbb\t/boot\text4\tdefaults\t0\t2\n"
            "tmpfs\t/tmp\ttmpfs\tdefaults\t0\t0\n"
            "tmpfs\t/run/user\ttmpfs\tdefaults\t0\t0\n"
            "proc\t/proc\tproc\tdefaults\t0\t0\n"
            "/dev/mmcblk0p2\t/mnt/sd_extra\text4\tdefaults\t0\t2\n"
            "/swapfile\tnone\tswap\tsw\t0\t0\n"
            "UUID=33333333-4444-5555-6666-777777777777\t/srv/data\txfs\tdefaults,noatime\t0\t2\n"
            "UUID=44444444-5555-6666-7777-888888888888\t/var/lib/postgresql\text4\tdefaults,noatime\t0\t2\n",
            encoding="utf-8",
        )

        emmc_backing = tmp_path / "emmc_backing"
        emmc_backing.mkdir()
        mnt_tmp = tmp_path / "mnt_tmp"
        mnt_tmp.mkdir()

        bin_dir = tmp_path / "bin"
        _make_linux_uname_shim(bin_dir)
        _write_exe(
            bin_dir / "findmnt",
            f'#!/usr/bin/env bash\nif [[ "$*" == *"-n -o SOURCE /"* && "$*" != *"/boot"* && "$*" != *"/usr"* && "$*" != *"/var"* && "$*" != *"/home"* && "$*" != *"/etc"* && "$*" != *"/opt"* && "$*" != *"/root"* && "$*" != *"/srv"* ]]; then printf "%s\\n" "{sd_root}"; fi\nexit 0\n',
        )
        _write_exe(
            bin_dir / "lsblk",
            f"""#!/usr/bin/env bash
case "$*" in
    *"-rn -o PATH,TYPE"*) printf '%s disk\\n%s part\\n' "{emmc_dev}" "{emmc_p1}" ;;
    *"-no PKNAME"*) printf 'mmcblk0\\n' ;;
    *"-dn -o TYPE"*) printf 'disk\\n' ;;
    *"-b -dn -o SIZE"*) printf '16000000000\\n' ;;
    *"-dn -o SIZE"*) printf '16G\\n' ;;
esac
exit 0
""",
        )
        _write_exe(
            bin_dir / "blkid",
            f"""#!/usr/bin/env bash
node="${{@: -1}}"
if [[ "$*" == *"-s UUID -o value"* ]]; then
    if [[ "$node" == "{sd_root}" ]]; then
        printf '11111111-2222-3333-4444-555555555555\\n'
    else
        printf '22222222-3333-4444-5555-666666666666\\n'
    fi
elif [[ "$*" == *"-s LABEL -o value"* ]]; then
    printf 'rvdk_emmc_root\\n'
fi
exit 0
""",
        )
        _write_exe(bin_dir / "df", "#!/usr/bin/env bash\nprintf 'Filesystem 1M-blocks Used\\n/dev/root 8000 500\\n'\n")
        _write_exe(bin_dir / "mountpoint", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "mount",
            """#!/usr/bin/env bash
tgt="${@: -1}"
mkdir -p "$tgt/etc" "$tgt/boot"
exit 0
""",
        )
        _write_exe(
            bin_dir / "umount",
            f"""#!/usr/bin/env bash
tgt="${{@: -1}}"
if [[ "$tgt" == *"/rvdk_rv2_emmc."* && -d "$tgt" ]]; then
    cp -R "$tgt/." "{emmc_backing}/"
    rm -rf "$tgt/"*
fi
exit 0
""",
        )
        for cmd in ("partprobe", "blockdev", "udevadm", "wipefs", "parted", "dd", "mkfs.ext4", "sync", "rsync", "systemctl"):
            _write_exe(bin_dir / cmd, "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "e2label",
            f"""#!/usr/bin/env bash
if [[ "${{#}}" -eq 1 ]]; then
    if [[ "$1" == "{sd_root}" ]]; then
        printf 'rvdk_sd_root\\n'
    else
        printf 'rvdk_emmc_root\\n'
    fi
fi
exit 0
""",
        )

        rvdk_ci = _load_rvdk_ci()
        emmc_src = rvdk_ci.render_standalone_script(
            (REPO_ROOT / "boards" / "orangepi" / "rv2" / "flash-emmc.sh").read_text(encoding="utf-8"),
            REPO_ROOT,
        )
        emmc_patched = tmp_path / "flash_emmc_fstab.sh"
        emmc_patched.write_text(
            emmc_src.replace(
                'rvdk_require_root "${BASH_SOURCE[0]:-}" ${orig_args[@]+"${orig_args[@]}"}',
                "true",
                1,
            )
            .replace('! -b "$live_root"', '! -e "$live_root"')
            .replace('! -b "$target_dev"', '! -e "$target_dev"')
            .replace('! -b "$emmc_part"', '! -e "$emmc_part"')
            .replace("/usr/lib/u-boot/platform_install.sh", str(tmp_path / "no_platform_install.sh"))
            .replace("/usr/lib/linux-u-boot-*", str(uboot_dir))
            .replace("if [[ -f /etc/fstab ]]; then", f'if [[ -f "{host_fstab}" ]]; then')
            .replace("' /etc/fstab)", f'\' "{host_fstab}")')
            .replace("/tmp/rvdk_rv2_emmc.XXXXXX", f"{mnt_tmp}/rvdk_rv2_emmc.XXXXXX"),
            encoding="utf-8",
        )

        proc = _run_bash(
            f'bash "{emmc_patched}" --force -y "{emmc_dev}"',
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}"},
        )
        assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        out_fstab = (emmc_backing / "etc" / "fstab").read_text(encoding="utf-8")
        assert "UUID=22222222-3333-4444-5555-666666666666\t/\text4" in out_fstab
        assert "UUID=33333333-4444-5555-6666-777777777777\t/srv/data\txfs\tdefaults,noatime\t0\t2" in out_fstab
        assert "UUID=44444444-5555-6666-7777-888888888888\t/var/lib/postgresql\text4\tdefaults,noatime\t0\t2" in out_fstab
        assert "/mnt/sd_extra" not in out_fstab
        assert "/swapfile" not in out_fstab
        assert "/run/user" not in out_fstab
        assert "\tproc\t" not in out_fstab
        assert "/boot" not in out_fstab
        assert (emmc_backing / "srv" / "data").is_dir()
        assert (emmc_backing / "var" / "lib" / "postgresql").is_dir()
