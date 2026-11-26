"""Behavioral regression tests for prebuilt bundle SHA-256 policy and PG18 staging isolation."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PG18_FORGE = REPO_ROOT / "postgresql" / "18-6-io_uring" / "forge.sh"
NTFY_FORGE = REPO_ROOT / "mods" / "ntfy" / "forge.sh"
README_PATH = REPO_ROOT / "README.md"

VALID_TEST_SHA256 = "a" * 64
ALT_TEST_SHA256 = "b" * 64


def _find_bash() -> str:
    for candidate in (
        shutil.which("bash"),
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        "/bin/bash",
    ):
        if not candidate or not Path(candidate).is_file():
            continue
        proc = subprocess.run(
            [candidate, "-c", 'printf "%s" "${BASH_VERSINFO[0]}"'],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.isdigit() and int(proc.stdout) >= 4:
            return candidate
    pytest.skip("Bash >= 4.0 is required for RVDK bundle verification tests")
    raise AssertionError("unreachable")


BASH_BIN = _find_bash()


def _run_bash(
    script: str,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
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


def _extract_pg18_bundle_block() -> str:
    text = PG18_FORGE.read_text(encoding="utf-8")
    pattern = re.compile(
        r'(?ms)^\s*if \[\[ "\$HAVE_VERIFIED_LOCAL_DEBS" == "false" \]\]; then\n'
        r".*?"
        r'(?=^\s*if \[\[ "\$FORCE_BUILD" == "false" \]\]; then)',
    )
    match = pattern.search(text)
    assert match is not None, "Could not locate PG18 prebuilt bundle acquisition block"
    return match.group(0)


def _extract_ntfy_bundle_block() -> str:
    text = NTFY_FORGE.read_text(encoding="utf-8")
    pattern = re.compile(
        r'(?ms)^\s*if \[\[ "\$FORCE_BUILD" == "false" \]\]; then\n'
        r'\s*HAVE_VERIFIED_LOCAL="false"\n'
        r".*?"
        r'(?=^\s*if \[\[ "\$FORCE_BUILD" == "true" \]\]; then)',
    )
    match = pattern.search(text)
    assert match is not None, "Could not locate ntfy prebuilt bundle acquisition block"
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


def _make_tar_shim(bin_dir: Path, tar_log: Path) -> None:
    real_tar = shutil.which("tar")
    assert real_tar is not None
    zstd_bin = shutil.which("zstd")
    if zstd_bin:
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
        _write_exe(
            bin_dir / "tar",
            f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{tar_log}"
args=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-I" ]]; then
        shift 2
        continue
    fi
    args+=("$1")
    shift
done
exec "{real_tar}" "${{args[@]}}"
""",
        )


def _build_archive(tmp_path: Path, src_dir: Path, archive_path: Path) -> str:
    real_tar = shutil.which("tar")
    assert real_tar is not None
    zstd_bin = shutil.which("zstd")
    if zstd_bin:
        plain_tar = tmp_path / f"{archive_path.stem}.tar"
        mk_tar = subprocess.run(
            [real_tar, "-cf", str(plain_tar), "-C", str(src_dir), "."],
            capture_output=True,
            text=True,
            check=False,
        )
        assert mk_tar.returncode == 0, mk_tar.stderr
        mk_zst = subprocess.run(
            [zstd_bin, "-q", "-f", str(plain_tar), "-o", str(archive_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert mk_zst.returncode == 0, mk_zst.stderr
        plain_tar.unlink(missing_ok=True)
    else:
        mk_tar = subprocess.run(
            [real_tar, "-cf", str(archive_path), "-C", str(src_dir), "."],
            capture_output=True,
            text=True,
            check=False,
        )
        assert mk_tar.returncode == 0, mk_tar.stderr
    return hashlib.sha256(archive_path.read_bytes()).hexdigest()


def _make_curl_shim(
    bin_dir: Path,
    curl_log: Path,
    url_payloads: dict[str, Path],
) -> Path:
    map_cases = "\n".join(
        f'    "{url}") cp -f "{src}" "$out_file"; exit 0 ;;'
        for url, src in url_payloads.items()
    )
    return _write_exe(
        bin_dir / "curl",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{curl_log}"
out_file=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out_file="${{2:-}}"; shift 2 ;;
        --proto|--tlsv1.2|--retry) shift 2 ;;
        -fL|-fsSL|-f|-L|-s|-S) shift ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$out_file" && -n "$url" ]] || exit 22
case "$url" in
{map_cases}
    *) exit 22 ;;
esac
""",
    )


def _pg18_helpers_src() -> str:
    fns = [
        "_rvdk_pg_cleanup",
        "_pg_curl",
        "_pg_pinned_bundle_sha256",
        "_pg_purge_local_repo_cache",
        "_pg_verify_local_repo_debs",
        "_pg_write_debs_manifest",
        "_pg_verify_debs_manifest",
        "_pg_stage_built_debs",
    ]
    return "\n\n".join(_extract_bash_function(PG18_FORGE, fn) for fn in fns)


def _ntfy_helpers_src() -> str:
    fns = [
        "_rvdk_ntfy_cleanup",
        "_ntfy_curl",
        "_ntfy_pinned_bundle_sha256",
    ]
    return "\n\n".join(_extract_bash_function(NTFY_FORGE, fn) for fn in fns)


class TestFailFastUnpinnedPolicy:
    @pytest.mark.parametrize(
        "target_slug",
        ["starfive-jh7110", "sifive-p550", "spacemit-k1", "riscv64-generic"],
    )
    def test_pg18_unpinned_target_fails_fast_without_cold_compile(
        self,
        tmp_path: Path,
        target_slug: str,
    ) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        _make_curl_shim(bin_dir, curl_log, {})

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)
        bundle_name = f"postgresql18-6-io_uring-{target_slug}.tar.zst"
        release_base = "https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1"

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="{target_slug}"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{release_base}/{bundle_name}"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
rvdk_register_cleanup _rvdk_pg_cleanup
pinned="$(_pg_pinned_bundle_sha256 "$TARGET_SLUG" "$BUNDLE_NAME")"
printf 'PINNED=%s\\n' "$pinned"
{_extract_pg18_bundle_block()}
printf 'FORCE_BUILD=%s\\n' "$FORCE_BUILD"
"""
        proc = _run_bash(
            script,
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(tmp_path)},
        )
        assert proc.returncode != 0
        assert "PINNED=\n" in proc.stdout
        assert "[RVDK:FATAL]" in proc.stderr
        assert "--bundle-sha256 <hex64>" in proc.stderr
        assert "--allow-remote-sha256" in proc.stderr
        assert "--force-build" in proc.stderr
        assert "FORCE_BUILD=true" not in proc.stdout
        assert not curl_log.exists(), "curl must not run when bundle digest is unpinned"

    @pytest.mark.parametrize(
        "target_slug",
        ["starfive-jh7110", "sifive-p550", "spacemit-k1", "riscv64-generic"],
    )
    def test_ntfy_unpinned_target_fails_fast_without_cold_compile(
        self,
        tmp_path: Path,
        target_slug: str,
    ) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        _make_curl_shim(bin_dir, curl_log, {})

        ntfy_lib = tmp_path / "ntfy"
        bundle_dir = ntfy_lib / "bundles"
        bundle_dir.mkdir(parents=True)
        bundle_name = f"ntfy-2.38.1-{target_slug}.tar.zst"
        release_base = "https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1"
        local_bundle = bundle_dir / bundle_name

        script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
NTFY_VERSION="2.38.1"
TARGET_SLUG="{target_slug}"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{release_base}/{bundle_name}"
NTFY_PREBUILT_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
NTFY_ENABLE_WEB="false"
NTFY_LIB_ROOT="{ntfy_lib}"
BUNDLE_DIR="{bundle_dir}"
BUILD_DIR="{ntfy_lib}/build"
LOCAL_BUNDLE="{local_bundle}"
LOCAL_BUNDLE_SHA="{local_bundle}.sha256"
_NTFY_TMP_ARCHIVE=""
_NTFY_TMP_EXTRACT=""
_NTFY_TMP_PKG=""
_NTFY_TMP_GO_TGZ=""
_NTFY_BUILD_ACTIVE="false"
{_ntfy_helpers_src()}
rvdk_register_cleanup _rvdk_ntfy_cleanup
pinned="$(_ntfy_pinned_bundle_sha256 "$TARGET_SLUG" "$BUNDLE_NAME")"
printf 'PINNED=%s\\n' "$pinned"
{_extract_ntfy_bundle_block()}
printf 'FORCE_BUILD=%s\\n' "$FORCE_BUILD"
"""
        proc = _run_bash(
            script,
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(tmp_path)},
        )
        assert proc.returncode != 0
        assert "PINNED=\n" in proc.stdout
        assert "[RVDK:FATAL]" in proc.stderr
        assert "--bundle-sha256 <hex64>" in proc.stderr
        assert "--allow-remote-sha256" in proc.stderr
        assert "--force-build" in proc.stderr
        assert "FORCE_BUILD=true" not in proc.stdout
        assert not curl_log.exists(), "curl must not run when bundle digest is unpinned"

    def test_allow_remote_sha256_fails_closed_on_empty_or_http_sidecar(
        self,
        tmp_path: Path,
    ) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        src_dir = tmp_path / "src"
        src_dir.mkdir()
        (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"pg18-deb")
        archive_path = tmp_path / "pg18.tar.zst"
        _build_archive(tmp_path, src_dir, archive_path)
        empty_sha = tmp_path / "empty.sha256"
        empty_sha.write_text("   \n", encoding="utf-8")

        https_url = "https://example.test/releases/download/rvdk-v1/postgresql18-6-io_uring-starfive-jh7110.tar.zst"
        _make_curl_shim(
            bin_dir,
            curl_log,
            {
                https_url: archive_path,
                f"{https_url}.sha256": empty_sha,
            },
        )

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)

        # 1. Empty .sha256 sidecar must fail closed
        empty_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="postgresql18-6-io_uring-starfive-jh7110.tar.zst"
RVDK_RELEASE_BASE="https://example.test/releases/download/rvdk-v1"
BUNDLE_URL="{https_url}"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="true"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
rvdk_register_cleanup _rvdk_pg_cleanup
{_extract_pg18_bundle_block()}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(tmp_path)},
        )
        assert empty_proc.returncode != 0
        assert "empty SHA-256 manifest" in empty_proc.stderr
        assert list(repo_dir.iterdir()) == []

        # 2. Non-HTTPS URL with --allow-remote-sha256 must fail closed before curl
        curl_log.unlink(missing_ok=True)
        http_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="postgresql18-6-io_uring-starfive-jh7110.tar.zst"
RVDK_RELEASE_BASE="http://example.test/releases/download/rvdk-v1"
BUNDLE_URL="http://example.test/releases/download/rvdk-v1/postgresql18-6-io_uring-starfive-jh7110.tar.zst"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="true"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
rvdk_register_cleanup _rvdk_pg_cleanup
{_extract_pg18_bundle_block()}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(tmp_path)},
        )
        assert http_proc.returncode != 0
        assert "insecure non-HTTPS URL" in http_proc.stderr
        assert not curl_log.exists()


class TestPinnedSha256Verification:
    def test_pg18_pinned_sha256_pass_and_mismatch(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        tar_log = tmp_path / "tar.log"
        install_log = tmp_path / "install.log"
        chown_log = tmp_path / "chown.log"
        _make_tar_shim(bin_dir, tar_log)
        _make_install_shim(bin_dir, install_log)
        _make_chown_shim(bin_dir, chown_log)

        src_dir = tmp_path / "bundle_src"
        src_dir.mkdir()
        (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"pg18-server-deb")
        (src_dir / "postgresql-client-18_18.6-1_riscv64.deb").write_bytes(b"pg18-client-deb")
        (src_dir / "postgresql-18-dbgsym_18.6-1_riscv64.deb").write_bytes(b"pg18-dbgsym-deb")

        archive_path = tmp_path / "postgresql18-6-io_uring-starfive-jh7110.tar.zst"
        actual_sha = _build_archive(tmp_path, src_dir, archive_path)
        wrong_sha = ALT_TEST_SHA256 if actual_sha != ALT_TEST_SHA256 else VALID_TEST_SHA256

        release_base = "https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1"
        bundle_name = "postgresql18-6-io_uring-starfive-jh7110.tar.zst"
        bundle_url = f"{release_base}/{bundle_name}"
        _make_curl_shim(bin_dir, curl_log, {bundle_url: archive_path})

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)
        stage_tmp = tmp_path / "stage_tmp"
        stage_tmp.mkdir()

        # 1. Pinned lookup match succeeds, strips -dbgsym_, promotes .deb files, writes manifest
        pass_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{bundle_url}"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
_pg_pinned_bundle_sha256() {{
    printf '%s\\n' "{actual_sha}"
}}
rvdk_register_cleanup _rvdk_pg_cleanup
{_extract_pg18_bundle_block()}
_pg_verify_debs_manifest "$LOCAL_REPO_DIR"
printf 'FORCE_BUILD=%s\\n' "$FORCE_BUILD"
"""
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(stage_tmp)}
        pass_proc = _run_bash(pass_script, env=env)
        assert pass_proc.returncode == 0, pass_proc.stderr
        assert f"Verified bundle SHA-256: {actual_sha[:16]}..." in pass_proc.stdout
        assert "FORCE_BUILD=false" in pass_proc.stdout
        assert (repo_dir / "postgresql-18_18.6-1_riscv64.deb").read_bytes() == b"pg18-server-deb"
        assert (repo_dir / "postgresql-client-18_18.6-1_riscv64.deb").read_bytes() == b"pg18-client-deb"
        assert not (repo_dir / "postgresql-18-dbgsym_18.6-1_riscv64.deb").exists()
        assert (repo_dir / ".rvdk-debs.sha256").is_file()
        assert list(stage_tmp.iterdir()) == [], "No temp stage dirs or archives should remain"

        # 2. Pinned lookup mismatch fails closed and leaves existing repo_dir untouched
        fail_script = f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{bundle_url}"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
_pg_pinned_bundle_sha256() {{
    printf '%s\\n' "{wrong_sha}"
}}
rvdk_register_cleanup _rvdk_pg_cleanup
{_extract_pg18_bundle_block()}
"""
        (repo_dir / "sentinel.txt").write_text("KEEP_ME", encoding="utf-8")
        fail_proc = _run_bash(fail_script, env=env)
        assert fail_proc.returncode != 0
        assert "SHA-256 MISMATCH" in fail_proc.stderr
        assert (repo_dir / "sentinel.txt").read_text(encoding="utf-8") == "KEEP_ME"
        assert list(stage_tmp.iterdir()) == []

    def test_ntfy_pinned_sha256_pass_and_mismatch(self, tmp_path: Path) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        chown_log = tmp_path / "chown.log"
        _make_chown_shim(bin_dir, chown_log)

        src_dir = tmp_path / "ntfy_src"
        (src_dir / "usr" / "bin").mkdir(parents=True)
        (src_dir / "usr" / "bin" / "ntfy").write_bytes(b"#!/bin/sh\necho ntfy\n")
        archive_path = tmp_path / "ntfy-2.38.1-starfive-jh7110.tar.zst"
        actual_sha = _build_archive(tmp_path, src_dir, archive_path)
        wrong_sha = ALT_TEST_SHA256 if actual_sha != ALT_TEST_SHA256 else VALID_TEST_SHA256

        release_base = "https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1"
        bundle_name = "ntfy-2.38.1-starfive-jh7110.tar.zst"
        bundle_url = f"{release_base}/{bundle_name}"
        _make_curl_shim(bin_dir, curl_log, {bundle_url: archive_path})

        ntfy_lib = tmp_path / "ntfy"
        bundle_dir = ntfy_lib / "bundles"
        bundle_dir.mkdir(parents=True)
        local_bundle = bundle_dir / bundle_name
        stage_tmp = tmp_path / "stage_tmp"
        stage_tmp.mkdir()
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(stage_tmp)}

        # 1. Pinned lookup match passes and populates LOCAL_BUNDLE + LOCAL_BUNDLE_SHA
        pass_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
NTFY_VERSION="2.38.1"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{bundle_url}"
NTFY_PREBUILT_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
NTFY_ENABLE_WEB="false"
NTFY_LIB_ROOT="{ntfy_lib}"
BUNDLE_DIR="{bundle_dir}"
BUILD_DIR="{ntfy_lib}/build"
LOCAL_BUNDLE="{local_bundle}"
LOCAL_BUNDLE_SHA="{local_bundle}.sha256"
_NTFY_TMP_ARCHIVE=""
_NTFY_TMP_EXTRACT=""
_NTFY_TMP_PKG=""
_NTFY_TMP_GO_TGZ=""
_NTFY_BUILD_ACTIVE="false"
{_ntfy_helpers_src()}
_ntfy_pinned_bundle_sha256() {{
    printf '%s\\n' "{actual_sha}"
}}
rvdk_register_cleanup _rvdk_ntfy_cleanup
{_extract_ntfy_bundle_block()}
printf 'FORCE_BUILD=%s\\n' "$FORCE_BUILD"
""",
            env=env,
        )
        assert pass_proc.returncode == 0, pass_proc.stderr
        assert f"Verified bundle SHA-256: {actual_sha[:16]}..." in pass_proc.stdout
        assert "FORCE_BUILD=false" in pass_proc.stdout
        assert local_bundle.read_bytes() == archive_path.read_bytes()
        assert (bundle_dir / f"{bundle_name}.sha256").read_text(encoding="utf-8").strip() == (
            f"{actual_sha}  {bundle_name}"
        )
        assert list(stage_tmp.iterdir()) == []

        # 2. Pinned mismatch fails closed and preserves existing LOCAL_BUNDLE
        local_bundle.write_bytes(b"TRUSTED_CACHED_BUNDLE")
        (bundle_dir / f"{bundle_name}.sha256").unlink()
        fail_proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
NTFY_VERSION="2.38.1"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{bundle_url}"
NTFY_PREBUILT_URL=""
BUNDLE_SHA256=""
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
NTFY_ENABLE_WEB="false"
NTFY_LIB_ROOT="{ntfy_lib}"
BUNDLE_DIR="{bundle_dir}"
BUILD_DIR="{ntfy_lib}/build"
LOCAL_BUNDLE="{local_bundle}"
LOCAL_BUNDLE_SHA="{local_bundle}.sha256"
_NTFY_TMP_ARCHIVE=""
_NTFY_TMP_EXTRACT=""
_NTFY_TMP_PKG=""
_NTFY_TMP_GO_TGZ=""
_NTFY_BUILD_ACTIVE="false"
{_ntfy_helpers_src()}
_ntfy_pinned_bundle_sha256() {{
    printf '%s\\n' "{wrong_sha}"
}}
rvdk_register_cleanup _rvdk_ntfy_cleanup
{_extract_ntfy_bundle_block()}
""",
            env=env,
        )
        assert fail_proc.returncode != 0
        assert "SHA-256 MISMATCH" in fail_proc.stderr
        assert local_bundle.read_bytes() == b"TRUSTED_CACHED_BUNDLE"
        assert list(stage_tmp.iterdir()) == []

    def test_pg18_pinned_download_failure_does_not_fall_back_to_cold_compile(
        self,
        tmp_path: Path,
    ) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        _make_curl_shim(bin_dir, curl_log, {})

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)
        bundle_name = "postgresql18-6-io_uring-starfive-jh7110.tar.zst"
        release_base = "https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1"

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{release_base}/{bundle_name}"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256="{VALID_TEST_SHA256}"
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
rvdk_register_cleanup _rvdk_pg_cleanup
{_extract_pg18_bundle_block()}
printf 'FORCE_BUILD=%s\\n' "$FORCE_BUILD"
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(tmp_path)},
        )
        assert proc.returncode != 0
        assert "Failed to download prebuilt bundle" in proc.stderr
        assert "FORCE_BUILD=true" not in proc.stdout


class TestPg18IsolatedStaging:
    @pytest.mark.parametrize(
        "malicious_kind",
        [
            "symlink_deb_to_secret",
            "broken_symlink_deb",
            "nested_subdir_deb",
            "dir_named_deb",
            "hidden_dot_deb",
            "traversal_dotdot_deb",
            "leading_dash_deb",
            "space_in_deb_name",
            "no_debs_only_readme",
            "dbgsym_only_bundle",
        ],
    )
    def test_pg18_staging_rejects_malicious_archive_and_leaves_local_repo_untouched(
        self,
        tmp_path: Path,
        malicious_kind: str,
    ) -> None:
        bin_dir = tmp_path / "bin"
        curl_log = tmp_path / "curl.log"
        tar_log = tmp_path / "tar.log"
        install_log = tmp_path / "install.log"
        chown_log = tmp_path / "chown.log"
        _make_tar_shim(bin_dir, tar_log)
        _make_install_shim(bin_dir, install_log)
        _make_chown_shim(bin_dir, chown_log)

        secret = tmp_path / "secret_target"
        secret.write_text("TOP_SECRET", encoding="utf-8")
        secret.chmod(0o600)

        src_dir = tmp_path / "bad_bundle_src"
        src_dir.mkdir()
        if malicious_kind == "symlink_deb_to_secret":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
            (src_dir / "evil_1.0_riscv64.deb").symlink_to(secret)
        elif malicious_kind == "broken_symlink_deb":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
            (src_dir / "broken_1.0_riscv64.deb").symlink_to(tmp_path / "missing_target")
        elif malicious_kind == "nested_subdir_deb":
            (src_dir / "pool").mkdir()
            (src_dir / "pool" / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"nested")
        elif malicious_kind == "dir_named_deb":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").mkdir()
        elif malicious_kind == "hidden_dot_deb":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
            (src_dir / ".hidden_1.0_riscv64.deb").write_bytes(b"hidden")
        elif malicious_kind == "traversal_dotdot_deb":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
            (src_dir / "bad..pkg_1.0_riscv64.deb").write_bytes(b"dotdot")
        elif malicious_kind == "leading_dash_deb":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
            (src_dir / "-evil_1.0_riscv64.deb").write_bytes(b"dash")
        elif malicious_kind == "space_in_deb_name":
            (src_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
            (src_dir / "bad name_1.0_riscv64.deb").write_bytes(b"space")
        elif malicious_kind == "no_debs_only_readme":
            (src_dir / "README.txt").write_text("no packages here\n", encoding="utf-8")
        elif malicious_kind == "dbgsym_only_bundle":
            (src_dir / "postgresql-18-dbgsym_18.6-1_riscv64.deb").write_bytes(b"dbgsym-only")

        archive_path = tmp_path / "malicious.tar.zst"
        archive_sha = _build_archive(tmp_path, src_dir, archive_path)

        release_base = "https://github.com/drewv-labs/riscv-data-kit/releases/download/rvdk-v1"
        bundle_name = "postgresql18-6-io_uring-starfive-jh7110.tar.zst"
        bundle_url = f"{release_base}/{bundle_name}"
        _make_curl_shim(bin_dir, curl_log, {bundle_url: archive_path})

        pg_lib = tmp_path / "pgdg"
        repo_dir = pg_lib / "debs"
        repo_dir.mkdir(parents=True)
        existing_deb = repo_dir / "existing-postgresql-18_18.6-0_riscv64.deb"
        existing_manifest = repo_dir / ".rvdk-debs.sha256"
        existing_release = repo_dir / "Release"
        existing_deb.write_bytes(b"EXISTING_GOOD_DEB")
        existing_manifest_body = (
            f"{hashlib.sha256(b'EXISTING_GOOD_DEB').hexdigest()}  {existing_deb.name}\n"
        )
        existing_manifest.write_text(existing_manifest_body, encoding="utf-8")
        existing_release.write_text("Origin: RVDK\n", encoding="utf-8")

        stage_tmp = tmp_path / "stage_tmp"
        stage_tmp.mkdir()

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
rvdk_prog() {{ :; }}
PG_VERSION="18"
TARGET_SLUG="starfive-jh7110"
BUNDLE_NAME="{bundle_name}"
RVDK_RELEASE_BASE="{release_base}"
BUNDLE_URL="{bundle_url}"
PG_PREBUILT_DEB_URL=""
BUNDLE_SHA256="{archive_sha}"
ALLOW_REMOTE_SHA="false"
SKIP_BUNDLE_SHA="false"
FORCE_BUILD="false"
KEEP_BUILD_DIR="false"
HAVE_VERIFIED_LOCAL_DEBS="false"
PG_LIB_ROOT="{pg_lib}"
BUILD_DIR="{pg_lib}/build"
LOCAL_REPO_DIR="{repo_dir}"
_PG_TMP_ARCHIVE=""
_PG_TMP_KEY=""
_PG_TMP_STAGE=""
_PG_MIGRATING_DIR=""
_PG_BUILD_ACTIVE="false"
{_pg18_helpers_src()}
rvdk_register_cleanup _rvdk_pg_cleanup
{_extract_pg18_bundle_block()}
""",
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "TMPDIR": str(stage_tmp)},
        )
        assert proc.returncode != 0
        assert "[RVDK:FATAL]" in proc.stderr
        assert not install_log.exists(), "install must never promote unverified archive entries"
        assert sorted(p.name for p in repo_dir.iterdir()) == [
            ".rvdk-debs.sha256",
            "Release",
            "existing-postgresql-18_18.6-0_riscv64.deb",
        ]
        assert existing_deb.read_bytes() == b"EXISTING_GOOD_DEB"
        assert existing_manifest.read_text(encoding="utf-8") == existing_manifest_body
        assert existing_release.read_text(encoding="utf-8") == "Origin: RVDK\n"
        assert stat.S_IMODE(secret.stat().st_mode) == 0o600
        assert secret.read_text(encoding="utf-8") == "TOP_SECRET"
        assert list(stage_tmp.iterdir()) == [], "cleanup must remove staging tmpdir on failure"

    def test_verify_local_repo_debs_rejects_fifo_non_regular_entry(self, tmp_path: Path) -> None:
        stage_dir = tmp_path / "stage"
        stage_dir.mkdir()
        (stage_dir / "postgresql-18_18.6-1_riscv64.deb").write_bytes(b"ok-deb")
        os.mkfifo(stage_dir / "rogue_pipe")

        proc = _run_bash(
            f"""
set -Eeuo pipefail
source "{REPO_ROOT}/lib/common.sh"
LOCAL_REPO_DIR="{tmp_path / 'debs'}"
{_extract_bash_function(PG18_FORGE, "_pg_verify_local_repo_debs")}
_pg_verify_local_repo_debs "{stage_dir}"
"""
        )
        assert proc.returncode != 0
        assert "non-regular entry" in proc.stderr


class TestReadmeBundleAlignment:
    def test_readme_uses_https_orangepi_and_documents_bundle_verification_flags(self) -> None:
        readme_text = README_PATH.read_text(encoding="utf-8")
        assert "http://www.orangepi.org/" not in readme_text
        assert "https://www.orangepi.org/" in readme_text
        assert "--allow-remote-sha256" in readme_text
        assert "--bundle-sha256" in readme_text
        assert "--force-build" in readme_text
        assert "prebuilt .tar.zst default" not in readme_text
        assert "bundle by default, or `--force-build`" not in readme_text
