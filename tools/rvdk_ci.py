#!/usr/bin/env python3
"""
DREW-V Labs // RVDK Integrity, Agnosticism & Static Bundler Tool
Path: riscv-data-kit/tools/rvdk_ci.py

Zero external dependencies (Python 3 standard library only).

Modes:
  python3 tools/rvdk_ci.py --check
      1. Validates all `boards/*/*/media.json` schemas (`schema_version == 1`),
         SoC BSP directory mappings, media flash scripts, and quirk scripts.
      2. Verifies every repository symlink resolves within the repository root.
      3. Runs `bash -n` syntax validation across all `.sh` scripts.
      4. Runs `shellcheck -x -S warning` across all `.sh` scripts.
      5. Scans repository files for downstream project bleed, PII/hostnames,
         and security anti-patterns (untrusted `.env` sourcing, `kptr_restrict=0`,
         unsigned HTTP APT repos, hardcoded `10.0.10.0/24`, etc.).
      6. Stages a dry-run standalone bundle in a temporary directory and validates
         all rendered `.sh` endpoints (`bash -n`, `shellcheck`, and stub-clobber
         invariants).

  python3 tools/rvdk_ci.py --bundle-dist <out_dir>
      1. Stages static GitHub Pages tree (`rvdk.drewv-labs.dev`), dereferencing
         board/module symlinks.
      2. Expands `# @RVDK_WRAPPER_DISTRO:`, `# @RVDK_WRAPPER_FILE:`, and
         `# @RVDK_INLINE_LIBS:` directives so every `.sh` endpoint works 100%
         standalone via `curl -fsSL https://rvdk.drewv-labs.dev/<path>.sh | sudo bash`.
      3. Verifies `bash -n`, `shellcheck -S warning`, and stub-clobber absence
         on every bundled `.sh` artifact in `<out_dir>`.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

IGNORED_DIRS = {
    ".git",
    "_site",
    "dist",
    "__pycache__",
    "graphify-out",
    "skills",
}

IGNORED_FILES = {
    ".DS_Store",
}

BINARY_EXTENSIONS = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".pdf",
    ".zst",
    ".xz",
    ".gz",
    ".bz2",
    ".img",
}

STAGE_ITEMS = (
    "bootstrap.sh",
    "install-cli.sh",
    "lib",
    "os",
    "bsp",
    "boards",
    "mods",
    "postgresql",
    "utils",
    "README.md",
    "LICENSE",
)

FORBIDDEN_BLEED_PATTERNS: Sequence[tuple[str, re.Pattern[str], bool]] = (
    ("Downstream project bleed (BrakerRak)", re.compile(r"\bbrakerrak\b", re.IGNORECASE), True),
    ("Downstream VG bleed (vg_braker)", re.compile(r"\bvg_braker\b", re.IGNORECASE), False),
    ("Downstream project bleed (CarrierPigeons)", re.compile(r"\bcarrier[-_]?pigeons\b", re.IGNORECASE), True),
    ("Downstream project bleed (Pigeoneer)", re.compile(r"\bpigeoneer\b", re.IGNORECASE), False),
    ("Downstream project bleed (pygeons)", re.compile(r"\bpygeons\b", re.IGNORECASE), False),
    ("Downstream project bleed (HamStak)", re.compile(r"\bhamstak\b", re.IGNORECASE), False),
    ("Personal workstation hostname (ZedBook)", re.compile(r"\bzedbook\b", re.IGNORECASE), False),
    ("Personal shipping note", re.compile(r"stuck in chicago", re.IGNORECASE), False),
    ("Downstream ADMIN_USER env bleed", re.compile(r"\bADMIN_USER\b"), False),
    ("Legacy LAB_SUBNET env bleed", re.compile(r"\bLAB_SUBNET\b"), False),
    ("Legacy nvme_pgdata mountpoint bleed", re.compile(r"nvme_pgdata"), False),
    ("Legacy PGDATA_NVME label bleed", re.compile(r"PGDATA_NVME"), False),
    ("Legacy lv_pgdata LV bleed", re.compile(r"\blv_pgdata\b"), False),
    ("Legacy DUAL_PG_PCT env bleed", re.compile(r"\bDUAL_PG_PCT\b"), False),
    ("Legacy .nfs_dirs JSON schema bleed", re.compile(r"\.nfs_dirs\b"), False),
    ("Hardcoded private subnet 10.0.10.0/24", re.compile(r"\b10\.0\.10\.0/24\b"), False),
    ("Legacy local PGDG path (drewv-pgdg-riscv64)", re.compile(r"drewv-pgdg-riscv64"), False),
    ("Legacy local PGDG list (drewv-local-pgdg)", re.compile(r"drewv-local-pgdg"), False),
    ("Personal username in CLI flags (--user drew)", re.compile(r"--user\s+drew\b"), False),
    ("KASLR-defeating kptr_restrict=0 default", re.compile(r"kptr_restrict\s*=\s*0"), False),
    ("Unsigned APT --allow-unauthenticated", re.compile(r"--allow-unauthenticated"), False),
    ("Unsigned HTTP [trusted=yes] APT source", re.compile(r"\[trusted=yes\]\s*http://", re.IGNORECASE), False),
    (
        "Arbitrary code execution via source on env/cache file",
        re.compile(r"\bsource\s+\"?\$(?:\{)?(?:ENV_FILE|env_file|RVDK_KIT_CACHE_FILE)\b"),
        False,
    ),
    ("Unsafe eval tilde expansion", re.compile(r"\beval\s+echo\s+\"?~"), False),
)


def strip_readme_promo_block(text: str) -> str:
    """Mask lines inside `#### Related *DREW-V Labs* Projects` while preserving line numbers."""
    out_lines: list[str] = []
    in_promo = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#### Related *DREW-V Labs* Projects"):
            in_promo = True
            out_lines.append("")
            continue
        if in_promo:
            if stripped.startswith("#") or stripped == "---":
                in_promo = False
            else:
                out_lines.append("")
                continue
        out_lines.append(line)
    return "\n".join(out_lines)


def check_manifests(repo_root: Path) -> list[str]:
    errors: list[str] = []
    manifest_paths = sorted(glob.glob(str(repo_root / "boards" / "*" / "*" / "media.json")))
    if not manifest_paths:
        errors.append("No board manifests found at boards/*/*/media.json")
        return errors

    required_keys = {"schema_version", "board", "tag", "name", "soc", "default_os", "media", "quirks"}
    seen_tags = {}
    sha256_re = re.compile(r"^[0-9a-f]{64}$")

    for m_str in manifest_paths:
        m_path = Path(m_str)
        rel = m_path.relative_to(repo_root)
        expected_board = f"{m_path.parent.parent.name}/{m_path.parent.name}"
        try:
            data = json.loads(m_path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{rel}: invalid JSON ({exc})")
            continue

        missing = required_keys - set(data.keys())
        if missing:
            errors.append(f"{rel}: missing required keys: {sorted(missing)}")
            continue

        if data.get("schema_version") != 1:
            errors.append(f"{rel}: expected schema_version == 1, got {data.get('schema_version')!r}")

        if data.get("board") != expected_board:
            errors.append(f"{rel}: board={data.get('board')!r} does not match directory {expected_board!r}")

        tag = data.get("tag")
        if not isinstance(tag, str) or not tag:
            errors.append(f"{rel}: 'tag' must be a non-empty string")
        elif tag in seen_tags:
            errors.append(f"{rel}: duplicate board tag {tag!r} (already used in {seen_tags[tag]})")
        else:
            seen_tags[tag] = str(rel)

        soc = data.get("soc")
        if not isinstance(soc, str) or not (repo_root / "bsp" / soc).is_dir():
            errors.append(f"{rel}: soc={soc!r} does not resolve to an existing bsp/<vendor>/<soc> directory")

        media = data.get("media")
        if not isinstance(media, dict):
            errors.append(f"{rel}: 'media' must be an object")
        else:
            for med_key, spec in media.items():
                if not isinstance(spec, dict):
                    errors.append(f"{rel}: media.{med_key} must be an object")
                    continue
                script_rel = spec.get("script")
                if script_rel and not (m_path.parent / script_rel).is_file():
                    errors.append(f"{rel}: media.{med_key}.script={script_rel!r} does not exist")
                mode = spec.get("mode")
                if mode is not None and mode not in ("raw", "uboot_ext4", "sd_bootstrap"):
                    errors.append(f"{rel}: media.{med_key}.mode={mode!r} must be 'raw', 'uboot_ext4', or 'sd_bootstrap'")
                if mode == "sd_bootstrap" and not script_rel:
                    errors.append(f"{rel}: media.{med_key} with mode='sd_bootstrap' requires 'script'")
                eff_mode = mode or ("uboot_ext4" if spec.get("uboot_payload") else "raw")
                for sha_field in ("sha256", "fallback_sha256"):
                    sha_val = spec.get(sha_field)
                    if sha_val is not None and (not isinstance(sha_val, str) or not sha256_re.match(sha_val)):
                        errors.append(
                            f"{rel}: media.{med_key}.{sha_field} must be a 64-character lowercase hex SHA-256 digest"
                        )
                if eff_mode in ("raw", "uboot_ext4"):
                    if spec.get("fallback_url") and not spec.get("fallback_sha256"):
                        errors.append(f"{rel}: media.{med_key} defines 'fallback_url' without 'fallback_sha256'")
                    if not spec.get("sha256") and not spec.get("fallback_sha256"):
                        errors.append(
                            f"{rel}: media.{med_key} ({eff_mode}) requires pinned 'sha256' (or 'fallback_sha256')"
                        )

        quirks = data.get("quirks")
        if not isinstance(quirks, list):
            errors.append(f"{rel}: 'quirks' must be an array")
        else:
            for q_name in quirks:
                q_file = m_path.parent / "quirks" / f"{q_name}.sh"
                if not q_file.is_file():
                    errors.append(f"{rel}: quirk {q_name!r} missing script {q_file.relative_to(repo_root)}")

    return errors


def check_symlinks(repo_root: Path) -> list[str]:
    errors: list[str] = []
    root_real = repo_root.resolve()

    for dirpath, dirnames, filenames in os.walk(repo_root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS]
        cur_dir = Path(dirpath)
        for entry in list(dirnames) + list(filenames):
            p = cur_dir / entry
            if p.is_symlink():
                rel = p.relative_to(repo_root)
                target = p.resolve()
                if not p.exists():
                    errors.append(f"{rel}: broken symlink (-> {os.readlink(p)})")
                    continue
                if not target.is_relative_to(root_real):
                    errors.append(f"{rel}: symlink escapes repository root (-> {target})")

    return errors


def collect_sh_files(root_dir: Path) -> list[Path]:
    sh_files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root_dir, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS]
        for fn in sorted(filenames):
            if fn.endswith(".sh"):
                sh_files.append(Path(dirpath) / fn)
    return sorted(sh_files)


def check_bash_syntax(root_dir: Path, label_root: Path) -> list[str]:
    errors: list[str] = []
    for sh in collect_sh_files(root_dir):
        proc = subprocess.run(
            ["bash", "-n", str(sh)],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            rel = sh.relative_to(label_root)
            errors.append(f"{rel}: bash -n failed:\n{proc.stderr.strip()}")
    return errors


def check_shellcheck(root_dir: Path, label_root: Path, external_sources: bool = False) -> list[str]:
    sc_bin = shutil.which("shellcheck")
    if not sc_bin:
        return [
            "shellcheck binary not found on PATH (install with `brew install shellcheck` or `apt-get install shellcheck`)"
        ]

    sh_files = collect_sh_files(root_dir)
    if not sh_files:
        return []

    cmd = [sc_bin]
    if external_sources:
        cmd.append("-x")
    cmd.extend(["-S", "warning"])
    cmd.extend(str(sh.relative_to(label_root)) for sh in sh_files)

    proc = subprocess.run(
        cmd,
        cwd=str(label_root),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        details = (proc.stdout or proc.stderr).strip()
        return [f"shellcheck failed:\n{details}"]
    return []


def check_forbidden_patterns(repo_root: Path) -> list[str]:
    errors: list[str] = []
    self_path = (repo_root / "tools" / "rvdk_ci.py").resolve()

    for dirpath, dirnames, filenames in os.walk(repo_root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS]
        for fn in sorted(filenames):
            if fn in IGNORED_FILES:
                continue
            p = Path(dirpath) / fn
            if p.is_symlink() or p.suffix.lower() in BINARY_EXTENSIONS:
                continue
            if p.resolve() == self_path:
                continue

            try:
                raw_text = p.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue

            rel = p.relative_to(repo_root)
            promo_masked_text = strip_readme_promo_block(raw_text) if str(rel) == "README.md" else raw_text

            for desc, regex, allow_in_readme_promo in FORBIDDEN_BLEED_PATTERNS:
                haystack = promo_masked_text if allow_in_readme_promo else raw_text
                for lineno, line in enumerate(haystack.splitlines(), start=1):
                    if regex.search(line):
                        errors.append(f"{rel}:{lineno}: {desc}: {line.strip()}")

    return errors


def strip_shebang(content: str) -> str:
    lines = content.splitlines()
    if lines and lines[0].startswith("#!"):
        lines = lines[1:]
    return "\n".join(lines).strip() + "\n"


def render_standalone_script(script_text: str, repo_root: Path) -> str:
    # 1. Expand `# @RVDK_WRAPPER_DISTRO: <distro>` -> `os/bootstrap-apt.sh` with default distro baked in
    m_distro = re.search(r"^#\s*@RVDK_WRAPPER_DISTRO:\s*([a-z0-9_-]+)\s*$", script_text, flags=re.MULTILINE)
    if m_distro:
        distro = m_distro.group(1)
        apt_base = (repo_root / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8")
        script_text = apt_base.replace(
            'DISTRO_FLAVOR="${RVDK_APT_DISTRO_DEFAULT:-auto}"',
            f'DISTRO_FLAVOR="${{RVDK_APT_DISTRO_DEFAULT:-{distro}}}"',
            1,
        )

    # 2. Expand `# @RVDK_WRAPPER_FILE: <rel_path>` -> target script contents
    m_wrap = re.search(r"^#\s*@RVDK_WRAPPER_FILE:\s*(\S+)\s*$", script_text, flags=re.MULTILINE)
    if m_wrap:
        target_rel = m_wrap.group(1)
        target_file = (repo_root / target_rel).resolve()
        if not target_file.is_relative_to(repo_root.resolve()):
            raise ValueError(f"Wrapper target escapes repository root: {target_rel}")
        script_text = target_file.read_text(encoding="utf-8")

    inlined_libs: list[str] = []

    # 3. Expand `# @RVDK_INLINE_LIBS: lib1 lib2 ...`
    def _replace_libs(match: re.Match[str]) -> str:
        libs = match.group(1).split()
        inlined_libs.extend(libs)
        chunks: list[str] = [f"# @RVDK_BUNDLED_LIBS: {' '.join(libs)}"]
        for lib_name in libs:
            lib_file = repo_root / "lib" / f"{lib_name}.sh"
            if not lib_file.is_file():
                raise FileNotFoundError(f"Missing inline library: {lib_file}")
            body = strip_shebang(lib_file.read_text(encoding="utf-8"))
            chunks.append(f"# --- BEGIN INLINED lib/{lib_name}.sh ---\n{body}# --- END INLINED lib/{lib_name}.sh ---")
        return "\n".join(chunks)

    rendered = re.sub(r"^#\s*@RVDK_INLINE_LIBS:\s*(.+)$", _replace_libs, script_text, flags=re.MULTILINE)

    # 4. Strip dead guarded fallback loader/stub blocks for libraries already inlined above
    for lib_name in inlined_libs:
        guard_var = f"_RVDK_{lib_name.upper()}_SH_LOADED"
        guard_re = re.compile(
            rf'^if \[\[ -z "\$\{{{guard_var}:-\}}" \]\]; then\n(?:^(?!fi[ \t]*$).*$\n)*^fi[ \t]*\n?',
            flags=re.MULTILINE,
        )
        rendered = guard_re.sub("", rendered)

    return rendered


def check_bundled_invariants(out_dir: Path) -> list[str]:
    errors: list[str] = []
    marker = "# --- BEGIN INLINED lib/common.sh ---"
    stub_sig = "rvdk_sync_cold_clock() { :; }"
    for sh in collect_sh_files(out_dir):
        text = sh.read_text(encoding="utf-8")
        if marker in text:
            tail = text.split(marker, 1)[1]
            if stub_sig in tail:
                rel = sh.relative_to(out_dir)
                errors.append(
                    f"{rel}: standalone bundle still defines stub `{stub_sig}` after `{marker}`"
                )
    return errors


def bundle_dist(
    repo_root: Path,
    out_dir: Path,
    skip_shellcheck: bool = False,
    quiet: bool = False,
) -> list[str]:
    out_abs = Path(os.path.abspath(os.path.expanduser(str(out_dir))))
    repo_real = repo_root.resolve()
    out_real = out_abs.resolve()
    home_real = Path.home().resolve()
    forbidden_roots = {
        Path("/private/tmp"),
        Path("/private/var"),
        Path("/private/etc"),
        Path("/var/tmp"),
        Path(tempfile.gettempdir()).resolve(),
    }

    if (
        out_real == repo_real
        or repo_real.is_relative_to(out_real)
        or out_real == home_real
        or len(out_abs.parts) <= 2
        or len(out_real.parts) <= 2
        or out_real in forbidden_roots
    ):
        raise ValueError(
            f"Unsafe bundle output directory '{out_real}': refuses repository root, "
            "parent of repository root, $HOME, or top-level/shared system directories."
        )

    if out_real.exists():
        shutil.rmtree(out_real)
    out_real.mkdir(parents=True, exist_ok=True)

    for item in STAGE_ITEMS:
        src = repo_real / item
        if not src.exists():
            continue
        dst = out_real / item
        if src.is_dir():
            shutil.copytree(src, dst, symlinks=False)
        else:
            shutil.copy2(src, dst, follow_symlinks=True)

    (out_real / "CNAME").write_text("rvdk.drewv-labs.dev\n", encoding="utf-8")
    (out_real / ".nojekyll").write_text("", encoding="utf-8")

    bundled_count = 0
    for dirpath, _, filenames in os.walk(out_real):
        for fn in sorted(filenames):
            if not fn.endswith(".sh"):
                continue
            sh_path = Path(dirpath) / fn
            orig = sh_path.read_text(encoding="utf-8")
            rendered = render_standalone_script(orig, repo_real)
            if rendered != orig:
                sh_path.write_text(rendered, encoding="utf-8")
                bundled_count += 1

    if not quiet:
        print(f"[RVDK:BUNDLE] Staged static site in {out_real} ({bundled_count} standalone scripts inlined).")
    errors = check_bundled_invariants(out_real)
    errors.extend(check_bash_syntax(out_real, out_real))
    if not skip_shellcheck:
        errors.extend(check_shellcheck(out_real, out_real, external_sources=False))
    return errors


def run_checks(repo_root: Path, skip_shellcheck: bool = False) -> int:
    all_errors: list[str] = []
    all_errors.extend(check_manifests(repo_root))
    all_errors.extend(check_symlinks(repo_root))
    all_errors.extend(check_bash_syntax(repo_root, repo_root))
    if not skip_shellcheck:
        all_errors.extend(check_shellcheck(repo_root, repo_root, external_sources=True))
    all_errors.extend(check_forbidden_patterns(repo_root))

    with tempfile.TemporaryDirectory(prefix="rvdk_ci_bundle_") as tmp_dir:
        bundle_errs = bundle_dist(
            repo_root,
            Path(tmp_dir) / "dist",
            skip_shellcheck=skip_shellcheck,
            quiet=True,
        )
        all_errors.extend(f"[bundle] {e}" for e in bundle_errs)

    if all_errors:
        print(f"[RVDK:CI] FAILED with {len(all_errors)} issue(s):", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    manifest_cnt = len(glob.glob(str(repo_root / "boards" / "*" / "*" / "media.json")))
    sc_note = " (ShellCheck skipped)" if skip_shellcheck else ", ShellCheck"
    print(
        f"[RVDK:CI] OK — {manifest_cnt} board manifests, symlinks, source & bundled bash syntax{sc_note}, "
        "and security/agnosticism checks passed."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="RVDK CI validator & static standalone bundler")
    parser.add_argument("--check", action="store_true", help="Run manifest, symlink, syntax, ShellCheck, and security checks")
    parser.add_argument("--bundle-dist", metavar="OUT_DIR", help="Build standalone dereferenced static site into OUT_DIR")
    parser.add_argument("--skip-shellcheck", action="store_true", help="Skip ShellCheck verification")
    args = parser.parse_args()

    if not args.check and not args.bundle_dist:
        parser.print_help()
        return 1

    repo_root = Path(__file__).resolve().parent.parent

    if args.check:
        rc = run_checks(repo_root, skip_shellcheck=args.skip_shellcheck)
        if rc != 0:
            return rc

    if args.bundle_dist:
        out_dir = Path(args.bundle_dist).resolve()
        bundle_errors = bundle_dist(repo_root, out_dir, skip_shellcheck=args.skip_shellcheck)
        if bundle_errors:
            print(f"[RVDK:BUNDLE] FAILED verification with {len(bundle_errors)} issue(s):", file=sys.stderr)
            for err in bundle_errors:
                print(f"  - {err}", file=sys.stderr)
            return 1
        sc_note = "" if args.skip_shellcheck else " and ShellCheck"
        print(f"[RVDK:BUNDLE] OK — all bundled standalone scripts passed bash -n{sc_note}.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
