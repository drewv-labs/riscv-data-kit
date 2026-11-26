"""Unit and regression tests for tools/rvdk_ci.py."""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
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
    media: dict[str, object] | None = None,
    manifest_overrides: dict[str, object] | None = None,
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

