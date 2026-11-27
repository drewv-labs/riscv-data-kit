"""Tests for Waveshare ESP32-P4 (riscv32) onboarding and Layer 1-3 --tune iot DeepTune."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

OWNED_SH_FILES = [
    REPO_ROOT / "os" / "deeptune.sh",
    REPO_ROOT / "bsp" / "eswin" / "eic7700x" / "deeptune.sh",
    REPO_ROOT / "bsp" / "eswin" / "eic7700x" / "bootstrap-ubuntu.sh",
    REPO_ROOT / "bsp" / "spacemit" / "k1" / "deeptune.sh",
    REPO_ROOT / "boards" / "sifive" / "p550" / "deeptune.sh",
    REPO_ROOT / "boards" / "orangepi" / "rv2" / "deeptune.sh",
    REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "forge.sh",
    REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "deeptune.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "quirks" / "c6-sdio.sh",
]

NEW_SH_FILES = [
    REPO_ROOT / "boards" / "orangepi" / "rv2" / "deeptune.sh",
    REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "forge.sh",
    REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "deeptune.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "quirks" / "c6-sdio.sh",
]


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
    pytest.skip("Bash >= 4.0 is required for RVDK shell tests")
    raise AssertionError("unreachable")


BASH_BIN = _find_bash()


def _load_rvdk_ci() -> ModuleType:
    ci_path = REPO_ROOT / "tools" / "rvdk_ci.py"
    spec = importlib.util.spec_from_file_location("rvdk_ci", ci_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _run_script(
    script_path: Path,
    args: list[str] | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    bash_dir = str(Path(BASH_BIN).parent)
    merged_env["PATH"] = f"{bash_dir}:{merged_env.get('PATH', '')}"
    if env:
        merged_env.update(env)
    return subprocess.run(
        [BASH_BIN, str(script_path), *(args or [])],
        cwd=str(REPO_ROOT),
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


class TestHygieneAndBundler:
    @pytest.mark.parametrize("sh_path", OWNED_SH_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
    def test_source_and_bundled_syntax_and_shellcheck(self, sh_path: Path, tmp_path: Path) -> None:
        assert sh_path.is_file()
        text = sh_path.read_text(encoding="utf-8")
        assert "declare -F" not in text, f"{sh_path} must use typeset -f, not declare -F"

        # Source bash -n
        syn = subprocess.run([BASH_BIN, "-n", str(sh_path)], capture_output=True, text=True, check=False)
        assert syn.returncode == 0, syn.stderr

        # Bundled render + bash -n
        rvdk_ci = _load_rvdk_ci()
        rendered = rvdk_ci.render_standalone_script(text, REPO_ROOT)
        syn_b = subprocess.run([BASH_BIN, "-n"], input=rendered, capture_output=True, text=True, check=False)
        assert syn_b.returncode == 0, syn_b.stderr

        sc_bin = shutil.which("shellcheck")
        if sc_bin:
            sc_src = subprocess.run(
                [sc_bin, "-x", "-S", "warning", str(sh_path.relative_to(REPO_ROOT))],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            assert sc_src.returncode == 0, sc_src.stdout + sc_src.stderr

            bundled_file = tmp_path / sh_path.name
            bundled_file.write_text(rendered, encoding="utf-8")
            sc_bnd = subprocess.run(
                [sc_bin, "-x", "-S", "warning", str(bundled_file)],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            assert sc_bnd.returncode == 0, sc_bnd.stdout + sc_bnd.stderr

    @pytest.mark.parametrize("sh_path", NEW_SH_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
    def test_new_scripts_executable_zsh_guard_and_headers(self, sh_path: Path) -> None:
        assert os.access(sh_path, os.X_OK), f"{sh_path} must be executable"
        text = sh_path.read_text(encoding="utf-8")
        assert text.startswith("#!/usr/bin/env bash\n")
        assert "ZSH_VERSION" in text
        assert "set -Eeuo pipefail" in text
        assert "# @RVDK_INLINE_LIBS: common kit progbar" in text

        zsh_bin = shutil.which("zsh")
        if zsh_bin:
            proc_help = subprocess.run(
                [zsh_bin, str(sh_path), "--help"],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            assert proc_help.returncode == 0, proc_help.stderr

            proc_stdin = subprocess.run(
                [zsh_bin],
                input=text,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            assert proc_stdin.returncode == 1
            assert "curl ... | sudo bash" in proc_stdin.stderr

    def test_media_json_contract(self) -> None:
        manifest_path = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "media.json"
        doc = json.loads(manifest_path.read_text(encoding="utf-8"))
        assert doc["schema_version"] == 1
        assert doc["board"] == "waveshare/esp32-p4-wifi6"
        assert doc["tag"] == "p4"
        assert doc["soc"] == "espressif/esp32p4"
        assert doc["arch"] == "riscv32"
        assert doc["default_os"] == "esp-idf"
        assert doc["quirks"] == ["c6-sdio"]
        sd = doc["media"]["sd"]
        assert sd["mode"] == "sd_bootstrap"
        assert sd["script"] == "flash-sd.sh"
        assert sd["root_label"] == "RVDK_P4_SD"
        assert sd["min_size_gib"] == 4
        assert sd["min_image_mib"] == 4
        assert "image" not in sd
        assert "sha256" not in sd
        assert any("303a:1001" in line for line in sd["post_flash_notes"])


class TestEsp32P4BspForgeAndDeeptune:
    def test_bsp_forge_idempotency_and_no_linux_server_tools(self, tmp_path: Path) -> None:
        forge = REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "forge.sh"
        forge_text = forge.read_text(encoding="utf-8")
        for forbidden in ("apt-get", "dpkg", "systemctl", "nvme", "mkfs.xfs"):
            assert forbidden not in forge_text

        stage = tmp_path / "stage"
        p1 = _run_script(forge, ["--stage-dir", str(stage), "--noprogbar"])
        assert p1.returncode == 0, p1.stderr
        assert "[OK]" in p1.stdout

        kit_env = stage / "config" / "rvdk-kit.env"
        assert kit_env.is_file()
        kit_text = kit_env.read_text(encoding="utf-8")
        for expected in (
            'RVDK_SOC="espressif/esp32p4"',
            'RVDK_SOC_SLUG="espressif-esp32p4"',
            'RVDK_BOARD="waveshare/esp32-p4-wifi6"',
            'RVDK_BOARD_TAG="p4"',
            'RVDK_ARCH="riscv32"',
            'RVDK_MMU="none"',
            'RVDK_CPU_HARTS="2"',
        ):
            assert expected in kit_text

        p2 = _run_script(forge, ["--stage-dir", str(stage), "--noprogbar"])
        assert p2.returncode == 0, p2.stderr
        assert "[SKIP]" in p2.stdout
        assert "[OK]" not in p2.stdout
        # Status subcommand reports expected metadata cleanly
        assert kit_env.read_text(encoding="utf-8") == kit_text

    def test_bsp_forge_parameterizes_board_tag_and_sd_label(self, tmp_path: Path) -> None:
        forge = REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "forge.sh"
        forge_text = forge.read_text(encoding="utf-8")
        assert "waveshare/esp32-p4-wifi6" not in forge_text

        # 1. Explicit --board parameterizes board, tag, and FAT32 RVDK_SD_LABEL
        stage_custom = tmp_path / "stage_custom"
        r_custom = _run_script(
            forge,
            ["--board", "acme/p4-mini", "--stage-dir", str(stage_custom), "--noprogbar"],
        )
        assert r_custom.returncode == 0, r_custom.stderr
        custom_txt = (stage_custom / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert 'RVDK_BOARD="acme/p4-mini"' in custom_txt
        assert 'RVDK_BOARD_TAG="p4-mini"' in custom_txt
        assert 'RVDK_SD_LABEL="RVDK_P4_MIN"' in custom_txt

        # 2. Explicit RVDK_BOARD + RVDK_BOARD_TAG env propagation
        stage_env = tmp_path / "stage_env"
        r_env = _run_script(
            forge,
            ["--stage-dir", str(stage_env), "--noprogbar"],
            env={"RVDK_BOARD": "acme/p4-dev", "RVDK_BOARD_TAG": "p4d"},
        )
        assert r_env.returncode == 0, r_env.stderr
        env_txt = (stage_env / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert 'RVDK_BOARD="acme/p4-dev"' in env_txt
        assert 'RVDK_BOARD_TAG="p4d"' in env_txt
        assert 'RVDK_SD_LABEL="RVDK_P4D_SD"' in env_txt

        # 3. Standalone execution without lib/kit.sh falls back cleanly to generic ESP32-P4 identity
        standalone_forge = tmp_path / "standalone_forge.sh"
        standalone_forge.write_text(forge_text, encoding="utf-8")
        standalone_forge.chmod(0o755)
        stage_sa = tmp_path / "stage_sa"
        r_sa = _run_script(
            standalone_forge,
            ["--stage-dir", str(stage_sa), "--noprogbar"],
            env={"RVDK_BOARD": "", "RVDK_BOARD_TAG": ""},
        )
        assert r_sa.returncode == 0, r_sa.stderr
        sa_txt = (stage_sa / "config" / "rvdk-kit.env").read_text(encoding="utf-8")
        assert 'RVDK_BOARD="espressif/esp32p4"' in sa_txt
        assert 'RVDK_BOARD_TAG="esp32p4"' in sa_txt
        assert 'RVDK_SD_LABEL="RVDK_ESP32P"' in sa_txt

        # 4. Malformed --board and oversized RVDK_SD_LABEL fail closed
        r_bad_board = _run_script(
            forge,
            ["--board", "../evil", "--stage-dir", str(tmp_path / "stage_bad1"), "--noprogbar"],
        )
        assert r_bad_board.returncode != 0
        assert "Invalid board identifier" in r_bad_board.stderr

        r_bad_lbl = _run_script(
            forge,
            ["--stage-dir", str(tmp_path / "stage_bad2"), "--noprogbar"],
            env={"RVDK_SD_LABEL": "TOO_LONG_FAT32_LABEL"},
        )
        assert r_bad_lbl.returncode != 0
        assert "Invalid FAT32 volume label" in r_bad_lbl.stderr

    def test_bsp_deeptune_iot_ai_flip_force_and_data_mapping(self, tmp_path: Path) -> None:
        dt = REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "deeptune.sh"
        stage = tmp_path / "stage"

        # Pass 1: iot
        r1 = _run_script(dt, ["--tune", "iot", "--stage-dir", str(stage), "--noprogbar"])
        assert r1.returncode == 0, r1.stderr
        assert "[OK]" in r1.stdout
        iot_cfg = stage / "config" / "sdkconfig.rvdk.iot.defaults"
        ai_cfg = stage / "config" / "sdkconfig.rvdk.ai.defaults"
        env_file = stage / "config" / "deeptune.env"
        assert iot_cfg.is_file()
        assert not ai_cfg.exists()
        iot_text = iot_cfg.read_text(encoding="utf-8")
        for line in (
            "CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_360=y",
            "CONFIG_PM_ENABLE=y",
            "CONFIG_FREERTOS_USE_TICKLESS_IDLE=y",
            "CONFIG_FREERTOS_HZ=1000",
            "CONFIG_SPIRAM=y",
            "CONFIG_SPIRAM_SPEED_200M=y",
            "CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY=y",
            "CONFIG_SDMMC_HOST_DEFAULT_MAX_FREQ_KHZ=40000",
            "CONFIG_FATFS_LFN_HEAP=y",
            "CONFIG_LOG_DEFAULT_LEVEL_WARN=y",
            "CONFIG_ESP_WIFI_REMOTE_ENABLED=y",
            "CONFIG_SLAVE_IDF_TARGET_ESP32C6=y",
        ):
            assert line in iot_text
        assert 'RVDK_TUNE="iot"' in env_file.read_text(encoding="utf-8")

        # Pass 2: idempotent [SKIP]
        r2 = _run_script(dt, ["--tune", "sensor", "--stage-dir", str(stage), "--noprogbar"])
        assert r2.returncode == 0, r2.stderr
        assert "[SKIP]" in r2.stdout
        assert "[OK]" not in r2.stdout

        # Tune flip: iot -> ai
        r3 = _run_script(dt, ["--tune", "ai", "--stage-dir", str(stage), "--noprogbar"])
        assert r3.returncode == 0, r3.stderr
        assert "[OK]" in r3.stdout
        assert ai_cfg.is_file()
        assert not iot_cfg.exists()
        ai_text = ai_cfg.read_text(encoding="utf-8")
        for line in (
            "CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_400=y",
            "CONFIG_PM_ENABLE=n",
            "CONFIG_COMPILER_OPTIMIZATION_PERF=y",
            "CONFIG_SPIRAM=y",
            "CONFIG_SPIRAM_SPEED_200M=y",
            "CONFIG_SPIRAM_XIP_FROM_PSRAM=y",
            "CONFIG_CACHE_L2_CACHE_256KB=y",
            "CONFIG_CACHE_L2_CACHE_LINE_128B=y",
            "CONFIG_ESP_SYSTEM_ALLOW_RTC_FAST_MEM_AS_HEAP=y",
            "CONFIG_SDMMC_HOST_DEFAULT_MAX_FREQ_KHZ=40000",
        ):
            assert line in ai_text
        assert 'RVDK_TUNE="ai"' in env_file.read_text(encoding="utf-8")

        # Pass 2 on ai: [SKIP]
        r4 = _run_script(dt, ["--tune", "ai", "--stage-dir", str(stage), "--noprogbar"])
        assert r4.returncode == 0, r4.stderr
        assert "[SKIP]" in r4.stdout

        # --force on ai: updates atomically with [OK]
        r5 = _run_script(dt, ["--tune", "ai", "--stage-dir", str(stage), "--force", "--noprogbar"])
        assert r5.returncode == 0, r5.stderr
        assert "[OK]" in r5.stdout

        # status subcommand
        r_stat = _run_script(dt, ["status", "--stage-dir", str(stage)])
        assert r_stat.returncode == 0, r_stat.stderr
        assert "Active Tune       : ai" in r_stat.stdout

        # --tune data maps gracefully to iot with warning
        r_data = _run_script(dt, ["--tune", "data", "--stage-dir", str(stage), "--noprogbar"])
        assert r_data.returncode == 0, r_data.stderr
        assert "[WARN]" in r_data.stdout
        assert iot_cfg.is_file()
        assert 'RVDK_TUNE="iot"' in env_file.read_text(encoding="utf-8")


class TestWaveshareBoardFlashDeeptuneAndQuirk:
    def test_board_deeptune_and_c6_sdio_quirk_idempotency(self, tmp_path: Path) -> None:
        board_dt = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh"
        quirk = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "quirks" / "c6-sdio.sh"
        stage = tmp_path / "stage"

        # Board DeepTune iot Pass 1 & 2
        b1 = _run_script(board_dt, ["--tune", "iot", "--stage-dir", str(stage), "--noprogbar"])
        assert b1.returncode == 0, b1.stderr
        assert "[OK]" in b1.stdout
        bcfg = stage / "config" / "board-waveshare-p4.defaults"
        btxt = bcfg.read_text(encoding="utf-8")
        assert 'RVDK_MIPI_CSI_POWER="disabled"' in btxt
        assert 'RVDK_MIPI_DSI_POWER="disabled"' in btxt
        assert "CONFIG_ETH_PHY_IP101=y" in btxt
        assert "CONFIG_ESP_CONSOLE_UART_BAUDRATE=115200" in btxt

        b2 = _run_script(board_dt, ["--tune", "iot", "--stage-dir", str(stage), "--noprogbar"])
        assert b2.returncode == 0, b2.stderr
        assert "[SKIP]" in b2.stdout

        # Board DeepTune ai Pass 1 & 2
        b3 = _run_script(board_dt, ["--tune", "ai", "--stage-dir", str(stage), "--noprogbar"])
        assert b3.returncode == 0, b3.stderr
        assert "[OK]" in b3.stdout
        btxt_ai = bcfg.read_text(encoding="utf-8")
        assert 'RVDK_MIPI_CSI_POWER="enabled"' in btxt_ai
        assert "CONFIG_ESP_LCD_MIPI_DSI_ENABLE=y" in btxt_ai

        # Quirk enable/disable/toggle/status
        q1 = _run_script(quirk, ["enable", "--stage-dir", str(stage), "--noprogbar"])
        assert q1.returncode == 0, q1.stderr
        assert "[OK]" in q1.stdout
        c6_env = stage / "config" / "c6-sdio.env"
        assert 'RVDK_C6_SDIO_ENABLED="true"' in c6_env.read_text(encoding="utf-8")

        q2 = _run_script(quirk, ["enable", "--stage-dir", str(stage), "--noprogbar"])
        assert q2.returncode == 0, q2.stderr
        assert "[SKIP]" in q2.stdout

        q3 = _run_script(quirk, ["disable", "--stage-dir", str(stage), "--noprogbar"])
        assert q3.returncode == 0, q3.stderr
        assert "[OK]" in q3.stdout
        assert 'RVDK_C6_SDIO_ENABLED="false"' in c6_env.read_text(encoding="utf-8")

        q4 = _run_script(quirk, ["disable", "--stage-dir", str(stage), "--noprogbar"])
        assert q4.returncode == 0, q4.stderr
        assert "[SKIP]" in q4.stdout

        q_stat = _run_script(quirk, ["status", "--stage-dir", str(stage)])
        assert q_stat.returncode == 0, q_stat.stderr
        assert "disabled" in q_stat.stdout

        q_tog = _run_script(quirk, ["toggle", "--stage-dir", str(stage), "--noprogbar"])
        assert q_tog.returncode == 0, q_tog.stderr
        assert 'RVDK_C6_SDIO_ENABLED="true"' in c6_env.read_text(encoding="utf-8")

    def test_flash_sd_stage_only_dry_run_and_help(self, tmp_path: Path) -> None:
        flash_sd = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh"

        h = _run_script(flash_sd, ["--help"])
        assert h.returncode == 0, h.stderr
        assert "RVDK_P4_SD" in h.stdout

        dr = _run_script(flash_sd, ["--dry-run"])
        assert dr.returncode == 0, dr.stderr
        assert "[DRY-RUN]" in dr.stdout

        stage = tmp_path / "sd_stage"
        s1 = _run_script(flash_sd, ["--stage-only", str(stage), "--tune", "iot", "--hostname", "p4-sensor-01", "--noprogbar"])
        assert s1.returncode == 0, s1.stderr
        for sub in ("config", "firmware", "models", "telemetry", "ota"):
            assert (stage / sub).is_dir()
        assert (stage / "config" / "rvdk-kit.env").is_file()
        assert (stage / "config" / "deeptune.env").is_file()
        assert (stage / "config" / "sdkconfig.rvdk.iot.defaults").is_file()
        assert (stage / "config" / "board-waveshare-p4.defaults").is_file()
        assert (stage / "config" / "c6-sdio.env").is_file()
        assert (stage / "config" / "hostname").read_text(encoding="utf-8").strip() == "p4-sensor-01"

        # Normalized --stage-dir <dir> --stage-only form + idempotency
        s2 = _run_script(flash_sd, ["--stage-dir", str(stage), "--stage-only", "--tune", "iot", "--noprogbar"])
        assert s2.returncode == 0, s2.stderr
        assert "[SKIP]" in s2.stdout

    def test_flash_sd_safety_interlocks_refuse_root_and_system_disks(self, tmp_path: Path) -> None:
        flash_sd = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh"
        bin_dir = tmp_path / "bin"
        real_uname = shutil.which("uname") or "/usr/bin/uname"

        # 1. macOS /dev/disk0 and /dev/disk1 refused (even with --dry-run)
        _write_exe(
            bin_dir / "uname",
            f'#!/usr/bin/env bash\nif [[ "${{1:-}}" == "-s" ]]; then printf "Darwin\\n"; exit 0; fi\nexec "{real_uname}" "$@"\n',
        )
        mac_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        for dev in ("/dev/disk0", "0", "/dev/disk1"):
            proc = _run_script(flash_sd, [dev, "--dry-run"], env=mac_env)
            assert proc.returncode != 0
            assert "Safety Interlock:" in proc.stderr

        # 2. macOS internal / APFS synthesized /dev/disk3 refused
        _write_exe(
            bin_dir / "diskutil",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
    cat <<'EOF'
   Device Identifier:         disk3
   Device Node:               /dev/disk3
   Device / Media Name:       APPLE SSD AP1024Q
   Content (IOContent):       Apple_APFS_Container
   Device Location:           Internal
   Removable Media:           Fixed
   Virtual:                   Yes
   Disk Size:                 1.0 TB (1000204886016 Bytes)
EOF
    exit 0
fi
exit 0
""",
        )
        proc_apfs = _run_script(flash_sd, ["/dev/disk3", "--dry-run"], env=mac_env)
        assert proc_apfs.returncode != 0
        assert "Safety Interlock:" in proc_apfs.stderr

        # 3. Linux '/' backing disk refused via findmnt + lsblk
        _write_exe(
            bin_dir / "uname",
            f'#!/usr/bin/env bash\nif [[ "${{1:-}}" == "-s" ]]; then printf "Linux\\n"; exit 0; fi\nexec "{real_uname}" "$@"\n',
        )
        _write_exe(
            bin_dir / "findmnt",
            """#!/usr/bin/env bash
if [[ "$*" == *"/"* && "$*" != *"/boot"* && "$*" != *"/usr"* && "$*" != *"/var"* && "$*" != *"/home"* ]]; then
    printf '/dev/sda2\\n'
fi
exit 0
""",
        )
        _write_exe(
            bin_dir / "lsblk",
            """#!/usr/bin/env bash
if [[ "$*" == *"PKNAME"* ]]; then
    printf 'sda\\n'
    exit 0
fi
if [[ "$*" == *"MOUNTPOINTS"* || "$*" == *"MOUNTPOINT"* ]]; then
    printf '/\\n/boot\\n'
    exit 0
fi
exit 0
""",
        )
        lin_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        proc_root = _run_script(flash_sd, ["/dev/sda", "--dry-run"], env=lin_env)
        assert proc_root.returncode != 0
        assert "Safety Interlock:" in proc_root.stderr
        assert "backs critical system mount" in proc_root.stderr

    def test_flash_sd_image_dry_run_enforces_min_image_mib(self, tmp_path: Path) -> None:
        flash_sd = REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh"

        tiny_img = tmp_path / "64k.img"
        tiny_img.write_bytes(b"\x00" * 65536)
        tiny_proc = _run_script(flash_sd, ["--image", str(tiny_img), "--dry-run"])
        assert tiny_proc.returncode != 0
        assert "Safety Interlock:" in tiny_proc.stderr
        assert "4 MiB" in tiny_proc.stderr

        valid_img = tmp_path / "4m.img"
        with valid_img.open("wb") as fh:
            fh.seek(4 * 1024 * 1024 - 1)
            fh.write(b"\x00")
        valid_proc = _run_script(flash_sd, ["--image", str(valid_img), "--dry-run"])
        assert valid_proc.returncode == 0, valid_proc.stderr
        assert "[DRY-RUN]" in valid_proc.stdout
        assert "4194304 bytes >= 4 MiB" in valid_proc.stdout


class TestExistingLayersIotDeepTuneParity:
    @pytest.mark.parametrize(
        "rel_path",
        [
            "os/deeptune.sh",
            "bsp/eswin/eic7700x/deeptune.sh",
            "bsp/spacemit/k1/deeptune.sh",
            "boards/sifive/p550/deeptune.sh",
            "boards/orangepi/rv2/deeptune.sh",
        ],
    )
    def test_help_and_invalid_tune_rejected(self, rel_path: str) -> None:
        script = REPO_ROOT / rel_path
        help_res = _run_script(script, ["--help"])
        assert help_res.returncode == 0, help_res.stderr
        assert "iot" in help_res.stdout

        bad_res = _run_script(script, ["--tune", "invalid-profile"])
        assert bad_res.returncode != 0
        assert "Invalid --tune" in bad_res.stderr or "Root privileges required" in bad_res.stderr or "Run as root" in bad_res.stderr

    def test_os_deeptune_iot_non_systemd_nommu_and_systemd_policies(self, tmp_path: Path) -> None:
        os_dt = REPO_ROOT / "os" / "deeptune.sh"
        src = os_dt.read_text(encoding="utf-8")

        # Verify distinct iot journald, service, module, and sysctl policies in os/deeptune.sh
        assert "Storage=volatile" in src
        assert "RuntimeMaxUse=16M" in src
        assert "RateLimitIntervalSec=30s" in src
        assert "RateLimitBurst=200" in src
        for pkg in ("packagekit", "modemmanager", "apport", "whoopsie"):
            assert pkg in src
        for k in (
            "vm.swappiness = 1",
            "vm.dirty_background_ratio = 3",
            "vm.dirty_ratio = 8",
            "vm.dirty_writeback_centisecs = 1500",
            "vm.vfs_cache_pressure = 120",
            "kernel.sched_autogroup_enabled = 0",
            "net.core.rmem_max = 1048576",
            "net.core.wmem_max = 1048576",
            "net.ipv4.tcp_keepalive_time = 60",
            "net.ipv4.tcp_keepalive_intvl = 15",
            "net.ipv4.tcp_keepalive_probes = 4",
        ):
            assert k in src

        # Behavioral test on patched temp copy (redirecting /etc/sysctl.d and disabling root gate)
        etc_sysctl_dir = tmp_path / "etc_sysctl.d"
        fake_proc_sys = tmp_path / "proc_sys"
        for sub in (
            "vm/swappiness",
            "vm/dirty_background_ratio",
            "vm/dirty_ratio",
            "vm/dirty_writeback_centisecs",
            "vm/vfs_cache_pressure",
            "kernel/sched_autogroup_enabled",
            "net/core/rmem_max",
            "net/core/wmem_max",
            "net/ipv4/tcp_keepalive_time",
            "net/ipv4/tcp_keepalive_intvl",
            "net/ipv4/tcp_keepalive_probes",
        ):
            p = fake_proc_sys / sub
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("1\n", encoding="utf-8")

        patched = tmp_path / "os_deeptune_test.sh"
        p_src = (
            src.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/sysctl.d", str(etc_sysctl_dir))
            .replace("/proc/sys", str(fake_proc_sys))
            .replace("/sys/kernel/mm/transparent_hugepage", str(tmp_path / "no_thp"))
            .replace("command -v systemctl >/dev/null 2>&1", "false")
            .replace("rvdk_kit_resolve", "true")
        )
        patched.write_text(p_src, encoding="utf-8")

        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "sysctl", "#!/usr/bin/env bash\nexit 0\n")
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_OS_ID": "linux-nommu",
            "RVDK_ARCH": "riscv32",
            "RVDK_MMU": "none",
        }
        r1 = _run_script(patched, ["--tune", "edge-iot", "--noprogbar"], env=env)
        assert r1.returncode == 0, r1.stderr
        assert "Transparent HugePages sysfs absent" in r1.stdout
        conf = etc_sysctl_dir / "95-rvdk-deeptune.conf"
        assert conf.is_file()
        conf_text = conf.read_text(encoding="utf-8")
        assert "vm.dirty_ratio = 8" in conf_text
        assert "net.ipv4.tcp_keepalive_time = 60" in conf_text

        r2 = _run_script(patched, ["--tune", "iot", "--noprogbar"], env=env)
        assert r2.returncode == 0, r2.stderr
        assert "already converged" in r2.stdout

        # Also test systemd iot path (volatile journald + iot sysctls + wireless preservation)
        sys_root = tmp_path / "systemd_root"
        (sys_root / "etc" / "systemd" / "journald.conf.d").mkdir(parents=True)
        (sys_root / "etc" / "systemd" / "user").mkdir(parents=True)
        (sys_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (sys_root / "etc" / "modprobe.d").mkdir(parents=True)
        (sys_root / "etc" / "sysctl.d").mkdir(parents=True)

        _write_exe(bin_dir / "systemctl", "#!/usr/bin/env bash\nif [[ \"${1:-}\" == \"is-enabled\" ]]; then echo disabled; fi\nexit 0\n")
        _write_exe(bin_dir / "dpkg-query", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "apt-get", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "findmnt", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "pgrep", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "modprobe", "#!/usr/bin/env bash\nexit 0\n")

        p_sys = (
            src.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/systemd", str(sys_root / "etc" / "systemd"))
            .replace("/etc/modprobe.d", str(sys_root / "etc" / "modprobe.d"))
            .replace("/etc/sysctl.d", str(sys_root / "etc" / "sysctl.d"))
            .replace("/etc/needrestart", str(sys_root / "etc" / "needrestart"))
            .replace("/etc/logrotate", str(sys_root / "etc" / "logrotate"))
            .replace("/etc/default/", str(sys_root / "etc" / "default") + "/")
            .replace("/etc/openwrt_release", str(sys_root / "etc" / "openwrt_release"))
            .replace("/var/log/journal", str(sys_root / "var" / "log" / "journal"))
            .replace("/var/log/sysstat", str(sys_root / "var" / "log" / "sysstat"))
            .replace("/var/lib/rvdk", str(sys_root / "var" / "lib" / "rvdk"))
            .replace("/lib/systemd/system", str(sys_root / "lib" / "systemd" / "system"))
            .replace("/usr/lib/systemd/system", str(sys_root / "usr" / "lib" / "systemd" / "system"))
            .replace("/sys/kernel/mm/transparent_hugepage", str(tmp_path / "no_thp"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/proc/swaps", str(tmp_path / "no_swaps"))
            .replace("rvdk_kit_resolve", "true")
        )
        patched_sys = tmp_path / "os_deeptune_systemd.sh"
        patched_sys.write_text(p_sys, encoding="utf-8")
        r_sys = _run_script(
            patched_sys,
            ["--tune", "iot", "--noprogbar"],
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_OS_ID": "debian", "RVDK_ARCH": "riscv64", "RVDK_MMU": "sv39"},
        )
        assert r_sys.returncode == 0, r_sys.stderr
        jconf = (sys_root / "etc" / "systemd" / "journald.conf.d" / "90-rvdk-deeptune.conf").read_text(encoding="utf-8")
        assert "Storage=volatile" in jconf
        assert "RuntimeMaxUse=16M" in jconf
        assert "RateLimitIntervalSec=30s" in jconf
        assert "RateLimitBurst=200" in jconf
        modconf = (sys_root / "etc" / "modprobe.d" / "85-rvdk-os-deeptune.conf").read_text(encoding="utf-8")
        assert "blacklist cfg80211" not in modconf
        sysconf = (sys_root / "etc" / "sysctl.d" / "95-rvdk-deeptune.conf").read_text(encoding="utf-8")
        assert "vm.dirty_writeback_centisecs = 1500" in sysconf
        assert "net.ipv4.tcp_keepalive_probes = 4" in sysconf

    def test_eic7700x_and_k1_iot_module_and_governor_semantics(self, tmp_path: Path) -> None:
        eic_text = (REPO_ROOT / "bsp" / "eswin" / "eic7700x" / "deeptune.sh").read_text(encoding="utf-8")
        k1_text = (REPO_ROOT / "bsp" / "spacemit" / "k1" / "deeptune.sh").read_text(encoding="utf-8")
        p550_text = (REPO_ROOT / "boards" / "sifive" / "p550" / "deeptune.sh").read_text(encoding="utf-8")

        for txt in (eic_text, k1_text):
            assert "iot|edge-iot|sensor|mcu" in txt
            assert "schedutil ondemand performance" in txt
            assert "pvrsrvkm" in txt

        # Verify K1 preserves wireless/BT in iot mode and EIC7700X disables HDMI/DRM in iot mode
        assert "es_drm dw_hdmi_eswin dw_hdmi_cec" in eic_text
        assert 'if [[ "$TUNE_MODE" == "iot" ]]; then' in k1_text
        assert "preserving Wi-Fi/BT/SDIO/I2C/SPI/UART" in k1_text
        assert "iot|edge-iot|sensor|mcu" in p550_text

        # Behavioral K1 iot test: preserves Wi-Fi/BT in modprobe.d and selects schedutil -> ondemand governor
        k1_root = tmp_path / "k1_root"
        (k1_root / "etc" / "modprobe.d").mkdir(parents=True)
        (k1_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (k1_root / "usr" / "local" / "sbin").mkdir(parents=True)
        cpu0 = k1_root / "sys" / "devices" / "system" / "cpu" / "cpu0" / "cpufreq"
        cpu0.mkdir(parents=True)
        (cpu0 / "scaling_available_governors").write_text("performance ondemand schedutil\n", encoding="utf-8")
        (cpu0 / "scaling_governor").write_text("performance\n", encoding="utf-8")

        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "systemctl", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "modprobe", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "pgrep", "#!/usr/bin/env bash\nexit 1\n")
        _write_exe(bin_dir / "install", "#!/usr/bin/env bash\nexit 0\n")

        p_k1 = (
            k1_text.replace('if [[ "$ACTION" != "status" && "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/modprobe.d", str(k1_root / "etc" / "modprobe.d"))
            .replace("/etc/systemd/system", str(k1_root / "etc" / "systemd" / "system"))
            .replace("/etc/default/cpufrequtils", str(k1_root / "etc" / "default" / "cpufrequtils"))
            .replace("/usr/local/sbin/rvdk-spacemit-k1-irq-tune", str(k1_root / "usr" / "local" / "sbin" / "rvdk-spacemit-k1-irq-tune"))
            .replace("/sys/devices/system/cpu", str(k1_root / "sys" / "devices" / "system" / "cpu"))
            .replace("/etc/openwrt_release", str(k1_root / "etc" / "openwrt_release"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("rvdk_kit_resolve", "true")
        )
        k1_patched = tmp_path / "k1_dt_test.sh"
        k1_patched.write_text(p_k1, encoding="utf-8")
        r_k1 = _run_script(
            k1_patched,
            ["--tune", "iot", "--force", "--noprogbar"],
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_SOC": "spacemit/k1", "RVDK_OS_ID": "ubuntu"},
        )
        assert r_k1.returncode == 0, r_k1.stderr
        k1_mod = (k1_root / "etc" / "modprobe.d" / "90-rvdk-spacemit-k1-deeptune.conf").read_text(encoding="utf-8")
        assert "blacklist pvrsrvkm" in k1_mod
        assert "blacklist bcmdhd" not in k1_mod
        assert "blacklist bluetooth" not in k1_mod
        assert (cpu0 / "scaling_governor").read_text(encoding="utf-8").strip() == "schedutil"

        # Fallback to ondemand when schedutil is absent
        (cpu0 / "scaling_available_governors").write_text("performance ondemand\n", encoding="utf-8")
        r_k1_fb = _run_script(
            k1_patched,
            ["--tune", "iot", "--force", "--noprogbar"],
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_SOC": "spacemit/k1", "RVDK_OS_ID": "ubuntu"},
        )
        assert r_k1_fb.returncode == 0, r_k1_fb.stderr
        assert (cpu0 / "scaling_governor").read_text(encoding="utf-8").strip() == "ondemand"


class TestDeepTuneSecurityReversibilityAndIsolation:
    def _patch_eic_script(self, tmp_path: Path, fake_root: Path) -> Path:
        src = (REPO_ROOT / "bsp" / "eswin" / "eic7700x" / "deeptune.sh").read_text(encoding="utf-8")
        p_src = (
            src.replace('if [[ "$ACTION" != "status" && "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/modprobe.d", str(fake_root / "etc" / "modprobe.d"))
            .replace("/etc/systemd/system", str(fake_root / "etc" / "systemd" / "system"))
            .replace("/etc/default/cpufrequtils", str(fake_root / "etc" / "default" / "cpufrequtils"))
            .replace("/etc/rvdk/deeptune.env", str(fake_root / "etc" / "rvdk" / "deeptune.env"))
            .replace("/usr/local/sbin", str(fake_root / "usr" / "local" / "sbin"))
            .replace("/sys/devices/system/cpu", str(fake_root / "sys" / "devices" / "system" / "cpu"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/proc/interrupts", str(tmp_path / "no_interrupts"))
        )
        patched = tmp_path / "eic_dt_test.sh"
        patched.write_text(p_src, encoding="utf-8")
        return patched

    def _patch_k1_script(self, tmp_path: Path, fake_root: Path) -> Path:
        src = (REPO_ROOT / "bsp" / "spacemit" / "k1" / "deeptune.sh").read_text(encoding="utf-8")
        p_src = (
            src.replace('if [[ "$ACTION" != "status" && "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/modprobe.d", str(fake_root / "etc" / "modprobe.d"))
            .replace("/etc/modules", str(fake_root / "etc" / "modules"))
            .replace("/etc/systemd/system", str(fake_root / "etc" / "systemd" / "system"))
            .replace("/lib/systemd/system", str(fake_root / "lib" / "systemd" / "system"))
            .replace("/usr/lib/systemd/system", str(fake_root / "usr" / "lib" / "systemd" / "system"))
            .replace("/etc/default/cpufrequtils", str(fake_root / "etc" / "default" / "cpufrequtils"))
            .replace("/etc/rvdk/deeptune.env", str(fake_root / "etc" / "rvdk" / "deeptune.env"))
            .replace("/usr/local/sbin", str(fake_root / "usr" / "local" / "sbin"))
            .replace("/sys/devices/system/cpu", str(fake_root / "sys" / "devices" / "system" / "cpu"))
            .replace("/etc/openwrt_release", str(fake_root / "etc" / "openwrt_release"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/proc/interrupts", str(tmp_path / "no_interrupts"))
        )
        patched = tmp_path / "k1_dt_test.sh"
        patched.write_text(p_src, encoding="utf-8")
        return patched

    def _setup_fake_bin(self, tmp_path: Path) -> Path:
        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "systemctl", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "modprobe", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "pgrep", "#!/usr/bin/env bash\nexit 1\n")
        return bin_dir

    @pytest.mark.parametrize("target", ["eic7700x", "k1"])
    @pytest.mark.parametrize("env_key", ["RVDK_PRIMARY_NIC", "RVDK_SECONDARY_NIC", "SECONDARY_NIC"])
    def test_malicious_nic_fails_closed_without_command_injection(
        self, tmp_path: Path, target: str, env_key: str
    ) -> None:
        fake_root = tmp_path / f"{target}_root"
        (fake_root / "etc" / "modprobe.d").mkdir(parents=True)
        (fake_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (fake_root / "usr" / "local" / "sbin").mkdir(parents=True)
        bin_dir = self._setup_fake_bin(tmp_path)

        if target == "eic7700x":
            patched = self._patch_eic_script(tmp_path, fake_root)
            soc = "eswin/eic7700x"
            irq_helper = fake_root / "usr" / "local" / "sbin" / "rvdk-eic7700x-irq-tune"
        else:
            patched = self._patch_k1_script(tmp_path, fake_root)
            soc = "spacemit/k1"
            irq_helper = fake_root / "usr" / "local" / "sbin" / "rvdk-spacemit-k1-irq-tune"

        pwn_tmp = tmp_path / "pwn"
        for payload in (
            f'end0"; touch {pwn_tmp}; #',
            f"end0$(touch {pwn_tmp})",
            "eth0123456789012",
            "end0\ntouch /tmp/should_not_run",
            "..",
        ):
            res = _run_script(
                patched,
                ["--tune", "data", "--force", "--noprogbar"],
                env={
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "RVDK_SOC": soc,
                    "RVDK_OS_ID": "ubuntu",
                    env_key: payload,
                },
            )
            assert res.returncode != 0
            assert "Invalid" in res.stderr
            assert not pwn_tmp.exists()
            assert not irq_helper.exists()

        # Verify canonical payload string fails closed even without RVDK_KIT_SCHEMA pre-populated
        canon_res = _run_script(
            patched,
            ["--tune", "data", "--force", "--noprogbar"],
            env={
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "RVDK_SOC": soc,
                "RVDK_OS_ID": "ubuntu",
                env_key: 'end0"; touch /tmp/pwn; #',
            },
        )
        assert canon_res.returncode != 0
        assert "Invalid" in canon_res.stderr
        assert not irq_helper.exists()

        # Valid NIC renders safely quoted helper and executes cleanly
        valid_res = _run_script(
            patched,
            ["--tune", "data", "--force", "--noprogbar"],
            env={
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "RVDK_KIT_SCHEMA": "1",
                "RVDK_SOC": soc,
                "RVDK_OS_ID": "ubuntu",
                "RVDK_PRIMARY_NIC": "enp1s0f0",
                "RVDK_SECONDARY_NIC": "enp2s0f0",
            },
        )
        assert valid_res.returncode == 0, valid_res.stderr
        assert irq_helper.is_file()
        irq_text = irq_helper.read_text(encoding="utf-8")
        assert "PRIMARY_NIC=enp1s0f0" in irq_text
        assert 'pin_irq "$PRIMARY_NIC"' in irq_text
        syn = subprocess.run([BASH_BIN, "-n", str(irq_helper)], capture_output=True, text=True, check=False)
        assert syn.returncode == 0, syn.stderr

    def test_k1_soc_isolates_orangepi_rv2_and_manages_etc_modules(self, tmp_path: Path) -> None:
        k1_src = (REPO_ROOT / "bsp" / "spacemit" / "k1" / "deeptune.sh").read_text(encoding="utf-8")
        assert "orangepirv2" not in k1_src
        assert "orangepi-hardware-optimize.service" not in k1_src

        fake_root = tmp_path / "k1_root"
        (fake_root / "etc" / "modprobe.d").mkdir(parents=True)
        (fake_root / "etc" / "modules-load.d").mkdir(parents=True)
        (fake_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (fake_root / "usr" / "local" / "sbin").mkdir(parents=True)

        etc_modules = fake_root / "etc" / "modules"
        orig_etc_modules = "loop\nbcmdhd\ndhd_static_buf nvram_path=/etc/fw.txt\n"
        etc_modules.write_text(orig_etc_modules, encoding="utf-8")

        opi_conf = fake_root / "etc" / "modules-load.d" / "orangepirv2.conf"
        orig_opi_conf = "bcmdhd\n"
        opi_conf.write_text(orig_opi_conf, encoding="utf-8")

        backup_root = tmp_path / "backups"
        bin_dir = self._setup_fake_bin(tmp_path)
        patched = self._patch_k1_script(tmp_path, fake_root)

        # 1. K1 SoC layer handles /etc/modules only, leaving orangepirv2.conf and OPI ordering to Layer 3
        opi_env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_KIT_SCHEMA": "1",
            "RVDK_SOC": "spacemit/k1",
            "RVDK_BOARD": "orangepi/rv2",
            "RVDK_OS_ID": "ubuntu",
            "RVDK_PRIMARY_NIC": "end0",
            "RVDK_BACKUP_ROOT": str(backup_root),
        }
        r_data = _run_script(patched, ["--tune", "data", "--force", "--noprogbar"], env=opi_env)
        assert r_data.returncode == 0, r_data.stderr
        assert "# disabled by RVDK spacemit/k1 deeptune" in etc_modules.read_text(encoding="utf-8")
        assert opi_conf.read_text(encoding="utf-8") == orig_opi_conf
        assert "blacklist bcmdhd" in (fake_root / "etc" / "modprobe.d" / "90-rvdk-spacemit-k1-deeptune.conf").read_text(encoding="utf-8")

        etc_enc = str(etc_modules).lstrip("/").replace("/", "__")
        etc_orig = backup_root / "deeptune" / f"{etc_enc}.orig"
        etc_sidecar = backup_root / "deeptune" / f"{etc_enc}.path"
        assert etc_orig.read_text(encoding="utf-8") == orig_etc_modules
        assert etc_sidecar.read_text(encoding="utf-8").strip() == str(etc_modules)

        # 2. K1 data -> iot restores /etc/modules cleanly without OPI service ordering in SoC units
        r_iot = _run_script(patched, ["--tune", "iot", "--force", "--noprogbar"], env=opi_env)
        assert r_iot.returncode == 0, r_iot.stderr
        assert etc_modules.read_text(encoding="utf-8") == orig_etc_modules
        assert opi_conf.read_text(encoding="utf-8") == orig_opi_conf
        assert "blacklist bcmdhd" not in (fake_root / "etc" / "modprobe.d" / "90-rvdk-spacemit-k1-deeptune.conf").read_text(encoding="utf-8")

        iot_unit = (fake_root / "etc" / "systemd" / "system" / "spacemit-k1-cpufreq-iot.service").read_text(encoding="utf-8")
        irq_unit = (fake_root / "etc" / "systemd" / "system" / "spacemit-k1-irq-affinity.service").read_text(encoding="utf-8")
        assert "orangepi-hardware-optimize.service" not in iot_unit
        assert "orangepi-hardware-optimize.service" not in irq_unit

    def test_orangepi_rv2_board_deeptune_modules_systemd_and_permissions(self, tmp_path: Path) -> None:
        rv2_path = REPO_ROOT / "boards" / "orangepi" / "rv2" / "deeptune.sh"
        assert rv2_path.is_file()
        assert (rv2_path.stat().st_mode & 0o777) == 0o755

        fake_root = tmp_path / "rv2_root"
        (fake_root / "etc" / "modules-load.d").mkdir(parents=True)
        (fake_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (fake_root / "etc" / "modprobe.d").mkdir(parents=True)
        (fake_root / "etc" / "rvdk").mkdir(parents=True)

        opi_conf = fake_root / "etc" / "modules-load.d" / "orangepirv2.conf"
        orig_opi_conf = "bcmdhd\ndhd_static_buf\n"
        opi_conf.write_text(orig_opi_conf, encoding="utf-8")

        modinfo_log = tmp_path / "modprobe.log"
        bin_dir = self._setup_fake_bin(tmp_path)
        _write_exe(bin_dir / "modinfo", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "modprobe",
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{modinfo_log}"\nexit 0\n',
        )

        src = rv2_path.read_text(encoding="utf-8")
        patched_src = (
            src.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/modules-load.d/orangepirv2.conf", str(opi_conf))
            .replace("/etc/systemd/system", str(fake_root / "etc" / "systemd" / "system"))
            .replace("/etc/modprobe.d", str(fake_root / "etc" / "modprobe.d"))
            .replace("/etc/rvdk/deeptune.env", str(fake_root / "etc" / "rvdk" / "deeptune.env"))
            .replace("/etc/openwrt_release", str(fake_root / "etc" / "openwrt_release"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/sys/class/net", str(fake_root / "sys" / "class" / "net"))
        )
        patched = tmp_path / "rv2_dt_test.sh"
        patched.write_text(patched_src, encoding="utf-8")

        backup_root = tmp_path / "rv2_backups"
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_KIT_SCHEMA": "1",
            "RVDK_SOC": "spacemit/k1",
            "RVDK_BOARD": "orangepi/rv2",
            "RVDK_OS_ID": "ubuntu",
            "RVDK_PRIMARY_NIC": "end0",
            "RVDK_BACKUP_ROOT": str(backup_root),
        }

        # 1. Non-RV2 board rejected unless --force
        r_guard = _run_script(
            patched,
            ["--tune", "data", "--noprogbar"],
            env={**env, "RVDK_BOARD": "bananapi/f3", "RVDK_DT_MODEL": "Banana Pi BPI-F3"},
        )
        assert r_guard.returncode != 0
        assert "not an Orange Pi RV2" in r_guard.stderr

        # 2. Pass 1 (--tune data): disables bcmdhd/dhd_static_buf with backup + installs IRQ drop-in
        r_data1 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r_data1.returncode == 0, r_data1.stderr
        assert "[OK]" in r_data1.stdout
        assert "# disabled by RVDK orangepi/rv2 deeptune" in opi_conf.read_text(encoding="utf-8")
        opi_enc = str(opi_conf).lstrip("/").replace("/", "__")
        assert (backup_root / "deeptune" / f"{opi_enc}.orig").read_text(encoding="utf-8") == orig_opi_conf

        irq_dropin = fake_root / "etc" / "systemd" / "system" / "spacemit-k1-irq-affinity.service.d" / "90-rvdk-orangepi-rv2.conf"
        iot_dropin = fake_root / "etc" / "systemd" / "system" / "spacemit-k1-cpufreq-iot.service.d" / "90-rvdk-orangepi-rv2.conf"
        assert irq_dropin.is_file()
        assert "After=orangepi-hardware-optimize.service" in irq_dropin.read_text(encoding="utf-8")
        assert not iot_dropin.exists()

        # 3. Pass 2 (--tune data): idempotent [SKIP]
        r_data2 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r_data2.returncode == 0, r_data2.stderr
        assert "[SKIP]" in r_data2.stdout
        assert "[OK]" not in r_data2.stdout

        # 4. --tune iot: restores orangepirv2.conf, installs IoT drop-in, reloads Wi-Fi modules
        r_iot1 = _run_script(patched, ["--tune", "iot", "--noprogbar"], env=env)
        assert r_iot1.returncode == 0, r_iot1.stderr
        assert opi_conf.read_text(encoding="utf-8") == orig_opi_conf
        assert iot_dropin.is_file()
        assert "After=orangepi-hardware-optimize.service" in iot_dropin.read_text(encoding="utf-8")
        mod_calls = modinfo_log.read_text(encoding="utf-8").splitlines()
        assert "dhd_static_buf" in mod_calls
        assert "bcmdhd" in mod_calls

        # 5. Repeat --tune iot: idempotent [SKIP]
        r_iot2 = _run_script(patched, ["--tune", "iot", "--noprogbar"], env=env)
        assert r_iot2.returncode == 0, r_iot2.stderr
        assert "[SKIP]" in r_iot2.stdout
        assert "[OK]" not in r_iot2.stdout

        # 6. iot -> ai removes IoT drop-in and suppresses bcmdhd again
        r_ai = _run_script(patched, ["--tune", "ai", "--noprogbar"], env=env)
        assert r_ai.returncode == 0, r_ai.stderr
        assert not iot_dropin.exists()
        assert "# disabled by RVDK orangepi/rv2 deeptune" in opi_conf.read_text(encoding="utf-8")

        # 7. Wireless primary NIC preserves active bcmdhd autoload
        opi_conf.write_text(orig_opi_conf, encoding="utf-8")
        r_wifi = _run_script(
            patched,
            ["--tune", "data", "--noprogbar"],
            env={**env, "RVDK_PRIMARY_NIC": "wlan0"},
        )
        assert r_wifi.returncode == 0, r_wifi.stderr
        assert opi_conf.read_text(encoding="utf-8") == orig_opi_conf

        # 8. Unprivileged status works cleanly on unpatched script
        r_stat = _run_script(rv2_path, ["status"])
        assert r_stat.returncode == 0, r_stat.stderr
        assert "Layer 3 Board (orangepi/rv2):" in r_stat.stdout

    def test_p550_symmetric_hdmi_transition_and_idempotency(self, tmp_path: Path) -> None:
        board_dir = tmp_path / "boards" / "sifive" / "p550"
        quirks_dir = board_dir / "quirks"
        quirks_dir.mkdir(parents=True)
        hdmi_log = tmp_path / "hdmi_calls.log"
        fusb_log = tmp_path / "fusb_calls.log"
        plat_dir = tmp_path / "plat_drivers"
        (plat_dir / "dw-hdmi-eswin" / "502a0000.hdmi").mkdir(parents=True)

        _write_exe(
            quirks_dir / "fusb.sh",
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{fusb_log}"\nexit 0\n',
        )
        _write_exe(
            quirks_dir / "hdmi.sh",
            f"""#!/usr/bin/env bash
printf "%s\\n" "$*" >> "{hdmi_log}"
if [[ "${{1:-}}" == "off" ]]; then
    rm -rf "{plat_dir}/dw-hdmi-eswin/502a0000.hdmi"
elif [[ "${{1:-}}" == "on" ]]; then
    mkdir -p "{plat_dir}/dw-hdmi-eswin/502a0000.hdmi"
fi
exit 0
""",
        )

        modprobe_dir = tmp_path / "etc" / "modprobe.d"
        modprobe_dir.mkdir(parents=True)
        dt_env = tmp_path / "etc" / "rvdk" / "deeptune.env"
        dt_env.parent.mkdir(parents=True)
        state_file = tmp_path / "run" / "rvdk-p550-hdmi.state"

        src = (REPO_ROOT / "boards" / "sifive" / "p550" / "deeptune.sh").read_text(encoding="utf-8")
        patched_src = (
            src.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("/etc/modprobe.d", str(modprobe_dir))
            .replace("/etc/rvdk/deeptune.env", str(dt_env))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/sys/bus/i2c/drivers/fusb303b", str(tmp_path / "no_i2c"))
        )
        patched = board_dir / "deeptune.sh"
        patched.write_text(patched_src, encoding="utf-8")

        env = {
            "RVDK_P550_HDMI_STATE_FILE": str(state_file),
            "RVDK_P550_PLAT_DRV_BASE": str(plat_dir),
        }

        # Initial --tune data: does not invoke hdmi.sh
        r_data1 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r_data1.returncode == 0, r_data1.stderr
        assert not hdmi_log.exists()

        # data -> iot: calls hdmi.sh off once
        r_iot1 = _run_script(patched, ["--tune", "iot", "--noprogbar"], env=env)
        assert r_iot1.returncode == 0, r_iot1.stderr
        assert hdmi_log.read_text(encoding="utf-8").splitlines() == ["off"]

        # iot -> iot: idempotent [SKIP], no extra call
        r_iot2 = _run_script(patched, ["--tune", "iot", "--noprogbar"], env=env)
        assert r_iot2.returncode == 0, r_iot2.stderr
        assert hdmi_log.read_text(encoding="utf-8").splitlines() == ["off"]

        # iot -> data: restores via hdmi.sh on
        r_data2 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r_data2.returncode == 0, r_data2.stderr
        assert hdmi_log.read_text(encoding="utf-8").splitlines() == ["off", "on"]

        # data -> data: idempotent [SKIP]
        r_data3 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r_data3.returncode == 0, r_data3.stderr
        assert hdmi_log.read_text(encoding="utf-8").splitlines() == ["off", "on"]

        # data -> iot -> ai -> ai
        r_iot3 = _run_script(patched, ["--tune", "iot", "--noprogbar"], env=env)
        assert r_iot3.returncode == 0, r_iot3.stderr
        r_ai1 = _run_script(patched, ["--tune", "ai", "--noprogbar"], env=env)
        assert r_ai1.returncode == 0, r_ai1.stderr
        r_ai2 = _run_script(patched, ["--tune", "ai", "--noprogbar"], env=env)
        assert r_ai2.returncode == 0, r_ai2.stderr
        assert hdmi_log.read_text(encoding="utf-8").splitlines() == ["off", "on", "off", "on"]

    def test_p550_deeptune_installs_fancontrol_idempotently(self, tmp_path: Path) -> None:
        board_dir = tmp_path / "boards" / "sifive" / "p550"
        quirks_dir = board_dir / "quirks"
        quirks_dir.mkdir(parents=True)
        _write_exe(quirks_dir / "fusb.sh", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(quirks_dir / "hdmi.sh", "#!/usr/bin/env bash\nexit 0\n")

        modprobe_dir = tmp_path / "etc" / "modprobe.d"
        modprobe_dir.mkdir(parents=True)
        dt_env = tmp_path / "etc" / "rvdk" / "deeptune.env"
        dt_env.parent.mkdir(parents=True)

        apt_log = tmp_path / "apt_calls.log"
        dpkg_state = tmp_path / "fancontrol.installed"
        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "apt-cache", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "dpkg",
            f'#!/usr/bin/env bash\n[[ -f "{dpkg_state}" ]]\n',
        )
        _write_exe(
            bin_dir / "dpkg-query",
            f'#!/usr/bin/env bash\nif [[ -f "{dpkg_state}" ]]; then echo "install ok installed"; exit 0; fi\nexit 1\n',
        )
        _write_exe(
            bin_dir / "apt-get",
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{apt_log}"\ntouch "{dpkg_state}"\nexit 0\n',
        )

        src = (REPO_ROOT / "boards" / "sifive" / "p550" / "deeptune.sh").read_text(encoding="utf-8")
        rvdk_ci = _load_rvdk_ci()
        rendered = rvdk_ci.render_standalone_script(src, REPO_ROOT)
        patched_src = (
            rendered.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then")
            .replace("/etc/modprobe.d", str(modprobe_dir))
            .replace("/etc/rvdk/deeptune.env", str(dt_env))
            .replace("/etc/apt/sources.list", str(tmp_path / "etc" / "apt" / "sources.list"))
            .replace("/etc/apt/apt.conf.d", str(tmp_path / "etc" / "apt" / "apt.conf.d"))
            .replace("/var/lib/apt/lists", str(tmp_path / "var" / "lib" / "apt" / "lists"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/sys/bus/i2c/drivers/fusb303b", str(tmp_path / "no_i2c"))
        )
        patched = board_dir / "deeptune.sh"
        patched.write_text(patched_src, encoding="utf-8")

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RVDK_P550_HDMI_STATE_FILE": str(tmp_path / "run" / "hdmi.state"),
            "RVDK_P550_PLAT_DRV_BASE": str(tmp_path / "plat"),
            "RVDK_NO_APT_UPDATE": "1",
            "RVDK_KEEP_VENDOR_MIRRORS": "1",
        }

        r1 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r1.returncode == 0, r1.stderr
        assert "Installed fancontrol-config-p550-premier" in r1.stdout
        assert "fancontrol-config-p550-premier" in apt_log.read_text(encoding="utf-8")

        apt_log.unlink()
        r2 = _run_script(patched, ["--tune", "data", "--noprogbar"], env=env)
        assert r2.returncode == 0, r2.stderr
        assert "fancontrol-config-p550-premier already installed" in r2.stdout
        assert not apt_log.exists()

    def test_eic7700x_bootstrap_parameterizes_board_tag_and_omits_p550_fancontrol(self, tmp_path: Path) -> None:
        src = (REPO_ROOT / "bsp" / "eswin" / "eic7700x" / "bootstrap-ubuntu.sh").read_text(encoding="utf-8")
        assert "fancontrol-config-p550-premier" not in src
        assert "90-p550-bsp-protect" not in src
        assert 'rvdk_bsp_persist_wired_nic "p550"' not in src

        fake_root = tmp_path / "bsp_root"
        (fake_root / "etc" / "apt" / "apt.conf.d").mkdir(parents=True)
        (fake_root / "etc" / "sysctl.d").mkdir(parents=True)
        (fake_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (fake_root / "etc" / "netplan").mkdir(parents=True)

        bin_dir = tmp_path / "bin"
        _write_exe(bin_dir / "dpkg", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "apt-get", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(bin_dir / "netplan", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "systemctl",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "is-enabled" ]]; then echo masked; exit 0; fi
if [[ "${1:-}" == "is-active" ]]; then exit 3; fi
exit 0
""",
        )
        _write_exe(bin_dir / "sysctl", "#!/usr/bin/env bash\nexit 0\n")
        _write_exe(
            bin_dir / "ip",
            """#!/usr/bin/env bash
if [[ "$*" == *"link show end0"* ]]; then exit 0; fi
if [[ "$*" == *"route show default"* ]]; then exit 0; fi
exit 1
""",
        )
        _write_exe(bin_dir / "locale", "#!/usr/bin/env bash\nprintf 'C.UTF-8\\n'\n")

        rvdk_ci = _load_rvdk_ci()
        rendered = rvdk_ci.render_standalone_script(src, REPO_ROOT)
        p_rendered = (
            rendered.replace('rvdk_require_root "${BASH_SOURCE[0]:-}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}', "true", 1)
            .replace("/etc/apt/apt.conf.d", str(fake_root / "etc" / "apt" / "apt.conf.d"))
            .replace("/etc/sysctl.d", str(fake_root / "etc" / "sysctl.d"))
            .replace("/etc/systemd/system", str(fake_root / "etc" / "systemd" / "system"))
            .replace("/etc/default/cpufrequtils", str(fake_root / "etc" / "default" / "cpufrequtils"))
            .replace("/etc/netplan", str(fake_root / "etc" / "netplan"))
            .replace("/etc/network", str(fake_root / "etc" / "network"))
            .replace("/etc/os-release", str(fake_root / "etc" / "os-release"))
            .replace("/var/lib/rvdk/backups", str(fake_root / "var" / "lib" / "rvdk" / "backups"))
            .replace("/boot/extlinux/extlinux.conf", str(fake_root / "boot" / "extlinux" / "extlinux.conf"))
            .replace("/boot/efi/extlinux.conf", str(fake_root / "boot" / "efi" / "extlinux.conf"))
            .replace("/etc/openwrt_release", str(fake_root / "etc" / "openwrt_release"))
            .replace("/proc/sys/kernel", str(tmp_path / "no_proc_sys_kernel"))
        )
        patched = tmp_path / "eic_bsp_test.sh"
        patched.write_text(p_rendered, encoding="utf-8")

        base_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_NO_APT_UPDATE": "1", "RVDK_KEEP_VENDOR_MIRRORS": "1"}

        # 1. Unset RVDK_BOARD_TAG defaults to eic7700x
        r_unset = _run_script(patched, ["--noprogbar"], env=base_env)
        assert r_unset.returncode == 0, r_unset.stderr
        assert (fake_root / "etc" / "apt" / "apt.conf.d" / "90-eic7700x-bsp-protect").is_file()
        assert (fake_root / "etc" / "netplan" / "01-eic7700x-end0.yaml").is_file()

        # 2. Explicit RVDK_BOARD_TAG=megrez parameterizes APT protect & netplan files
        for f in (fake_root / "etc" / "netplan").glob("*.yaml"):
            f.unlink()
        r_megrez = _run_script(
            patched,
            ["--noprogbar"],
            env={**base_env, "RVDK_BOARD": "milkv/megrez", "RVDK_BOARD_TAG": "megrez"},
        )
        assert r_megrez.returncode == 0, r_megrez.stderr
        assert (fake_root / "etc" / "apt" / "apt.conf.d" / "90-megrez-bsp-protect").is_file()
        assert (fake_root / "etc" / "netplan" / "01-megrez-end0.yaml").is_file()

    def test_eic7700x_deeptune_probes_active_default_route_nic_before_end0(self, tmp_path: Path) -> None:
        fake_root = tmp_path / "eic_nic_root"
        (fake_root / "etc" / "modprobe.d").mkdir(parents=True)
        (fake_root / "etc" / "systemd" / "system").mkdir(parents=True)
        (fake_root / "usr" / "local" / "sbin").mkdir(parents=True)

        bin_dir = self._setup_fake_bin(tmp_path)
        _write_exe(
            bin_dir / "ip",
            """#!/usr/bin/env bash
if [[ "$*" == *"route show"* ]]; then
    printf 'default via 192.0.2.1 dev enP1p1s0 proto dhcp src 192.0.2.10 metric 100\\n'
    exit 0
fi
exit 1
""",
        )

        # Patch out rvdk_kit_resolve so PRIMARY_NIC probe path in deeptune.sh executes directly
        src = (REPO_ROOT / "bsp" / "eswin" / "eic7700x" / "deeptune.sh").read_text(encoding="utf-8")
        patched_src = (
            src.replace('if [[ "$ACTION" != "status" && "${EUID:-$(id -u)}" -ne 0 ]]; then', "if false; then", 1)
            .replace("typeset -f rvdk_kit_resolve >/dev/null 2>&1 && rvdk_kit_resolve", "true", 1)
            .replace("/etc/modprobe.d", str(fake_root / "etc" / "modprobe.d"))
            .replace("/etc/systemd/system", str(fake_root / "etc" / "systemd" / "system"))
            .replace("/etc/default/cpufrequtils", str(fake_root / "etc" / "default" / "cpufrequtils"))
            .replace("/etc/rvdk/deeptune.env", str(fake_root / "etc" / "rvdk" / "deeptune.env"))
            .replace("/usr/local/sbin", str(fake_root / "usr" / "local" / "sbin"))
            .replace("/sys/devices/system/cpu", str(fake_root / "sys" / "devices" / "system" / "cpu"))
            .replace("/proc/modules", str(tmp_path / "no_modules"))
            .replace("/proc/interrupts", str(tmp_path / "no_interrupts"))
        )
        patched = tmp_path / "eic_nic_probe.sh"
        patched.write_text(patched_src, encoding="utf-8")

        r_probe = _run_script(
            patched,
            ["--tune", "data", "--force", "--noprogbar"],
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_SOC": "eswin/eic7700x", "RVDK_PRIMARY_NIC": ""},
        )
        assert r_probe.returncode == 0, r_probe.stderr
        irq_helper = fake_root / "usr" / "local" / "sbin" / "rvdk-eic7700x-irq-tune"
        assert "PRIMARY_NIC=enP1p1s0" in irq_helper.read_text(encoding="utf-8")

        # When ip route probe finds nothing, falls back cleanly to end0
        _write_exe(bin_dir / "ip", "#!/usr/bin/env bash\nexit 1\n")
        r_fb = _run_script(
            patched,
            ["--tune", "data", "--force", "--noprogbar"],
            env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RVDK_SOC": "eswin/eic7700x", "RVDK_PRIMARY_NIC": ""},
        )
        assert r_fb.returncode == 0, r_fb.stderr
        assert "PRIMARY_NIC=end0" in irq_helper.read_text(encoding="utf-8")

    @pytest.mark.parametrize(
        ("rel_path", "extra_args"),
        [
            ("bsp/eswin/eic7700x/deeptune.sh", ["--tune", "iot", "--force", "--noprogbar"]),
            ("bsp/spacemit/k1/deeptune.sh", ["--tune", "iot", "--force", "--noprogbar"]),
            ("bsp/espressif/esp32p4/deeptune.sh", ["--tune", "iot", "--noprogbar"]),
            ("boards/sifive/p550/deeptune.sh", ["--tune", "iot", "--noprogbar"]),
            ("boards/orangepi/rv2/deeptune.sh", ["--tune", "iot", "--force", "--noprogbar"]),
        ],
    )
    @pytest.mark.parametrize("standalone", [False, True])
    def test_rvdk_sudo_preserve_enforcement_across_bsp_and_board_scripts(
        self,
        tmp_path: Path,
        rel_path: str,
        extra_args: list[str],
        standalone: bool,
    ) -> None:
        if os.geteuid() == 0:
            pytest.skip("Unprivileged sudo escalation test requires non-root UID")

        src_script = REPO_ROOT / rel_path
        src_text = src_script.read_text(encoding="utf-8")
        assert "sudo -E" not in src_text
        assert "rvdk_sudo_preserve" in src_text

        target_script = src_script
        if standalone:
            target_script = tmp_path / f"standalone_{src_script.parent.name}_{src_script.name}"
            target_script.write_text(src_text, encoding="utf-8")
            target_script.chmod(0o755)

        bin_dir = tmp_path / f"bin_{standalone}"
        sudo_log = tmp_path / f"sudo_{standalone}.log"
        _write_exe(
            bin_dir / "sudo",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{sudo_log}"
if [[ "${{1:-}}" == "-n" && "${{2:-}}" == "true" ]]; then
    exit 0
fi
if [[ "${{1:-}}" == --preserve-env=* && "${{2:-}}" == "-n" && "${{3:-}}" == "true" ]]; then
    exit 0
fi
exit 0
""",
        )

        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "BASH_ENV": "/tmp/evil_bashenv.sh",
            "ENV": "/tmp/evil_env.sh",
            "LD_PRELOAD": "/tmp/evil.so",
            "LD_LIBRARY_PATH": "/tmp/evil_lib",
            "XDG_CACHE_HOME": "/tmp/evil_xdg",
            "RVDK_PROGBAR_LIB": "/tmp/evil_progbar.sh",
            "RVDK_APT_LIB": "/tmp/evil_apt.sh",
            "RVDK_TUNE": "iot",
            "RVDK_BOARD": "sifive/p550",
            "RVDK_SOC": "eswin/eic7700x",
        }
        proc = _run_script(target_script, extra_args, env=env)
        assert proc.returncode == 0, proc.stderr

        calls = sudo_log.read_text(encoding="utf-8").splitlines()
        assert len(calls) == 2
        assert "--preserve-env=" in calls[0]
        assert "--preserve-env=" in calls[1]
        for line in calls:
            assert " -E " not in f" {line} "
            for forbidden in (
                "BASH_ENV",
                "ENV=",
                ",ENV,",
                "LD_PRELOAD",
                "LD_LIBRARY_PATH",
                "XDG_CACHE_HOME",
                "PATH",
                "RVDK_PROGBAR_LIB",
                "RVDK_APT_LIB",
            ):
                assert forbidden not in line
        assert "RVDK_TUNE" in calls[1]
        assert "RVDK_BOARD" in calls[1]
        assert "RVDK_SOC" in calls[1]

        # SETENV-denied fallback calls plain sudo once and propagates target exit code
        deny_bin = tmp_path / f"bin_deny_{standalone}"
        deny_log = tmp_path / f"deny_{standalone}.log"
        _write_exe(
            deny_bin / "sudo",
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{deny_log}"
if [[ "${{1:-}}" == --preserve-env=* ]]; then
    echo "sudo: sorry, you are not allowed to set the following environment variables: RVDK_TUNE" >&2
    exit 1
fi
if [[ "${{1:-}}" == "-n" && "${{2:-}}" == "true" ]]; then
    exit 0
fi
exit 23
""",
        )
        deny_proc = _run_script(
            target_script,
            extra_args,
            env={**env, "PATH": f"{deny_bin}:{os.environ['PATH']}"},
        )
        assert deny_proc.returncode == 23
        deny_calls = deny_log.read_text(encoding="utf-8").splitlines()
        assert "--preserve-env=" in deny_calls[0]
        assert " -E " not in f" {deny_calls[-1]} "
        assert "--preserve-env=" not in deny_calls[-1]
