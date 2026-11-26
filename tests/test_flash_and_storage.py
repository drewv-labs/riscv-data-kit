"""Mocked-subprocess regression tests for lib/flash.sh, lib/bsp.sh, and lib/storage_guard.sh."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
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
