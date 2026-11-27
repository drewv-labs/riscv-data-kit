"""Unit and regression tests for tools/rvdk_ci.py."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
from collections.abc import Mapping
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
VALID_SHA256 = "a" * 64
ALT_SHA256 = "b" * 64


def _load_rvdk_ci() -> ModuleType:
    ci_path = REPO_ROOT / "tools" / "rvdk_ci.py"
    spec = importlib.util.spec_from_file_location("rvdk_ci", ci_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


rvdk_ci = _load_rvdk_ci()


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
    fallback = shutil.which("bash") or "/bin/bash"
    return fallback


def _make_manifest_repo(
    tmp_path: Path,
    *,
    media: Mapping[str, object] | None = None,
    manifest_overrides: Mapping[str, object] | None = None,
    omit_keys: tuple[str, ...] = (),
) -> Path:
    (tmp_path / "bsp" / "demo" / "soc1").mkdir(parents=True)
    board_dir = tmp_path / "boards" / "demo" / "board1"
    board_dir.mkdir(parents=True)
    (board_dir / "flash-sd.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")

    manifest: dict[str, object] = {
        "schema_version": 1,
        "board": "demo/board1",
        "tag": "board1",
        "name": "Demo Board 1",
        "soc": "demo/soc1",
        "default_os": "ubuntu-24.04",
        "media": media
        if media is not None
        else {
            "sd": {
                "mode": "raw",
                "script": "flash-sd.sh",
                "image": "demo.img.zst",
                "sha256": VALID_SHA256,
            }
        },
        "quirks": [],
    }
    if manifest_overrides:
        manifest.update(manifest_overrides)
    for key in omit_keys:
        manifest.pop(key, None)

    (board_dir / "media.json").write_text(json.dumps(manifest), encoding="utf-8")
    return tmp_path


class TestCheckManifests:
    def test_repo_manifests_pass(self) -> None:
        assert rvdk_ci.check_manifests(REPO_ROOT) == []

    def test_valid_manifest_passes(self, tmp_path: Path) -> None:
        repo = _make_manifest_repo(tmp_path)
        assert rvdk_ci.check_manifests(repo) == []

    @pytest.mark.parametrize("mode", ["raw", "uboot_ext4"])
    def test_unpinned_primary_image_rejected_even_with_fallback_sha256(
        self, tmp_path: Path, mode: str
    ) -> None:
        media = {
            "sd": {
                "mode": mode,
                "script": "flash-sd.sh",
                "image": "demo.img.zst",
                "fallback_url": "https://example.com/fallback.img.xz",
                "fallback_sha256": ALT_SHA256,
            }
        }
        repo = _make_manifest_repo(tmp_path, media=media)
        errs = rvdk_ci.check_manifests(repo)
        assert len(errs) == 1
        assert "declares 'image' without pinned 'sha256'" in errs[0]

    def test_invalid_hex_sha256_rejected(self, tmp_path: Path) -> None:
        media = {
            "sd": {
                "mode": "raw",
                "script": "flash-sd.sh",
                "image": "demo.img.zst",
                "sha256": "A" * 64,
            }
        }
        repo = _make_manifest_repo(tmp_path, media=media)
        errs = rvdk_ci.check_manifests(repo)
        assert any("64-character lowercase hex SHA-256 digest" in e for e in errs)

    def test_short_sha256_rejected(self, tmp_path: Path) -> None:
        media = {
            "sd": {
                "mode": "raw",
                "script": "flash-sd.sh",
                "image": "demo.img.zst",
                "sha256": "deadbeef",
            }
        }
        repo = _make_manifest_repo(tmp_path, media=media)
        errs = rvdk_ci.check_manifests(repo)
        assert any("64-character lowercase hex SHA-256 digest" in e for e in errs)

    @pytest.mark.parametrize("missing_key", ["schema_version", "board", "tag", "soc", "media", "quirks"])
    def test_missing_required_keys_rejected(self, tmp_path: Path, missing_key: str) -> None:
        repo = _make_manifest_repo(tmp_path, omit_keys=(missing_key,))
        errs = rvdk_ci.check_manifests(repo)
        assert len(errs) == 1
        assert f"missing required keys: ['{missing_key}']" in errs[0]

    def test_wrong_schema_version_rejected(self, tmp_path: Path) -> None:
        repo = _make_manifest_repo(tmp_path, manifest_overrides={"schema_version": 2})
        errs = rvdk_ci.check_manifests(repo)
        assert any("expected schema_version == 1" in e for e in errs)

    def test_valid_riscv32_sd_bootstrap_with_arch_and_min_image_mib(self, tmp_path: Path) -> None:
        media = {
            "sd": {
                "mode": "sd_bootstrap",
                "script": "flash-sd.sh",
                "root_label": "RVDK_P4_SD",
                "min_size_gib": 4,
                "min_image_mib": 4,
            }
        }
        repo = _make_manifest_repo(
            tmp_path,
            media=media,
            manifest_overrides={"arch": "riscv32"},
        )
        assert rvdk_ci.check_manifests(repo) == []

    def test_valid_riscv64_arch_passes(self, tmp_path: Path) -> None:
        repo = _make_manifest_repo(tmp_path, manifest_overrides={"arch": "riscv64"})
        assert rvdk_ci.check_manifests(repo) == []

    @pytest.mark.parametrize("bad_arch", ["amd64", "x86_64", "arm64", 123, True])
    def test_invalid_arch_rejected(self, tmp_path: Path, bad_arch: object) -> None:
        repo = _make_manifest_repo(tmp_path, manifest_overrides={"arch": bad_arch})
        errs = rvdk_ci.check_manifests(repo)
        assert len(errs) == 1
        assert "optional 'arch'" in errs[0]

    @pytest.mark.parametrize("bad_min_mib", [0, -4, True, False, "4", 4.5])
    def test_invalid_min_image_mib_rejected(self, tmp_path: Path, bad_min_mib: object) -> None:
        media = {
            "sd": {
                "mode": "sd_bootstrap",
                "script": "flash-sd.sh",
                "min_image_mib": bad_min_mib,
            }
        }
        repo = _make_manifest_repo(tmp_path, media=media)
        errs = rvdk_ci.check_manifests(repo)
        assert len(errs) == 1
        assert "min_image_mib" in errs[0]


class TestForbiddenBleedPatterns:
    def test_repo_has_no_forbidden_patterns(self) -> None:
        assert rvdk_ci.check_forbidden_patterns(REPO_ROOT) == []

    @pytest.mark.parametrize(
        "token",
        [
            "Braker" + "Box",
            "Braker" + "Bench",
            "Lil" + "Snitch",
            "Snitch" + "Bench",
            "devbench-" + "p4",
        ],
    )
    def test_new_downstream_iot_bleed_tokens_caught(self, tmp_path: Path, token: str) -> None:
        (tmp_path / "script.sh").write_text(f"echo {token}\n", encoding="utf-8")
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 1
        assert "script.sh:1:" in errs[0]

    @pytest.mark.parametrize(
        "token",
        [
            "Ada" + "Lovespace",
            "ada-" + "lovespace",
            "ada_" + "lovespace",
            "Braker" + "Rak",
        ],
    )
    def test_promo_exempt_tokens_caught_outside_promo_and_allowed_inside_promo(
        self, tmp_path: Path, token: str
    ) -> None:
        # Allowed inside README promo block
        readme = tmp_path / "README.md"
        readme.write_text(
            "# RVDK\n\n"
            "#### Related *DREW-V Labs* Projects\n\n"
            f"- See {token} for downstream workloads.\n\n"
            "---\n\n"
            "Clean footer.\n",
            encoding="utf-8",
        )
        assert rvdk_ci.check_forbidden_patterns(tmp_path) == []

        # Caught outside promo block in README.md
        readme.write_text(
            "# RVDK\n\n"
            f"Leaked {token} in main body.\n\n"
            "#### Related *DREW-V Labs* Projects\n\n"
            "- Clean promo.\n",
            encoding="utf-8",
        )
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 1
        assert "README.md:3:" in errs[0]

        # Caught in regular script/config files
        readme.unlink()
        (tmp_path / "script.sh").write_text(f"echo {token}\n", encoding="utf-8")
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 1
        assert "script.sh:1:" in errs[0]

    @pytest.mark.parametrize(
        "token",
        [
            "Dark" + "Silicon",
            "dark-" + "silicon",
            "Pogger" + "box",
            "Coda" + "Box",
            "Coffee" + "Can",
        ],
    )
    def test_strict_bleed_tokens_caught_everywhere_including_readme_promo(
        self, tmp_path: Path, token: str
    ) -> None:
        readme = tmp_path / "README.md"
        readme.write_text(
            "# RVDK\n\n"
            "#### Related *DREW-V Labs* Projects\n\n"
            f"- {token} must NEVER appear even here.\n\n"
            "---\n",
            encoding="utf-8",
        )
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 1
        assert "README.md:5:" in errs[0]

        (tmp_path / "mod.sh").write_text(f"# {token}\n", encoding="utf-8")
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 2

    @pytest.mark.parametrize(
        "line",
        [
            "kernel." + "kptr_restrict" + "=0",
            "apt-get install " + "--allow-" + "unauthenticated foo",
            "source " + '"$' + 'ENV_FILE"',
            "source " + "$" + "env_file",
            "source " + '"${' + 'RVDK_KIT_CACHE_FILE}"',
            "deb [trusted=" + "yes] http://mirror.example/debian bookworm main",
            "HOME_DIR=$(" + "eval " + 'echo "~$USER")',
            "10.0." + "10.0/24",
        ],
    )
    def test_existing_security_and_bleed_patterns_caught(
        self, tmp_path: Path, line: str
    ) -> None:
        (tmp_path / "bad.sh").write_text(f"#!/usr/bin/env bash\n{line}\n", encoding="utf-8")
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 1
        assert "bad.sh:2:" in errs[0]

    @pytest.mark.parametrize(
        "line",
        [
            "/Users/" + "drew",
            "/Users/" + "drew/repos/riscv-data-kit",
            "/home/" + "drew/.ssh/id_ed25519",
            "/users/" + "drew",
            "dev" + "@gmail.com",
            "alice" + "@example.org",
            "ops" + "@drewv-labs.dev.evil.com",
            "ops" + "@drewv-labs.dev-phish.org",
            "ops" + "@fake-drewv-labs.dev",
            "ops" + "@drewv-labs.com",
            "See user" + "@example.com.",
            "Copyright (c) 2026 DREW-V Labs ("
            + bytes.fromhex("64726577").decode("ascii").title()
            + " "
            + bytes.fromhex("76616e64616772696666").decode("ascii").title()
            + ")",
            bytes.fromhex("64726577").decode("ascii")
            + bytes.fromhex("76616e64616772696666").decode("ascii"),
            bytes.fromhex("64726577").decode("ascii")
            + "."
            + bytes.fromhex("76616e64616772696666").decode("ascii"),
            "author: " + bytes.fromhex("76616e64616772696666").decode("ascii").title(),
        ],
    )
    def test_strict_pii_paths_emails_and_legal_name_caught_everywhere(
        self, tmp_path: Path, line: str
    ) -> None:
        readme = tmp_path / "README.md"
        readme.write_text(
            "# RVDK\n\n"
            "#### Related *DREW-V Labs* Projects\n\n"
            f"- {line}\n\n"
            "---\n",
            encoding="utf-8",
        )
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 1
        assert "README.md:5:" in errs[0]

        (tmp_path / "notes.txt").write_text(f"{line}\n", encoding="utf-8")
        errs = rvdk_ci.check_forbidden_patterns(tmp_path)
        assert len(errs) == 2

    @pytest.mark.parametrize(
        "line",
        [
            "Copyright (c) 2026 DREW-V Labs",
            "DREW-V Labs // rvdk.drewv-labs.dev",
            "ops" + "@drewv-labs.dev",
            "ops" + "@drewv-labs.dev.",
            "ci" + "@rvdk.drewv-labs.dev",
            "/Users/" + "alice/work",
            "/home/" + "rvadmin",
            "/home/" + "drewv-labs/src",
            "/home/${REAL_USER}",
            "/home/swap",
            "sed -E 's@https?://mirror.example/debian@https://deb.debian.org/debian@g'",
            "system." + "@system[0].hostname",
            "postgresql" + "@.service.d",
            "postgresql@18-main.service",
            "postgresql@18-main.service.d",
            "getty@tty1.service",
            "ssh root@192.168.1.10",
            "pkg@1.2.3",
            "actions/checkout@v4.1.0",
        ],
    )
    def test_clean_domains_paths_and_sed_expressions_allowed(
        self, tmp_path: Path, line: str
    ) -> None:
        (tmp_path / "clean.sh").write_text(f"#!/usr/bin/env bash\n# {line}\n", encoding="utf-8")
        assert rvdk_ci.check_forbidden_patterns(tmp_path) == []


class TestRenderStandaloneScript:
    def test_inlines_libs_strips_shebang_and_dead_stubs_and_is_idempotent(
        self, tmp_path: Path
    ) -> None:
        lib_dir = tmp_path / "lib"
        lib_dir.mkdir()
        (lib_dir / "alpha.sh").write_text(
            "#!/usr/bin/env bash\n_RVDK_ALPHA_SH_LOADED=1\nalpha_fn() { echo alpha; }\n",
            encoding="utf-8",
        )
        (lib_dir / "beta.sh").write_text(
            "#!/usr/bin/env bash\n_RVDK_BETA_SH_LOADED=1\nbeta_fn() { echo beta; }\n",
            encoding="utf-8",
        )

        script = (
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "# @RVDK_INLINE_LIBS: alpha beta\n"
            'if [[ -z "${_RVDK_ALPHA_SH_LOADED:-}" ]]; then\n'
            "    alpha_fn() { echo STUB_ALPHA; }\n"
            "fi\n"
            'if [[ -z "${_RVDK_BETA_SH_LOADED:-}" ]]; then\n'
            "    beta_fn() { echo STUB_BETA; }\n"
            "fi\n"
            "alpha_fn\n"
            "beta_fn\n"
        )

        rendered = rvdk_ci.render_standalone_script(script, tmp_path)
        assert "# @RVDK_BUNDLED_LIBS: alpha beta" in rendered
        assert "# --- BEGIN INLINED lib/alpha.sh ---" in rendered
        assert "# --- END INLINED lib/alpha.sh ---" in rendered
        assert "# --- BEGIN INLINED lib/beta.sh ---" in rendered
        assert "# --- END INLINED lib/beta.sh ---" in rendered
        assert "STUB_ALPHA" not in rendered
        assert "STUB_BETA" not in rendered
        assert rendered.count("#!/usr/bin/env bash") == 1

        # Idempotent on re-render
        assert rvdk_ci.render_standalone_script(rendered, tmp_path) == rendered

        # Valid bash syntax and runtime output uses inlined functions
        bash_bin = _find_bash()
        syntax = subprocess.run([bash_bin, "-n"], input=rendered, capture_output=True, text=True, check=False)
        assert syntax.returncode == 0, syntax.stderr
        run = subprocess.run([bash_bin, "-c", rendered], capture_output=True, text=True, check=False)
        assert run.returncode == 0, run.stderr
        assert run.stdout.splitlines() == ["alpha", "beta"]

    @pytest.mark.parametrize(
        "rel_path",
        [
            "utils/purge-user.sh",
            "mods/nvme-4kn/forge.sh",
            "mods/btrfs-raid/forge.sh",
            "os/bootstrap-ubuntu.sh",
        ],
    )
    def test_real_repo_scripts_render_with_valid_syntax_and_no_stub_clobber(
        self, rel_path: str
    ) -> None:
        orig = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
        rendered = rvdk_ci.render_standalone_script(orig, REPO_ROOT)
        assert "# --- BEGIN INLINED lib/common.sh ---" in rendered
        tail = rendered.split("# --- BEGIN INLINED lib/common.sh ---", 1)[1]
        assert "rvdk_sync_cold_clock() { :; }" not in tail

        # Re-rendering already bundled script is idempotent
        assert rvdk_ci.render_standalone_script(rendered, REPO_ROOT) == rendered

        bash_bin = _find_bash()
        syntax = subprocess.run([bash_bin, "-n"], input=rendered, capture_output=True, text=True, check=False)
        assert syntax.returncode == 0, syntax.stderr

    def test_wrapper_target_escaping_repo_root_is_rejected(self, tmp_path: Path) -> None:
        with pytest.raises(ValueError, match="escapes repository root"):
            rvdk_ci.render_standalone_script("# @RVDK_WRAPPER_FILE: ../../etc/passwd\n", tmp_path)


class TestWave1SecurityAndIdempotencyInvariants:
    def test_no_armbian_community_mirror_in_executable_lines(self) -> None:
        for sh_path in rvdk_ci.collect_sh_files(REPO_ROOT):
            for lineno, line in enumerate(sh_path.read_text(encoding="utf-8").splitlines(), start=1):
                stripped = line.lstrip()
                if stripped.startswith("#"):
                    continue
                assert "armbian.chi.auroradev.org" not in line, f"{sh_path}:{lineno}: {line}"
        assert "https://apt.armbian.com" in (REPO_ROOT / "lib" / "apt.sh").read_text(encoding="utf-8")
        assert "https://apt.armbian.com" in (REPO_ROOT / "install-cli.sh").read_text(encoding="utf-8")

    def test_nvme_secondary_fs_label_default_fits_xfs_limit(self) -> None:
        nvme_text = (REPO_ROOT / "mods" / "nvme-4kn" / "forge.sh").read_text(encoding="utf-8")
        assert 'SECONDARY_FS_LABEL="${CLI_SEC_LABEL:-RVDK_SEC}"' in nvme_text
        assert 'SECONDARY_FS_LABEL="${CLI_SEC_LABEL:-RVDK_SECONDARY}"' not in nvme_text

    def test_pg18_and_ntfy_bundle_and_wal_hardening(self) -> None:
        pg_text = (REPO_ROOT / "postgresql" / "18-6-io_uring" / "forge.sh").read_text(encoding="utf-8")
        ntfy_text = (REPO_ROOT / "mods" / "ntfy" / "forge.sh").read_text(encoding="utf-8")

        assert "df -BG --output=size" in pg_text
        assert "df -BG --output=avail" not in pg_text
        assert "tar --no-same-owner --no-same-permissions" in pg_text
        assert "# RVDK-MANAGED-CIDR" in pg_text
        assert "Refusing to fetch remote .sha256 sidecar over insecure non-HTTPS URL" in pg_text
        assert "Refusing to fetch remote .sha256 sidecar over insecure non-HTTPS URL" in ntfy_text

    def test_tailscale_tarball_regex_and_gro_systemd_unit(self) -> None:
        ts_text = (REPO_ROOT / "mods" / "tailscale" / "forge.sh").read_text(encoding="utf-8")
        assert r"^tailscale_[0-9A-Za-z._-]+_(riscv64|amd64|arm64|arm)\.tgz$" in ts_text
        assert "rvdk-tailscale-gro.service" in ts_text

    def test_bootstrap_apt_has_no_static_pub_only_dns_clobber(self) -> None:
        apt_text = (REPO_ROOT / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8")
        assert "static_pub_only" not in apt_text

    def test_no_declare_dash_f_in_core_libs_or_entrypoints(self) -> None:
        targets = [
            *sorted((REPO_ROOT / "lib").glob("*.sh")),
            REPO_ROOT / "bootstrap.sh",
            REPO_ROOT / "install-cli.sh",
            *sorted((REPO_ROOT / "utils").glob("*.sh")),
        ]
        for path in targets:
            text = path.read_text(encoding="utf-8")
            assert "declare -F" not in text, f"{path.relative_to(REPO_ROOT)} still uses 'declare -F'"

    def test_license_and_bootstrap_apt_header_clean(self) -> None:
        license_lines = (REPO_ROOT / "LICENSE").read_text(encoding="utf-8").splitlines()
        assert license_lines[2] == "Copyright (c) 2026 DREW-V Labs"

        bootstrap_apt_text = (REPO_ROOT / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8")
        assert "armbian.chi.auroradev.org" not in bootstrap_apt_text
        assert "apt.armbian.com" in "\n".join(bootstrap_apt_text.splitlines()[:15])

    @pytest.mark.parametrize(
        ("initial_epoch", "synced_epoch", "apt_rc", "expect_bypass", "expect_warn", "expect_sync"),
        [
            ("1767225600", "", 0, False, False, False),
            ("1795651200", "", 0, False, False, False),
            ("1767225600", "", 1, False, False, False),
            ("1000", "1767225605", 0, False, False, True),
            ("1767225599", "1767225599", 0, True, True, True),
        ],
    )
    def test_rvdk_apt_update_conditional_check_valid_until(
        self,
        tmp_path: Path,
        initial_epoch: str,
        synced_epoch: str,
        apt_rc: int,
        expect_bypass: bool,
        expect_warn: bool,
        expect_sync: bool,
    ) -> None:
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        epoch_file = tmp_path / "epoch.txt"
        epoch_file.write_text(initial_epoch, encoding="utf-8")
        apt_log = tmp_path / "apt.log"
        sync_log = tmp_path / "sync.log"
        stamp_file = tmp_path / "apt.stamp"

        date_mock = bin_dir / "date"
        date_mock.write_text(
            "#!/usr/bin/env bash\n"
            'if [[ "${1:-}" == "-u" && "${2:-}" == "+%s" ]]; then\n'
            f'    cat "{epoch_file}"\n'
            "    exit 0\n"
            "fi\n"
            'exec /bin/date "$@"\n',
            encoding="utf-8",
        )
        date_mock.chmod(0o755)

        apt_mock = bin_dir / "apt-get"
        apt_mock.write_text(
            "#!/usr/bin/env bash\n"
            f'printf "%s\\n" "$*" >> "{apt_log}"\n'
            f"exit {apt_rc}\n",
            encoding="utf-8",
        )
        apt_mock.chmod(0o755)

        script = (
            "set -Eeuo pipefail\n"
            f'source "{REPO_ROOT / "lib" / "common.sh"}"\n'
            f'source "{REPO_ROOT / "lib" / "apt.sh"}"\n'
            "rvdk_sync_cold_clock() {\n"
            f'    echo called >> "{sync_log}"\n'
            + (f'    printf "%s" "{synced_epoch}" > "{epoch_file}"\n' if synced_epoch else "")
            + "    return 0\n"
            "}\n"
            "export _RVDK_APT_MIRRORS_CHECKED=1\n"
            f'export RVDK_APT_STAMP_FILE="{stamp_file}"\n'
            "rvdk_apt_update\n"
        )
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        proc = subprocess.run(
            [_find_bash(), "-c", script],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

        assert proc.returncode == apt_rc, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        logged_calls = apt_log.read_text(encoding="utf-8").splitlines()
        assert len(logged_calls) == 1
        if expect_bypass:
            assert "Acquire::Check-Valid-Until=false" in logged_calls[0]
        else:
            assert "Check-Valid-Until=false" not in logged_calls[0]
            assert logged_calls[0] == "-o DPkg::Lock::Timeout=120 update -q"

        if expect_warn:
            assert "[WARN]" in proc.stdout
        else:
            assert "[WARN]" not in proc.stdout

        assert sync_log.exists() is expect_sync
        assert stamp_file.exists() is (apt_rc == 0)

    def test_rvdk_apt_update_failure_under_if_condition_does_not_mark_updated(
        self, tmp_path: Path
    ) -> None:
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        stamp_file = tmp_path / "apt.stamp"

        date_mock = bin_dir / "date"
        date_mock.write_text(
            "#!/usr/bin/env bash\n"
            'if [[ "${1:-}" == "-u" && "${2:-}" == "+%s" ]]; then\n'
            '    echo "1795651200"\n'
            "    exit 0\n"
            "fi\n"
            'exec /bin/date "$@"\n',
            encoding="utf-8",
        )
        date_mock.chmod(0o755)

        apt_mock = bin_dir / "apt-get"
        apt_mock.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
        apt_mock.chmod(0o755)

        script = (
            "set -Eeuo pipefail\n"
            f'source "{REPO_ROOT / "lib" / "apt.sh"}"\n'
            "export _RVDK_APT_MIRRORS_CHECKED=1\n"
            'export RVDK_NO_APT_UPDATE="0"\n'
            f'export RVDK_APT_STAMP_FILE="{stamp_file}"\n'
            "if rvdk_apt_update; then\n"
            "    echo unexpected-success\n"
            "    exit 99\n"
            "fi\n"
            'printf "no_apt_update=%s\\n" "${RVDK_NO_APT_UPDATE}"\n'
        )
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        proc = subprocess.run(
            [_find_bash(), "-c", script],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert proc.returncode == 0, f"stdout={proc.stdout}\nstderr={proc.stderr}"
        assert "no_apt_update=0" in proc.stdout
        assert not stamp_file.exists()


class TestSudoDashEBan:
    def test_repo_has_no_sudo_dash_e(self) -> None:
        assert rvdk_ci.check_sudo_dash_e(REPO_ROOT, REPO_ROOT) == []

    def test_catches_executable_sudo_dash_e_and_allows_comments_or_other_flags(
        self, tmp_path: Path
    ) -> None:
        bad_lines = [
            "sudo " + "-E bash \"$0\"",
            "sudo -n " + "-E id",
            "sudo " + "-nE id",
            "sudo -u root " + "-E env",
            "sudo --preserve-env=FOO " + "-E id",
        ]
        for idx, cmd in enumerate(bad_lines):
            sh = tmp_path / f"bad_{idx}.sh"
            sh.write_text(f"#!/usr/bin/env bash\n{cmd}\n", encoding="utf-8")
            errs = rvdk_ci.check_sudo_dash_e(tmp_path, tmp_path)
            assert len(errs) == 1, f"Expected violation for {cmd!r}, got {errs}"
            assert f"bad_{idx}.sh:2:" in errs[0]
            sh.unlink()

        clean = tmp_path / "clean.sh"
        clean.write_text(
            "#!/usr/bin/env bash\n"
            + "# Never run sudo "
            + "-E in RVDK\n"
            + "sudo sed -E 's/a/b/' /tmp/file\n"
            + "sudo -u root grep -E 'foo' /tmp/file\n"
            + "sudo -- grep -E 'foo' /tmp/file\n"
            + 'sudo --preserve-env=RVDK_TUNE bash "$0"\n'
            + 'rvdk_sudo_preserve bash "$0"\n',
            encoding="utf-8",
        )
        assert rvdk_ci.check_sudo_dash_e(tmp_path, tmp_path) == []

    def test_bundle_dist_rejects_sudo_dash_e_after_inlining(self, tmp_path: Path) -> None:
        repo = tmp_path / "repo"
        (repo / "lib").mkdir(parents=True)
        (repo / "lib" / "badlib.sh").write_text(
            "#!/usr/bin/env bash\n"
            "_RVDK_BADLIB_SH_LOADED=1\n"
            "run_bad() {\n"
            "    sudo " + '-E bash "$@"\n'
            "}\n",
            encoding="utf-8",
        )
        (repo / "bootstrap.sh").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "# @RVDK_INLINE_LIBS: badlib\n"
            "run_bad\n",
            encoding="utf-8",
        )
        out_dir = tmp_path / "out_site"
        errs = rvdk_ci.bundle_dist(repo, out_dir, skip_shellcheck=True, quiet=True)
        assert any("bootstrap.sh:" in e and "Forbidden 'sudo -E'" in e for e in errs), errs


class TestKitBoardAliasSync:
    def test_repo_kit_aliases_stay_in_sync_with_all_17_manifests(self) -> None:
        manifests = sorted((REPO_ROOT / "boards").glob("*/*/media.json"))
        assert len(manifests) == 17
        assert rvdk_ci.check_kit_board_aliases(REPO_ROOT) == []

    def test_detects_missing_or_drifted_kit_alias_tag_soc_and_flash_parity(
        self, tmp_path: Path
    ) -> None:
        repo = tmp_path / "repo"
        (repo / "lib").mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "lib" / "kit.sh", repo / "lib" / "kit.sh")
        shutil.copy2(REPO_ROOT / "lib" / "flash.sh", repo / "lib" / "flash.sh")

        # Copy one valid manifest first and confirm clean pass
        p550_dir = repo / "boards" / "sifive" / "p550"
        p550_dir.mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "boards" / "sifive" / "p550" / "media.json", p550_dir / "media.json")
        assert rvdk_ci.check_kit_board_aliases(repo) == []

        # Drift 1: tag mismatch in manifest vs lib/kit.sh
        p550_doc = json.loads((p550_dir / "media.json").read_text(encoding="utf-8"))
        p550_doc["tag"] = "p550_drift"
        (p550_dir / "media.json").write_text(json.dumps(p550_doc), encoding="utf-8")
        errs_tag = rvdk_ci.check_kit_board_aliases(repo)
        assert any("p550_drift" in e for e in errs_tag), errs_tag

        # Restore p550 manifest, then add unmapped board manifest
        shutil.copy2(REPO_ROOT / "boards" / "sifive" / "p550" / "media.json", p550_dir / "media.json")
        drift_dir = repo / "boards" / "acme" / "driftboard"
        drift_dir.mkdir(parents=True)
        (drift_dir / "media.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "board": "acme/driftboard",
                    "tag": "driftb",
                    "name": "Acme Drift",
                    "soc": "spacemit/k1",
                    "default_os": "debian-13",
                    "media": {},
                    "quirks": [],
                }
            ),
            encoding="utf-8",
        )
        errs_missing = rvdk_ci.check_kit_board_aliases(repo)
        assert any("acme/driftboard" in e and "rvdk_normalize_board_id" in e for e in errs_missing), errs_missing
        assert any("acme/driftboard" in e and "soc" in e for e in errs_missing), errs_missing

        # Remove unmapped board, drift lib/flash.sh alias dict
        shutil.rmtree(repo / "boards" / "acme")
        flash_text = (repo / "lib" / "flash.sh").read_text(encoding="utf-8")
        (repo / "lib" / "flash.sh").write_text(
            flash_text.replace('"p550": "sifive/p550",', '"p550": "acme/wrong",', 1),
            encoding="utf-8",
        )
        errs_flash = rvdk_ci.check_kit_board_aliases(repo)
        assert any("lib/flash.sh" in e for e in errs_flash), errs_flash


class TestConsolidatedCommonHelpersBundling:
    def test_flash_sh_bundle_inlines_common_rewriters_without_duplicates(self) -> None:
        raw = (REPO_ROOT / "lib" / "flash.sh").read_text(encoding="utf-8")
        assert "_rvdk_flash_strip_fstab_commit()" not in raw
        assert "_rvdk_flash_rewrite_literal()" not in raw

        bsp_raw = (REPO_ROOT / "lib" / "bsp.sh").read_text(encoding="utf-8")
        assert "_rvdk_bsp_strip_fstab_commit()" not in bsp_raw
        assert "_rvdk_bsp_rewrite_literal()" not in bsp_raw

        rendered = rvdk_ci.render_standalone_script(raw, REPO_ROOT)
        assert "# --- BEGIN INLINED lib/common.sh ---" in rendered
        assert "_rvdk_strip_fstab_commit()" in rendered
        assert "_rvdk_rewrite_label_token()" in rendered
        assert "_rvdk_rewrite_literal()" in rendered
        syn = subprocess.run([_find_bash(), "-n"], input=rendered, capture_output=True, text=True, check=False)
        assert syn.returncode == 0, syn.stderr



class TestBundleCatalogAndSudoAllowlistCI:
    def test_repo_bundle_catalog_and_sudo_allowlists_pass(self) -> None:
        assert rvdk_ci.check_bundle_catalog(REPO_ROOT) == []
        assert rvdk_ci.check_sudo_preserve_allowlists(REPO_ROOT) == []

    def test_check_bundle_catalog_rejects_bad_schema_sha_and_bundle(self, tmp_path: Path) -> None:
        cat_dir = tmp_path / "catalog"
        cat_dir.mkdir()
        cat_file = cat_dir / "bundles.json"

        # Valid catalog with pinned entry
        cat_file.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "release_tag": "rvdk-v1",
                    "bundles": {
                        "postgresql": {
                            "18.6": {
                                "debian-13-riscv64": {
                                    "bundle": "rvdk-pg18.6-debian-13-riscv64.tar.zst",
                                    "sha256": VALID_SHA256,
                                    "release_tag": "rvdk-v1",
                                }
                            }
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        assert rvdk_ci.check_bundle_catalog(tmp_path) == []

        # Bad schema_version + bad hex sha256 + missing bundle
        cat_file.write_text(
            json.dumps(
                {
                    "schema_version": 2,
                    "release_tag": "bad tag!",
                    "bundles": {
                        "postgresql": {
                            "18.6": {
                                "debian-13-riscv64": {
                                    "bundle": "",
                                    "sha256": "NOT_HEX",
                                }
                            }
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        errs = rvdk_ci.check_bundle_catalog(tmp_path)
        assert any("schema_version" in e for e in errs), errs
        assert any("release_tag" in e for e in errs), errs
        assert any("bundle" in e for e in errs), errs
        assert any("64-character lowercase hex" in e for e in errs), errs

    def test_check_sudo_preserve_allowlists_catches_drift_and_steering_vars(
        self, tmp_path: Path
    ) -> None:
        repo = tmp_path / "repo"
        (repo / "lib").mkdir(parents=True)
        (repo / "os").mkdir(parents=True)
        common_src = (REPO_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        (repo / "lib" / "common.sh").write_text(common_src, encoding="utf-8")
        (repo / "os" / "bootstrap-apt.sh").write_text(
            (REPO_ROOT / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        assert rvdk_ci.check_sudo_preserve_allowlists(repo) == []

        # Drift inline fallback allowlist in os/bootstrap-apt.sh
        apt_txt = (repo / "os" / "bootstrap-apt.sh").read_text(encoding="utf-8")
        (repo / "os" / "bootstrap-apt.sh").write_text(
            apt_txt.replace("RVDK_NO_PROGBAR", "RVDK_NO_PROGBAR RVDK_BASE_URL", 1),
            encoding="utf-8",
        )
        errs = rvdk_ci.check_sudo_preserve_allowlists(repo)
        assert any("RVDK_BASE_URL" in e for e in errs), errs
        assert any("out of sync with lib/common.sh" in e for e in errs), errs
