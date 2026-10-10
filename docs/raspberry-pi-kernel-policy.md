# Raspberry Pi kernel and boot recovery policy

## Accepted kernel

Heracles and Nyx use the official Ubuntu Raspberry Pi kernel
`6.14.0-1019-raspi`, package version `6.14.0-1019.19`. This is a deliberately
accepted EOL kernel exception for the unresolved RP1/macb Ethernet fault. The
userspace release does not select the approved kernel. A new root filesystem,
rescue clone, package reinstall, or migration must preserve the kernel policy,
not inherit the newest kernel from the source image.

Do not promote 6.17/7.0 or a custom build as a substitute. A replacement needs
an authenticated official package, the actual upstream correction in that
build, and native boot, controller, storage, network and workload qualification.
The upstream correction is [macb transmit timeout recovery](https://github.com/torvalds/linux/commit/e438ec3e9e95cd3f49a8120e5f63ae3f9606e6fa);
release numbering alone does not prove inclusion. See also
[Ubuntu LP#2133877](https://bugs.launchpad.net/ubuntu/+source/linux-raspi/+bug/2133877).

### Package and staging ownership

Nyx's `/etc/apt/preferences.d/raspi-kernel-policy` and native `apt-mark`
holds own its exception. Preserve Heracles's independently established pin;
do not assume its preference filename or package inventory matches Nyx. Retain the exact image/modules version; do not rely
on an image-package hold alone while a newer installed kernel or metapackage
can still win flash-kernel's version sort. After qualification on 6.14, remove
only authenticated superseded kernel packages using an inspected native APT
transaction. Never autoremove broadly or remove a running/accepted kernel.

Before any reboot after a firmware/initramfs/package trigger:

- Require a clean `dpkg --audit`.
- Read the installed `piboot-try` interface and actual current/new/old state.
- Authenticate current **and staged** kernel, initramfs and matching boot assets.
- Preserve independent rescue and current assets; do not infer boot identity
  from `/boot/vmlinuz` alone.
- Use supported explicit staging `flash-kernel --force 6.14.0-1019-raspi`
  only under the maintained boot protocol. Installing the debs alone does not
  establish the staged version.
- Preserve authoritative application data and live etcd membership. Boot
  rollback is not permission to restore an old root, database or etcd snapshot.

## Nyx independent recovery topology

Production remains the existing T7/XFS root. Kingston has its own FAT and ext4
rescue root with the same official 6.14 kernel; it must not start production
writers or a stale K3s/etcd instance. The December 2025 EEPROM executable build
is retained; selector changes are configuration changes to that captured build,
not an upgrade to `latest`.

The supported USB selector uses VID/PID exclusions and a high-partition alias:

```ini
[all]
USB_MSD_EXCLUDE_VID_PID=09511666
[partition=62]
PARTITION=1
USB_MSD_EXCLUDE_VID_PID=04e84001
[all]
```

Normal selection excludes Kingston. Requested partition 62 excludes the T7 and
maps to Kingston's actual FAT partition 1. This is **not** a USB serial selector;
replacing hardware requires re-authenticating physical devices and identities.

Enduring watchdog routing is:

- Production normal boot/loading/runtime: target 62 (independent Kingston).
- Production rejected tryboot: target 1 (accepted production current).
- Kingston loading/runtime: target 1 (production).

EEPROM normal `BOOT_WATCHDOG_PARTITION=62` is overridden to 1 in `[tryboot]`
and `[partition=62]`. Production `kernel_watchdog_partition=62` is overridden
to 1 in `[tryboot]`; rescue uses 1. The loading/open watchdog is finite and
normal PID1 takes over hardware feeding. Reading configuration alone does not
qualify these routes: retain real distinct boot IDs, firmware-consumed source
marker plus USB-source tuple, correct FAT/root/kernel, actual descriptor owner
and timer expiry, and automatic return without an explicit reboot request.

Do not decode requested partition 62 from `rsts` alone or require a 7.0-specific
`early-watchdog` DT marker on 6.14. Verify the actual boot source and hardware
behaviour. An old/ slot is not automatic fallback from a promoted-current hang.

### Limits and maintenance

A/B and watchdog routing cannot guarantee survival of board, power, shared
firmware/device corruption, or a management/network hang while PID1 continues
to feed. Independent rescue improves the boot-software failure domain; physical
recovery remains an emergency option, not a planned qualification step.

Never invoke a lifecycle script with `--help` before inspecting its parser:
`k3s-killall.sh` ignores that argument and performs shutdown/cleanup. Maintenance
must preserve other members' quorum, quiesce protected writers, use supported
native interfaces, recover persisted receipts after a transport timeout, and
never repeat a boot/reset merely because an observer failed.

Retire task-owned validation conditions, overrides and offload workarounds only
after qualification. Restore original reconciliation, replica and scheduling
policy and verify real endpoints. A cold private-image authentication failure
is not a kernel failure: boot-critical drivers must use admitted immutable
images through the existing Kustomize image mechanism, with `IfNotPresent` to
avoid unnecessary JWT authentication for locally available unchanged software.
This does not guarantee recovery after image GC; missing-image recovery still
requires the registry and its authentication service.

The historical April downgrade execution plan is evidence, not the current
boot protocol or permission to reuse its physical-recovery assumptions.
