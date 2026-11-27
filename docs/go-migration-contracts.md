# RVDK Go Migration Contracts (`schema_version: 1`)

This document defines the stable CLI, machine-readable JSON, declarative catalog, and privilege-boundary contracts between the current POSIX/Bash engine (`riscv-data-kit`) and future incremental single-binary Go (`riscv64` / `arm64` / `amd64`) subcommand implementations.

---

## 1. Strangler-Fig Migration Architecture

Subcommands migrate incrementally behind the `rvdk` entrypoint (`bootstrap.sh`) without breaking existing CLI invocations, exit codes, or idempotent `[SKIP]` convergence semantics.

- **Public CLI Invariant:** Existing subcommand names (`day0`, `bsp`, `os`, `kit`, `flash`, `storage`, `quirk`, `deeptune`, `uninstall`, `mods/*`, `postgresql/*`) and existing flags must remain backward-compatible.
- **Additive Machine-Readable Flag:** Read-only inspection commands support `--json` emitting RFC 8259 JSON with a top-level integer `"schema_version": 1`.
- **Single-Source Declarative Data:** Hardware/image metadata and prebuilt module digests are stored in versioned JSON catalogs rather than duplicated inside shell scripts.

---

## 2. Exit Code Contract

| Exit Code | Meaning |
| --- | --- |
| `0` | Success or idempotent convergence (`[SKIP]`) |
| `1` | Fatal validation error, safety interlock refusal, integrity/SHA-256 failure, or runtime error (`[RVDK:FATAL]`) |

All structured `--json` responses emit strictly to `stdout`; warnings and fatal diagnostics emit to `stderr` (or human-readable `stdout` only when `--json` is not requested).

---

## 3. `rvdk kit --json` (`schema_version: 1`)

Produced by `rvdk_kit_print_json` in `lib/kit.sh` and invoked via `rvdk kit --json [--board <id>] [--soc <id>] [--os <id>] [--no-cache]`. Runs unprivileged unless `--refresh` is passed on Linux.

```json
{
  "schema_version": 1,
  "kit_schema": "2",
  "dt_model": "SiFive HiFive Premier P550",
  "board": "sifive/p550",
  "board_tag": "p550",
  "soc": "eswin/eic7700x",
  "soc_slug": "eswin-eic7700x",
  "arch": "riscv64",
  "mmu": "sv39",
  "factory_user": "ubuntu",
  "os_id": "ubuntu",
  "os_version_id": "24.04",
  "primary_nic": "end0",
  "cpu_harts": 4,
  "kit_cache_file": "/etc/rvdk/kit.env",
  "kit_source": "probe",
  "active_tune": "edge",
  "deeptune_chain": [
    "os/deeptune.sh",
    "bsp/eswin/eic7700x/deeptune.sh",
    "boards/sifive/p550/deeptune.sh"
  ],
  "quirks": [
    "fusb",
    "hdmi"
  ]
}
```

### Field Guarantees
- `schema_version`: integer `1`.
- `cpu_harts`: non-negative integer when detected, otherwise `null`.
- `deeptune_chain`: ordered array of repo-relative paths executed during `rvdk deeptune`.
- `quirks`: sorted array of quirk basenames under `boards/<board>/quirks/*.sh`.
- All remaining string fields default to `""` when unknown.

---

## 4. `rvdk storage status --json` (`schema_version: 1`)

Produced by `print_status_json` in `utils/storage.sh` and invoked via `rvdk storage status --json [--vg <vg_name>]`.

```json
{
  "schema_version": 1,
  "vg_name": "vg_rvdk",
  "vg_size_bytes": 107374182400,
  "vg_free_bytes": 21474836480,
  "vg_extent_bytes": 4194304,
  "vg_extents_total": 25600,
  "vg_extents_free": 5120,
  "vg_reserve_pct": 20,
  "lvs": [
    {
      "name": "lv_data",
      "path": "/dev/vg_rvdk/lv_data",
      "size_bytes": 42949672960,
      "extents": 10240,
      "mounted": true,
      "mount_point": "/mnt/nvme_data",
      "fstype": "xfs",
      "fs_size_bytes": 42949672960,
      "fs_used_bytes": 17179869184,
      "fs_avail_bytes": 25769803776,
      "fs_util_pct": 40
    }
  ]
}
```

### Field Guarantees
- `schema_version`: integer `1`.
- All byte counts, extent counts, and percentages are base-10 JSON integers (`0` when unmounted or unavailable).
- `lvs[].mounted`: JSON boolean (`true` / `false`).
- `lvs[].mount_point`: absolute path string when `mounted == true`, otherwise `null`.

---

## 5. Declarative Catalog Contracts

### 5.1 Board Media Manifests (`boards/<vendor>/<board>/media.json`)
Validated by `tools/rvdk_ci.py:check_manifests` and `check_kit_board_aliases`:
- `schema_version`: `1` (required).
- Required keys: `board`, `tag`, `soc`, `media`, `quirks`.
- Optional `arch`: `"riscv64"` or `"riscv32"`.
- Any `media.<medium>` declaring `image` in `raw` or `uboot_ext4` mode must carry a 64-character lowercase hex `sha256` pin.

### 5.2 Prebuilt Module Bundle Catalog (`catalog/bundles.json`)
Validated by `tools/rvdk_ci.py:check_bundle_catalog`:
- `schema_version`: `1` (required).
- `release_tag`: valid release tag token (e.g. `"rvdk-v1"`).
- `bundles.<module>.<version>.<target_slug>`: object with non-empty `bundle` filename, 64-character lowercase hex `sha256`, and `release_tag`.
- Fail-closed rule: custom bundle URLs or `--prebuilt-only` invocations without a matching pinned digest must fail with exit code `1`; default unpinned invocations without `--prebuilt-only` emit a warning and fall back to verified source compilation.

---

## 6. Privilege Boundary & Shared Primitives

- **Strict `sudo` Preservation Allowlist (`lib/common.sh:_RVDK_SUDO_PRESERVE_ALLOWLIST`):**
  - `sudo -E` is forbidden repo-wide (`tools/rvdk_ci.py:check_sudo_dash_e`).
  - Execution-path and trust-root steering variables (`RVDK_ENGINE_DIR`, `RVDK_BASE_URL`, `RVDK_REPO_URL`, `RVDK_BOARDS_DIR`, `RVDK_ENV_FILE`, `RVDK_SYSTEMD_UNIT_DIR`, `RVDK_RELEASE_BASE`, `RVDK_MIRROR_URL`, `RVDK_STATE_DIR`, `RVDK_BACKUP_ROOT`, `RVDK_KIT_CACHE_FILE`, `RVDK_P550_PLAT_DRV_BASE`, `RVDK_PROGBAR_LIB`, `RVDK_APT_LIB`, `XDG_CACHE_HOME`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `BASH_ENV`, `ENV`, `PATH`) must NEVER be preserved across privilege escalation (`tools/rvdk_ci.py:check_sudo_preserve_allowlists`).
  - Any future Go CLI invoking `sudo` must preserve the exact same non-privileged operational/UI subset.
- **Canonical Mirror Normalization (`lib/common.sh:RVDK_CN_MIRROR_HOSTS_RE`):**
  - Shared single source of truth via `rvdk_cn_mirror_hosts_regex()` consumed by `lib/apt.sh`, `install-cli.sh`, and `os/bootstrap-openwrt.sh`.
- **Storage Guard Invariants (`lib/storage_guard.sh`):**
  - Live OS/swap/LVM wipe-protection guards and explicit `--force-wipe` + `--yes`/TTY confirmation gates are mandatory across all block-mutating workflows.
