# Migration plan: Leap 15.6 → Tumbleweed

Status: done (2026-11-10). All 13 nodes run Tumbleweed `tumbleweed-2.2.0-rc.1` with k3s v1.37.2+k3s1.

## Background

- Leap 15.6 is probably end-of-life (support believed to have ended around April 2026; not verified).
- Leap 16.0 was tried before: the nodes could not mount Ceph volumes.
- Cause: the Leap 16.0 kernel does not ship `ceph.ko` (the CephFS kernel client) in any
  package. `rbd.ko` and `libceph.ko` are still there, so RBD volumes should work; CephFS
  kernel mounts fail.
- Tumbleweed `kernel-default` (7.3.1, aarch64) ships `ceph.ko`, `rbd.ko` and `libceph.ko`.
- Ceph-CSI pods bring their own Ceph userspace; the host only needs the kernel modules.
- A Kairos upgrade replaces the whole OS image (active/passive), so a distro switch via
  system-upgrade-controller works mechanically. As far as we know Kairos does not
  officially support or document it. The boot partition (Pi firmware, bootloader,
  possibly device trees) is **not** updated by an upgrade.
- Published images contain `/usr/sbin/suc-upgrade` (checked on `1.2.0-test`).

## Version 1: original plan

1. Create an image with the same k3s version.
2. Deploy it to a node.
3. Move a workload using Ceph volumes there (Paperless, as it uses both types of Ceph
   volumes afaik).
4. If that works: roll it out everywhere, then update the k3s version.
5. If it doesn't work: try Debian and target the same node again.
6. If that is not possible either: pull each Pi and provision the image onto the
   connected disk.

## Version 2: plan with refinements

### 1. Build the image
- Start a new branch from `main`. Don't reuse `feature/tumbleweed`: it has k3s v1.34.2,
  kairos-init v0.5.29 and the old action versions. Copy its `permissions:` block and
  `prefix=tumbleweed-`.
- Change only the base image: keep k3s `v1.35.2+k3s1`, kairos-init v0.7.4 and the `ceph`
  stage extension.
  - Update 2026-11-10: kairos-init v0.7.4 fails on Tumbleweed (`systemctl disable wicked`,
    and Tumbleweed has no `wicked.service`). Bumped to v0.8.14; v0.8.0 is the release that
    skips this step on Tumbleweed and has no other changes. Branch:
    `feature/tumbleweed-migration`.
  - Build moved to a native `ubuntu-24.04-arm` runner: ~2.5 min instead of 15–20 min.
  - Done 2026-11-10: `ghcr.io/elkiwos/kairos-rpi4-image:tumbleweed-2.0.0-rc.1`
    (digest `sha256:4f8760e0…`). Checked: Tumbleweed 20261108, kernel 7.3.1 with
    `ceph.ko`/`rbd.ko`/`libceph.ko`, k3s v1.35.2+k3s1, `/usr/sbin/suc-upgrade` present,
    systemd-networkd enabled, `latest` unchanged.
  - Finding: the `ceph` stage extension has never run. It needs kairos-init's `-x`
    (`--stage-extensions`) flag, which was removed in commit `b822719`. So neither the
    Leap 1.x images nor this one contain the `ceph` package, and Ceph mounts worked on
    Leap 15.6 without it.
- Pin Tumbleweed by digest, not `:latest`, so the tested image and the rolled-out image
  are the same.
- Use a test version, for example `2.0.0-rc.1`. With `latest=auto` it won't move `latest`.

### 2. Deploy to one canary node
- Choose a worker node, not a k3s server, and not a node whose Ceph mon is needed for quorum.
- Make sure you have physical access to it, in case it doesn't boot and you need to pick
  the fallback entry.
- Run `ceph osd set noout`, then apply a Plan with a `nodeSelector` for that one hostname.
- Check before moving any workload:
  - `/etc/kairos-release` shows Tumbleweed
  - `modprobe ceph rbd` works
  - the node is Ready
  - the node's OSDs and mon rejoin, `HEALTH_OK`
- Run `ceph osd unset noout`.

### 3. Test the Ceph volumes
- First a throwaway pod on the canary with one new RBD PVC and one new CephFS PVC:
  mount both, write and read a file.
- Then move Paperless, after a backup or snapshot. Check its PVCs to confirm it really
  uses both volume types.

### 4. Roll out everywhere
- One node at a time (`concurrency: 1`), `HEALTH_OK` between nodes.
- Upgrade the k3s servers last. Keep `noout` set for the whole rollout.

### 5. Update k3s
- k3s is built into the image, so this is another image build and rollout.
- Don't skip k3s minor versions.

### 6. If it fails, work out how first
- The node doesn't boot: most likely the boot-partition firmware, which would hit Debian
  too. Fall back to the passive Leap image. Trying Debian on the same node probably
  won't help.
- It boots but Ceph mounts fail: investigate before switching distros, since `ceph.ko`
  should be there.
- Debian is a bigger change than Tumbleweed: a different distro family, and the network
  setup and persistent `/etc` may not carry over cleanly.

### 7. Last resort: reprovisioning
Before pulling a Pi, check where the Ceph data lives on it:
- If the OSDs are on the disk that gets reflashed, that OSD's data is lost and Ceph copies
  it again from the other nodes.
- If the mon state is in `/var/lib/rook`, that node's mon has to be rebuilt.

## Outcome (2026-11-10)

- Canary rk8s-node10 on `tumbleweed-2.0.0-rc.1`: booted with the old Pi firmware; RBD and
  CephFS mounts and Paperless worked.
- Tumbleweed rollout to all 13 nodes with k3s v1.35.2, then k3s v1.36.6 (`2.1.0-rc.1`) and
  v1.37.2 (`2.2.0-rc.1`). Builds take ~2.5 min on the native arm64 runner.
- NFS client is present on Tumbleweed.

## Lessons learned

- **Never take down two Ceph OSD nodes at once.** `ceph-blockpool` is size 2 / min_size 1: with
  one OSD down and another drained, PGs go `down` and RBD I/O stops.
- **A drained OSD node can deadlock its own upgrade.** `kairos-agent upgrade` calls `sync()`
  after moving `active.img` to `passive.img`. If RBD data can't be flushed because PGs are
  down, `sync()` blocks, the SUC job hits its deadline, and the node is left with
  `passive.img` + `transition.img` (labelled COS_ACTIVE) and **no `active.img`**. Fix: get Ceph
  healthy (uncordon so the OSD returns), then on the node:
  `mount -o remount,rw /run/initramfs/cos-state; mv cOS/transition.img cOS/active.img; sync;
  mount -o remount,ro …; reboot`.
- **Put every Ceph daemon host in a gated lane.** OSD hosts: node07, node08, node09. Mon hosts:
  node04, node05, node09. node08 was first in the worker lane by mistake and caused a ~40 min
  outage of 75 PGs.
- **Boot assessment works.** node08's first boot of 2.2.0 timed out waiting for
  `/dev/disk/by-label/COS_STATE` and ended in emergency mode (ping yes, ssh no). After a PoE
  power cycle GRUB booted the passive image with `upgrade_failure`. To retry the active image:
  `grub2-editenv /run/initramfs/cos-state/boot_assessment unset boot_assessment_tentative`
  (state partition remounted rw) and reboot. Watch node08's USB-SATA adapter.
- **SUC:** a failed job for the current plan hash blocks a `concurrency: 1` lane. Either delete
  the job (SUC reruns it; `suc-upgrade` exits "Up to date") or mark the node done with
  `plan.upgrade.cattle.io/<plan>=<latestHash>`. The drain is now eviction-based, so Rook's
  OSD/mon PDBs are respected.

## Lanes (system-upgrade-controller)

| Lane | Plan | Label `k3s-upgrade` | Nodes |
|---|---|---|---|
| masters | `os-upgrade-masters` | `master` | master01–03 |
| mons | `os-upgrade-mons` | `mons` | node04, node05 |
| storage | `os-upgrade-storage` | `storage` | node07, node08, node09 |
| workers | `os-upgrade` | `true` | node01, node02, node03, node06, node10 |

All plans have `concurrency: 1`. Order: masters, then node09 (OSD + mon) alone, then the other
lanes in parallel, releasing each storage node only when Ceph is `active+clean`. Plan
definitions: `rk8s` Flux repo, `apps/core/suc/plan.yaml` (applied by hand).

## Open questions
- Promote the rc images to final versions and merge `feature/tumbleweed-migration` into `main`.
- Ceph: insecure auth keys (`HEALTH_ERR`), low disk for mon `bg` on node05.
- The `ceph` stage extension never runs (no `-x`); remove it or wire it up.
