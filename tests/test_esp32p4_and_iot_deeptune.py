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
    REPO_ROOT / "bsp" / "spacemit" / "k1" / "deeptune.sh",
    REPO_ROOT / "boards" / "sifive" / "p550" / "deeptune.sh",
    REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "forge.sh",
    REPO_ROOT / "bsp" / "espressif" / "esp32p4" / "deeptune.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "flash-sd.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "deeptune.sh",
    REPO_ROOT / "boards" / "waveshare" / "esp32-p4-wifi6" / "quirks" / "c6-sdio.sh",
]

NEW_SH_FILES = [
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
        assert kit_env.read_text(encoding="utf-8") == kit_text

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
