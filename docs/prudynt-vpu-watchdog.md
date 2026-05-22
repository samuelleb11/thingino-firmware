# Prudynt VPU guard & encoder watchdog

## The problem

prudynt's default [`prudynt.json`](../package/prudynt-t/files/prudynt.json)
enables four IMP encoder channels:

| Stream  | Role                 | RTSP / output        | Priority   |
|---------|----------------------|----------------------|------------|
| stream0 | H264 main            | `ch0`                | essential  |
| stream1 | H264 sub             | `ch1`                | important  |
| stream2 | JPEG snapshot (main) | `/tmp/snapshot.jpg`  | useful     |
| stream3 | JPEG snapshot (sub)  | `/tmp/snapshot_ch1.jpg` | least   |

That is four hardware VPU encoder channels. Budget SoCs — notably the **T23**
— cannot run four. The 4th `IMPEncoder::init()` fails with
`vpu channel run failed`, which wedges the whole encoder: stream0 never emits
its SPS/PPS, RTSP `DESCRIBE ch0` returns **404**, and prudynt spins forever
retrying the IDR (high CPU, no media). A plain restart does not help — the
overcommit is deterministic.

## The fix — two layers

### 1. Prevention: preflight channel trim

[`prudynt-vpu-guard`](../package/prudynt-t/files/prudynt-vpu-guard)
(`/usr/sbin/prudynt-vpu-guard`) is run by
[`S31prudynt`](../package/prudynt-t/files/S31prudynt) **before** prudynt
launches. It reads the SoC family (`soc -f`) and trims the enabled channel
count to a SoC-safe maximum, dropping the least important streams first
(stream3, then stream2, then stream1).

The per-SoC limit lives in `soc_max_channels()` in the guard script —
currently `t23 → 3`, everything else `→ 4`. Extend that table as field
evidence accumulates.

### 2. Self-heal: the encoder watchdog

[`S32prudyntwd`](../package/prudynt-t/files/S32prudyntwd)
(`/etc/init.d/S32prudyntwd`) runs a background loop that probes RTSP `ch0`
with a `DESCRIBE` every 30 s. A registered media session answers `200`
(or `401` when auth is required); a wedged encoder never registers it, so
live555 answers `404`.

On a confirmed wedge it escalates:

1. **Restart** prudynt once — clears transient bring-up races.
2. **Degrade** — drop the next channel (stream3 → stream2 → stream1) and
   restart. The change is written to `/etc/prudynt.json` so it persists
   across reboots.
3. **Alert** — once only stream0 is left and it is still wedged, stop
   degrading, publish `state: alert`, and back off to a 30 min poll.

The watchdog never disables stream0, so the camera always keeps (or returns
to) a working main RTSP stream when at all possible.

## Status file (for fleet management)

The guard publishes live status to **`/run/prudynt-vpu-guard.status`** as
JSON. Poll this to monitor encoder health across a fleet:

```json
{
  "state": "healthy",
  "soc": "t23",
  "max_channels": 3,
  "active_channels": 3,
  "disabled_streams": "stream3",
  "updated": 1747900000,
  "updated_iso": "2026-05-22T12:00:00Z",
  "message": "stream0 RTSP session registered"
}
```

`state` values: `configured` (preflight done), `healthy` (RTSP confirmed up),
`wedged` (encoder failure, recovering), `down` (prudynt not running),
`alert` (unrecoverable — needs attention), `disabled` (guard opted out).

A camera running fewer channels than `max_channels`, or in `alert`, is the
signal a fleet manager should surface.

## Manual controls

```sh
prudynt-vpu-guard status     # show current status JSON
prudynt-vpu-guard probe      # exit 0 healthy / 1 wedged / 2 down
prudynt-vpu-guard reset      # undo watchdog degradation, re-apply SoC baseline
```

`reset` re-enables stream1/2/3 and re-runs preflight; use it after a prudynt
update that is expected to lift the channel limit.

## Opting out

Multi-sensor rigs (`multi_sensor.enabled: true`) are skipped automatically —
they intentionally drive extra channels. To force the guard off for a
specific camera, add to its `prudynt.json` override:

```json
{ "vpu_guard": { "enabled": false } }
```

With the guard off, preflight does not trim and the watchdog only restarts
(it never degrades channels).

## Upstream note

The complete fix belongs in `themactep/prudynt-t`: cap encoder channels per
SoC, and skip a channel whose `IMPEncoder::init()` fails instead of letting
it wedge stream0. The guard + watchdog here are firmware-side mitigation.
