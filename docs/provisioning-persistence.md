# Provisioning Persistence Across Firmware Upgrades

Keeping a configured camera's identity and credentials — Wi-Fi, hostname,
timezone, root password, SSH key — and its motor configuration across a
full firmware upgrade.

> This is distinct from `Provisioning-System.md`, which covers first-boot
> auto-provisioning from a network provisioning server. This document is
> about an **already-configured camera surviving `sysupgrade -f`**.

## Background — what a full upgrade destroys

A full upgrade (`sysupgrade -f`) rewrites the entire flash. Two partitions
that hold live configuration are overwritten:

- the **U-Boot environment** partition (see `firmware-image-structure.md`)
- the **config / overlay** partition (`/etc`, `/root`, …)

So a stock `-f` discards Wi-Fi credentials (`/etc/wpa_supplicant.conf`),
hostname, timezone, the root password (`/etc/shadow`) and SSH
`authorized_keys`. A remote or headless camera then returns in
captive-portal mode after every upgrade — effectively unrecoverable
without physical access.

A full upgrade also resets **motor configuration** (`/etc/motors.json`):
pan/tilt GPIO assignment, homing position and direction-reversal markers
revert to the camera profile's build defaults. A PTZ camera still boots,
but comes back mis-homed or with reversed pan/tilt until the provisioning
agent corrects it — and that correction needs a reboot of its own.
Persisting `motors.json` removes the drift, so a configured camera needs
only the single reboot the flash itself performs.

## Overview

Persistence is achieved by three cooperating mechanisms:

1. **Environment preservation** — `sysupgrade` keeps the U-Boot
   environment partition byte-for-byte intact across the flash.
2. **Capture** — when the camera is configured (captive portal or web
   UI), the settings are mirrored into the U-Boot environment; motor
   config is captured by `sysupgrade` itself, just before the flash.
3. **Restore** — on the first boot after an upgrade, the settings are
   copied from the U-Boot environment back into the fresh overlay.

Net effect: **configure once → settings live in the U-Boot environment →
the environment survives `-f` → first boot restores them into the new
overlay.**

The U-Boot environment is the linchpin: it is the one writable area that
(with mechanism 1) survives a full flash.

## 1. Environment preservation (`package/thingino-sysupgrade`)

`sysupgrade` copies the U-Boot environment partition aside before the
flash and writes it straight back afterwards:

- **stage 1**, `backup_env_partition()` — locates the `env` MTD partition
  via `/proc/mtd`, copies it to `/tmp/sysupgrade/env.backup`
  (`cat /dev/mtd<env>`), and range-checks the size.
- **stage 2**, `restore_env_partition()` — after the flash, finds the
  `env` partition again and `flashcp`s the backup straight back onto it.

This is a **raw partition copy** — no `fw_setenv`, no CRC recomputation,
no key-by-key merge.

### Why a raw copy, not `fw_setenv`

Immediately after the flash, `fw_printenv` / `fw_setenv` mis-read the
environment as *"Bad CRC, using default environment"* — a fw-tools
geometry/format mismatch — even though U-Boot itself reads the same
environment without trouble. Any approach that asked `fw_setenv` to
modify the post-flash environment would therefore either:

- write back an environment synthesised from an empty default, dropping
  `bootcmd` / `mtdparts` / `gpio_*` and leaving the camera unbootable; or
- detect the bad read and skip, restoring nothing.

A verbatim partition copy sidesteps fw-tools entirely. The bytes written
back are bytes U-Boot already accepted, so the result is guaranteed
bootable.

### Failure behaviour

Every failure path is non-fatal — the upgrade always proceeds to reboot.
If the backup is missing or fails its size check, stage 2 skips the
restore and the camera boots on the firmware image's default
environment. A skipped restore loses the preserved keys but is fully
recoverable; a clobbered boot environment is not.

### Tradeoff

The environment is preserved wholesale, so it is **not** refreshed with a
new firmware's environment defaults. This is correct for upgrading the
same camera model (the flash partition layout is stable across builds).
A deliberate partition-layout change would require an explicit migration
rather than relying on this mechanism.

## 2. Capturing settings to the environment

### The `provision-env` helper (`/usr/sbin/provision-env`)

A small shell tool with two modes:

- `provision-env snapshot` — reads current overlay state and writes it to
  the U-Boot environment in a single batched `fw_setenv` call.
- `provision-env restore` — the reverse; used on first boot.

Run from a fully-booted system, `fw_setenv` works normally — the
post-flash "Bad CRC" problem in mechanism 1 does not apply here.

All of `provision-env`'s diagnostic output goes to **stderr**: it is
invoked from CGIs whose stdout becomes the HTTP response body.

### Capture hooks

`provision-env snapshot` is invoked after a settings change by:

| Caller | Triggers on |
|---|---|
| `api.cgi` (wifi package) | captive-portal first-boot setup |
| `json-config-network.cgi` | hostname / Wi-Fi change in the web UI |
| `json-config-webui.cgi` | root password change in the web UI |
| `json-config-time.cgi` | timezone change in the web UI |

This keeps the U-Boot environment in step with the camera's current
configuration, whether it was set at first boot or changed later.

### Upgrade-time snapshot (motor config)

Motor configuration has no web-UI capture hook. The provisioning agent
(Dragonfly) writes `/etc/motors.json` over SSH with `jct`, bypassing the
CGIs entirely, so a per-CGI hook would miss it.

Instead, `sysupgrade` runs `provision-env snapshot` itself, immediately
before it backs up the U-Boot environment partition (full upgrades only).
This captures the *live* `/etc/motors.json` however it was set — web UI,
Dragonfly, or a manual SSH edit — and the same call refreshes every other
`prov_*` / `wlan_*` key from the current overlay as a side effect.
`motors.json` is stored whole, base64-wrapped, in `prov_motors`.

## 3. Restoring settings on boot

Restore is split between two init scripts because Wi-Fi recovery has to
integrate with `wpa_supplicant` startup, while the rest does not.

### Wi-Fi — `S38wpa_supplicant`

`credentials_from_uboot_env()` runs at service start. When the current
`/etc/wpa_supplicant.conf` has no usable client credentials (the camera
would otherwise fall back to the captive portal), it reads `wlan_ssid`,
`wlan_pass` and `wlan_ap` from the environment and regenerates the config
via `wlan configure`.

Mode detection was factored into `determine_mode()` so the wireless mode
is re-evaluated *after* credential recovery — the camera connects on the
same boot, with no extra reboot.

Recovery is fallback-only: an existing or user-set config always wins,
and an SD-card `uenv.txt` still takes precedence over the environment.

### Hostname / timezone / root password / SSH key — `S02provision`

`S02provision` runs early (before `S04hostname`) and calls
`provision-env restore`, which writes `prov_*` values from the
environment back into the overlay. It is gated by an `/etc/.provisioned`
marker so it runs **only once per overlay lifetime** — after a wipe, not
on every boot — and so it never overrides a change the user makes later.

### Motor config — `S02provision`

The same `provision-env restore` call merges the saved `motors.json` back
into the overlay: it base64-decodes `prov_motors` and uses `jct import`,
so the saved values land on top of the new firmware's default file. A
newer firmware's *added* keys survive, while the saved
`gpio_pan` / `gpio_tilt` / `dragonfly_*_reversed` / `pos_0` /
`steps_pan` / `steps_tilt` set is restored as one consistent unit —
restoring only some of them would make the provisioning agent re-reverse
the motors.

`S02provision` (init stage 02) runs well before `S59motor` starts the
motor daemon, so the daemon reads the corrected `motors.json` at its
normal first start. The drift is gone before anything consumes the file,
so no extra reboot is needed.

## U-Boot environment keys

| Key             | Holds                              | Restored by         |
|-----------------|------------------------------------|---------------------|
| `wlan_ssid`     | Wi-Fi SSID                         | `S38wpa_supplicant` |
| `wlan_pass`     | Wi-Fi PSK (derived, not the passphrase) | `S38wpa_supplicant` |
| `wlan_ap`       | AP-mode flag                       | `S38wpa_supplicant` |
| `prov_hostname` | hostname                           | `S02provision`      |
| `prov_timezone` | timezone name (`/etc/timezone`)    | `S02provision`      |
| `prov_tzdata`   | POSIX TZ string (`/etc/TZ`)        | `S02provision`      |
| `prov_rootpw`   | root crypt hash, base64-wrapped    | `S02provision`      |
| `prov_sshkey`   | `authorized_keys`, base64-wrapped  | `S02provision`      |
| `prov_motors`   | `/etc/motors.json`, base64-wrapped | `S02provision`      |

Because mechanism 1 preserves the whole partition, every key above
survives an upgrade automatically — the per-key list matters only to the
capture and restore steps.

## End-to-end example

1. A user runs the captive-portal setup: hostname `front-door`, the home
   Wi-Fi, a root password, a timezone.
2. `api.cgi` applies those to the overlay, then `provision-env snapshot`
   writes `wlan_*` and `prov_*` into the U-Boot environment.
3. Months later the camera is upgraded: `sysupgrade -f`. Stage 1 backs up
   the environment partition; the flash rewrites the whole flash; stage 2
   writes the backup back byte-for-byte. The environment survives intact.
4. The new firmware boots with a default overlay. `S02provision` restores
   hostname / timezone / root password / SSH key from the environment;
   `S38wpa_supplicant` restores Wi-Fi. The `/etc/.provisioned` marker is
   then set.
5. The camera rejoins the home Wi-Fi as `front-door` with its password
   and timezone intact — no physical visit required.

## Security considerations

Storing credentials so they can be restored is a deliberate tradeoff;
the design minimises its cost:

- **No plaintext secrets.** The root password is stored as its
  `/etc/shadow` sha512 crypt hash; Wi-Fi is stored as the derived PSK —
  exactly the forms already on the device in `/etc/shadow` and
  `/etc/wpa_supplicant.conf`. The SSH key stored is the *public* key.
  The hash and key are base64-wrapped only to survive transport, not as
  obfuscation.
- **No new exposure surface.** These values already exist on the camera.
  The environment partition holds an additional copy on the **same
  soldered flash** as the rootfs and overlay — there is no removable
  medium involved. Extracting it requires a flash clip or desoldering and
  a dump, not a tool-free pull.
- **A camera that stores Wi-Fi credentials can always leak them.** Any
  camera that auto-connects to Wi-Fi must hold the credentials in some
  recoverable form. Treat a physically stolen camera as a disclosed
  credential regardless of this feature, and keep cameras on a segmented
  VLAN.

If a deployment cannot accept credentials surviving on the device at all,
do not configure the camera through the portal/web UI — but then it
cannot self-recover Wi-Fi after an upgrade either.

## Limitations

- **The upgrade that installs this feature cannot use it.** That upgrade
  is performed by the *previous* firmware's `sysupgrade`. Persistence
  takes effect from the next `-f` onward.
- The environment is preserved wholesale and does not adopt a new
  firmware's environment defaults (see the mechanism 1 tradeoff).
- `provision-env restore` is fallback-only (gated by `/etc/.provisioned`).
  A configuration change made after an upgrade is captured normally by
  the capture hooks on the next change.
- Motor config is merged with `jct import`, not copied wholesale, so a
  new firmware's *added* `motors.json` keys take effect; only keys the
  camera had previously set are carried across. Unlike the other
  `prov_*` keys it is captured only at upgrade time, not on every
  change — which is sufficient, since the snapshot reads the live file.

## Testing / verification

There is no automated test target; verify on hardware.

1. Build firmware with this change and flash it to a camera. *(This first
   flash does not exercise persistence — see Limitations.)*
2. Configure the camera via the captive portal or web UI: set a
   distinctive hostname, the Wi-Fi network, a root password, a timezone.
3. Confirm the environment was captured:
   ```sh
   fw_printenv | grep -E '^(wlan_|prov_)'
   ```
   Expect `wlan_ssid`, `wlan_pass`, `prov_hostname`, `prov_timezone`,
   `prov_rootpw`, etc.
4. Upgrade again: `sysupgrade -f` with the same or a newer build.
5. After reboot, verify persistence:
   - the camera rejoined the configured Wi-Fi;
   - `hostname`, `cat /etc/timezone`, and the root password are retained;
   - on a PTZ camera, `motors.json` kept its `gpio_*` /
     `dragonfly_*_reversed` / `pos_0`, and the camera homes correctly
     with no second reboot;
   - `/etc/.provisioned` exists.
6. Negative check: on a camera with no prior configuration, confirm a
   full upgrade still boots and falls back to the captive portal cleanly.

### Recovery

If the U-Boot environment is ever left in a bad state, at the U-Boot
serial prompt:

```
env default -a -f
saveenv
reset
```

This restores U-Boot's built-in defaults and boots the camera; it can
then be reconfigured normally.
