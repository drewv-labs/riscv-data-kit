"""Mocked-subprocess regression tests for lib/flash.sh, lib/bsp.sh, and lib/storage_guard.sh."""

from __future__ import annotations

import hashlib
import os
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
    ) -> tuple[dict[str, str], Path, Path, str, Path, Path, Path]:
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
        _write_exe(
            e2fs_prefix / "sbin" / "mkfs.ext4",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{mkfs_log}"
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
        stage_stamp = stage_dir / "ubuntu-24.04-preinstalled-server-riscv64.img.rvdk-stage.sha256"

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_CACHE_DIR": str(cache_dir),
        }
        return env, src_img, staged_img, src_sha, stage_stamp, zstd_log, mkfs_log

    def test_uboot_ext4_atomic_staging_create_reuse_and_recover(self, tmp_path: Path) -> None:
        env, src_img, staged_img, src_sha, stage_stamp, zstd_log, mkfs_log = (
            self._setup_p550_uboot_ext4_env(tmp_path)
        )
        expected_staged_sha = hashlib.sha256(b"UBOOT_EXT4_STAGED_PAYLOAD_BYTES\n").hexdigest()

        flash_cmd = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/flash.sh"
rvdk_flash_main p550 usb /dev/disk4 --image "{src_img}" --sha256 "{src_sha}" -y
"""
        # 1. Initial atomic decompression creates .rvdk-stage.sha256 (<src_sha256> <staged_sha256>)
        run1 = _run_bash(flash_cmd, env=env)
        assert run1.returncode == 0, run1.stderr
        assert staged_img.is_file()
        assert stage_stamp.is_file()
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 1
        assert "-O ^metadata_csum_seed,^orphan_file" in mkfs_log.read_text(encoding="utf-8")

        # 2. Valid re-run reuses cached image without re-decompressing
        run2 = _run_bash(flash_cmd, env=env)
        assert run2.returncode == 0, run2.stderr
        assert "Reusing verified decompressed staging payload" in run2.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 1

        # 3. Tampered/truncated staged image is rejected with warning and atomically re-decompressed
        staged_img.write_bytes(b"CORRUPT")
        run3 = _run_bash(flash_cmd, env=env)
        assert run3.returncode == 0, run3.stderr
        assert "failed SHA-256 verification" in run3.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 2
        assert staged_img.read_bytes() == b"UBOOT_EXT4_STAGED_PAYLOAD_BYTES\n"
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"

        # 4. Missing sidecar is rejected with warning and atomically re-decompressed
        stage_stamp.unlink()
        run4 = _run_bash(flash_cmd, env=env)
        assert run4.returncode == 0, run4.stderr
        assert "is missing verification sidecar" in run4.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 3
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"

        # 5. Mismatched sidecar is rejected with warning and atomically re-decompressed
        stage_stamp.write_text(f"{'0' * 64} {expected_staged_sha}\n", encoding="utf-8")
        run5 = _run_bash(flash_cmd, env=env)
        assert run5.returncode == 0, run5.stderr
        assert "does not match source archive SHA-256" in run5.stdout
        assert len(zstd_log.read_text(encoding="utf-8").splitlines()) == 4
        assert stage_stamp.read_text(encoding="utf-8").strip() == f"{src_sha} {expected_staged_sha}"


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
