# Pi 5 Kernel Downgrade (LP#2133877 Final Mitigation) Implementation Plan

> **Status:** COMPLETED 2026-04-15. Both Pis on `6.14.0-1019-raspi`, cluster Ready, soaks clean.
>
> **Execution deviations from plan** (all validated):
> 1. **Boot layout** — Ubuntu Pi uses `piboot-try` A/B (`/boot/firmware/current/` + `new/` + `old/` with state files), not a flat `/boot/firmware/vmlinuz` symlink. Plan's Task 7 Step 2 verification paths adjusted accordingly.
> 2. **flash-kernel version-sort veto** — `dpkg -i linux-image-6.14` alone writes 6.17 to `new/` because 6.17 > 6.14 by version sort. Must run `sudo flash-kernel --force 6.14.0-1019-raspi` explicitly. Added as new sub-task 7a.
> 3. **Can't remove running kernel** — Task 7's `apt-get remove` aborts on `linux-image-6.17.0-1011-raspi` (the running kernel) via debconf `removing-running-kernel` check. Split Task 7 into 7a (force flash-kernel before reboot) and 7b (apt remove after reboot validates 6.14). Actual order executed: 5 → 6 → 7a → 9 (reboot) → 7b → 8 (hold) → 10 (uncordon + soak).
> 4. **Rollback note** — Plan assumed bricked-boot required physical SSD recovery. Actually piboot-try provides **automatic firmware-level rollback** — if 6.14 fails to boot, Pi reverts to `current/` (6.17) and piboot-try marks `new/state=bad`. No physical recovery needed for boot failures.
> 5. **Extra package cleanup** — Plan missed `linux-raspi-tools-6.17.0-*`; purge included them. Also hold added on `linux-image-raspi`/`linux-headers-raspi`/`linux-raspi` metapackages to block accidental reinstall.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin Heracles + Nyx to `linux-image-6.14.0-1019-raspi` (pre-LP#2133877 kernel) and retire the structurally-broken watchdog.service mitigation.

**Architecture:**
- 25.10 (questing) only ships 6.17.x-raspi (bug-affected). Plucky-updates (25.04) still hosts the last-good 6.14.x line at 6.14.0-1019.
- Install pulled .debs via `dpkg -i`, then `apt remove` the 6.17 kernels so flash-kernel re-targets `/boot/firmware/vmlinuz` at 6.14.
- `apt-mark hold` the 6.14 packages so unattended-upgrades cannot drag the kernel forward.
- Disable `watchdog.service` — its `interface = eth0` check is RX-only; LP#2133877 is a TX-only wedge and the package cannot detect it. Keep `pi5-eth0-offload.service` as defense-in-depth.
- Stagger Heracles → verify → Nyx so etcd quorum (Hestia + 1 Pi) is preserved throughout.

**Tech Stack:** Ubuntu 25.10 questing, plucky-updates ports pool, dpkg/apt/apt-mark, flash-kernel, systemd, k3s/etcd, ssh.

**Nodes:**
- heracles: 192.168.1.6 (Pi 5)
- nyx: 192.168.1.7 (Pi 5)
- hestia: 192.168.1.5 (amd64, unaffected — stays up throughout)

**Rollback note:** If the 6.14 kernel panics on boot, physical access is required (SSD reader on another machine, edit `/boot/firmware/vmlinuz` symlink back to `vmlinuz-6.17.0-1011-raspi`). This is why we stage Heracles first and observe before touching Nyx.

---

### Task 1: Fetch 6.14.0-1019-raspi .debs to local staging

**Files:**
- Create: `/tmp/pi5-kernel/linux-image-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb`
- Create: `/tmp/pi5-kernel/linux-modules-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb`

- [ ] **Step 1: Create staging dir and fetch both .debs from ports pool**

```bash
mkdir -p /tmp/pi5-kernel && cd /tmp/pi5-kernel && \
  curl -fSL -O "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux-raspi/linux-image-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb" && \
  curl -fSL -O "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux-raspi/linux-modules-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb"
```

- [ ] **Step 2: Verify integrity against plucky-updates Packages.gz SHA256**

```bash
cd /tmp/pi5-kernel && \
  curl -fsSL "http://ports.ubuntu.com/ubuntu-ports/dists/plucky-updates/main/binary-arm64/Packages.gz" | \
  zcat | awk -v RS='' '/^Package: linux-(image|modules)-6\.14\.0-1019-raspi/' | \
  grep -E "^(Filename|SHA256):"
sha256sum linux-image-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb linux-modules-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb
```

Expected: both printed SHA256 hashes match the values in the Packages index. Do not proceed if they differ.

---

### Task 2: Copy .debs to Heracles and Nyx

**Files:**
- Create on each Pi: `/home/ben/pi5-kernel/linux-image-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb`
- Create on each Pi: `/home/ben/pi5-kernel/linux-modules-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb`

- [ ] **Step 1: Make dir on both Pis, then scp both .debs in parallel**

```bash
ssh ben@192.168.1.6 'mkdir -p /home/ben/pi5-kernel'
ssh ben@192.168.1.7 'mkdir -p /home/ben/pi5-kernel'
scp /tmp/pi5-kernel/*.deb ben@192.168.1.6:/home/ben/pi5-kernel/
scp /tmp/pi5-kernel/*.deb ben@192.168.1.7:/home/ben/pi5-kernel/
```

- [ ] **Step 2: Verify sizes match on both Pis**

```bash
ls -la /tmp/pi5-kernel/*.deb
ssh ben@192.168.1.6 'ls -la /home/ben/pi5-kernel/*.deb'
ssh ben@192.168.1.7 'ls -la /home/ben/pi5-kernel/*.deb'
```

Expected: byte counts identical across all three listings.

---

### Task 3: Pre-downgrade snapshot (Heracles)

**Files:** (read-only inspection)

- [ ] **Step 1: Record current kernel, boot symlinks, installed kernel packages, watchdog state, disk free**

```bash
ssh ben@192.168.1.6 'uname -r; echo ---; ls -la /boot/firmware/vmlinuz /boot/firmware/initrd.img 2>/dev/null; ls -la /boot/vmlinuz* /boot/initrd.img* 2>/dev/null; echo ---; dpkg -l "linux-image-*-raspi" "linux-modules-*-raspi" "linux-headers-*-raspi" "linux-raspi-headers-*" "linux-image-raspi" "linux-headers-raspi" "linux-raspi" 2>/dev/null | awk "/^ii/ {print \$2, \$3}"; echo ---; systemctl is-active watchdog.service pi5-eth0-offload.service; echo ---; df -h /boot /boot/firmware /'
```

Expected output contains: `6.17.0-1011-raspi`, `vmlinuz-6.17.0-1011-raspi` referenced, `linux-image-6.17.0-1011-raspi` and `linux-image-6.17.0-1006-raspi` installed, watchdog.service `active`, `/boot/firmware` has at least 400MB free.

- [ ] **Step 2: Save verbatim output to `/tmp/pi5-kernel/heracles-pre.txt` for reference**

```bash
ssh ben@192.168.1.6 'uname -r; ls -la /boot/firmware/vmlinuz /boot/firmware/initrd.img; dpkg -l | grep -E "linux-(image|modules|headers|raspi)"; systemctl is-active watchdog.service pi5-eth0-offload.service' > /tmp/pi5-kernel/heracles-pre.txt
cat /tmp/pi5-kernel/heracles-pre.txt
```

---

### Task 4: Cordon + drain Heracles

**Files:** (cluster state only)

- [ ] **Step 1: Cordon Heracles so new pods don't land there, and drain existing workloads**

```bash
kubectl cordon heracles
kubectl drain heracles --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=5m
```

Expected: command returns `node/heracles drained`. DaemonSet pods (cilium, alloy, node-exporter, pi5-macb-offload — if still present — etc.) remain.

- [ ] **Step 2: Confirm etcd still has quorum**

```bash
kubectl get nodes
kubectl -n kube-system get pods -l app=etcd 2>/dev/null || kubectl get --raw='/readyz?verbose' | grep etcd
```

Expected: `hestia` and `nyx` remain `Ready`; etcd readyz returns `[+]etcd ok`.

---

### Task 5: Stop + disable watchdog.service on Heracles

**Files:** (systemd state only)

- [ ] **Step 1: Stop and disable the broken watchdog unit**

```bash
ssh ben@192.168.1.6 'sudo systemctl disable --now watchdog.service; systemctl is-active watchdog.service; sudo fuser /dev/watchdog0 2>&1 || echo watchdog0-free'
```

Expected: `inactive`, then `watchdog0-free` (no process holds `/dev/watchdog0`).

---

### Task 6: Install 6.14.0-1019-raspi on Heracles

**Files:**
- Create on heracles: `/boot/vmlinuz-6.14.0-1019-raspi`, `/boot/initrd.img-6.14.0-1019-raspi`, `/lib/modules/6.14.0-1019-raspi/`

- [ ] **Step 1: dpkg-install modules first then image (order avoids dep gap)**

```bash
ssh ben@192.168.1.6 'cd /home/ben/pi5-kernel && sudo dpkg -i linux-modules-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb linux-image-6.14.0-1019-raspi_6.14.0-1019.19_arm64.deb'
```

Expected: no errors. `Setting up linux-image-6.14.0-1019-raspi` line in output. `flash-kernel: installing version 6.14.0-1019-raspi` line in output (or a similar flash-kernel line; the postinst invokes it).

- [ ] **Step 2: Verify modules + kernel present**

```bash
ssh ben@192.168.1.6 'ls -la /boot/vmlinuz-6.14.0-1019-raspi /boot/initrd.img-6.14.0-1019-raspi; ls /lib/modules/6.14.0-1019-raspi/ | head'
```

Expected: both files exist, `/lib/modules/6.14.0-1019-raspi/` has `kernel/` and `modules.dep`.

---

### Task 7: Remove 6.17 kernel packages on Heracles

**Files:** (package removal)

- [ ] **Step 1: apt-get remove all 6.17 raspi kernel packages and the metapackages**

```bash
ssh ben@192.168.1.6 'sudo apt-get remove --purge -y linux-image-6.17.0-1006-raspi linux-image-6.17.0-1011-raspi linux-modules-6.17.0-1006-raspi linux-modules-6.17.0-1011-raspi linux-headers-6.17.0-1006-raspi linux-headers-6.17.0-1011-raspi linux-raspi-headers-6.17.0-1006 linux-raspi-headers-6.17.0-1011 linux-image-raspi linux-headers-raspi linux-raspi 2>&1 | tail -40'
```

Expected: removal completes without errors. flash-kernel postrm should run and point `/boot/firmware/vmlinuz` at the 6.14 kernel.

- [ ] **Step 2: Verify /boot/firmware now points at 6.14**

```bash
ssh ben@192.168.1.6 'ls -la /boot/firmware/vmlinuz /boot/firmware/initrd.img; sudo file /boot/firmware/vmlinuz; ls /boot/vmlinuz* 2>/dev/null'
```

Expected: `/boot/firmware/vmlinuz` either is or links to the 6.14.0-1019 kernel. No 6.17 kernels remain under `/boot/`.

- [ ] **Step 3: If /boot/firmware/vmlinuz was NOT retargeted, manually re-run flash-kernel**

```bash
ssh ben@192.168.1.6 'sudo flash-kernel 6.14.0-1019-raspi; ls -la /boot/firmware/vmlinuz'
```

Expected: explicit invocation relinks `/boot/firmware/vmlinuz` to the 6.14 kernel. Only run if Step 2 failed.

---

### Task 8: Pin 6.14 on Heracles

**Files:** (apt state only)

- [ ] **Step 1: apt-mark hold the exact-version kernel packages**

```bash
ssh ben@192.168.1.6 'sudo apt-mark hold linux-image-6.14.0-1019-raspi linux-modules-6.14.0-1019-raspi; apt-mark showhold'
```

Expected: both packages listed in `showhold` output.

---

### Task 9: Reboot Heracles and wait for return

**Files:** (system state)

- [ ] **Step 1: Trigger reboot**

```bash
ssh ben@192.168.1.6 'sudo systemctl reboot'
```

Expected: ssh connection drops.

- [ ] **Step 2: Wait up to 5 min for ssh to come back, confirm uname**

```bash
until ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ben@192.168.1.6 'uname -r' 2>/dev/null; do sleep 5; done
```

Expected: prints `6.14.0-1019-raspi` when heracles is back.

---

### Task 10: Post-reboot verification on Heracles

**Files:** (inspection only)

- [ ] **Step 1: Confirm kernel, offload-fix service, eth0 offloads, watchdog.service disabled**

```bash
ssh ben@192.168.1.6 'uname -r; systemctl is-active pi5-eth0-offload.service; systemctl is-enabled watchdog.service 2>&1; ethtool -k eth0 | grep -E "tcp-segmentation|scatter-gather"; ip -s link show eth0 | head -6'
```

Expected: `6.14.0-1019-raspi`, `active`, `disabled` (or `masked`), `tcp-segmentation-offload: off`, `scatter-gather: off`, eth0 RX/TX counters present.

- [ ] **Step 2: Confirm k3s node returns Ready and uncordon**

```bash
kubectl get nodes
kubectl uncordon heracles
kubectl get nodes
```

Expected: `heracles` `Ready`, `SchedulingDisabled` cleared after uncordon.

- [ ] **Step 3: Soak test — observe for 10 min before touching Nyx**

```bash
for i in 1 2 3 4 5; do sleep 120; kubectl get nodes | grep heracles; ssh ben@192.168.1.6 'uptime; dmesg -T | tail -3'; done
```

Expected: `heracles` remains `Ready` for the full 10 min; no macb/rcu stall messages in dmesg. If anything looks wrong, STOP and investigate before doing Nyx.

---

### Task 11: Repeat Tasks 3–10 on Nyx

**Files:** (all Task 3–10 work, targeting 192.168.1.7 / `nyx`)

- [ ] **Step 1: Run Task 3 (pre-snapshot) with ssh host 192.168.1.7 and output `/tmp/pi5-kernel/nyx-pre.txt`**
- [ ] **Step 2: Run Task 4 (cordon/drain nyx, verify quorum)**
- [ ] **Step 3: Run Task 5 (disable watchdog.service on nyx)**
- [ ] **Step 4: Run Task 6 (dpkg -i 6.14 on nyx)**
- [ ] **Step 5: Run Task 7 (apt-get remove 6.17 on nyx)**
- [ ] **Step 6: Run Task 8 (apt-mark hold on nyx)**
- [ ] **Step 7: Run Task 9 (reboot + wait on nyx)**
- [ ] **Step 8: Run Task 10 (post-reboot verification + 10 min soak + uncordon on nyx)**

Expected: all steps produce the same outputs as for Heracles, adjusted for host 192.168.1.7 / node `nyx`.

---

### Task 12: Update memory file

**Files:**
- Modify: `/home/ben/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/project_pi5_macb_silent_hang.md`
- Modify: `/home/ben/.claude/projects/-home-ben-Documents-Personal-projects-iac-cluster-state/memory/MEMORY.md`

- [ ] **Step 1: Rewrite project_pi5_macb_silent_hang.md**

Replace the Status + Mitigation sections with:

```markdown
## Status — 2026-04-15

**RESOLVED via kernel downgrade.** Both Heracles and Nyx pinned to `linux-image-6.14.0-1019-raspi` (from plucky-updates) — the last 6.14.x raspi kernel, pre-LP#2133877. 6.17.x-raspi is affected across all micro-versions (1003/1004/1006/1011 all reproduced the wedge). `apt-mark hold` applied to prevent roll-forward.

The earlier host-level `watchdog.service` (Debian `watchdog` 5.16 package) approach **did not work and is structurally incapable of working** for LP#2133877: its `interface = eth0` check reads only the RX byte counter from `/proc/net/dev`. LP#2133877 is a **TX-only** descriptor ring wedge — peers keep sending etcd/raft/cilium heartbeats, so RX continues to tick, but all outbound traffic is silently dropped. The check passes, `/dev/watchdog0` keeps getting petted, and no reboot fires. On 2026-04-15 ~10:27 BST both Pis TX-wedged (Nyx k3s logs: `dial tcp 192.168.1.5:2380: i/o timeout`, `dial tcp 192.168.1.6:6443: no route to host`; Heracles journal: RCU preempt stall at 10:28:01). The user manually power-cycled both (`systemd-logind: Power key pressed short` at 10:28:00) — the watchdog never fired.

`watchdog.service` is now stopped and `disabled` on both Pis. `pi5-eth0-offload.service` (systemd oneshot running `ethtool -K eth0 tso off sg off`) is **kept** as defense-in-depth — it reduces but does not eliminate wedge frequency. `/etc/watchdog.conf` and the `wait-online.conf` drop-in are left in place as dead configuration (no harm).
```

Update the Mitigation section heading to `## Mitigation — kernel pin`, describe the install procedure from this plan (dpkg -i + apt remove + apt-mark hold), and note the holds must be checked after each `apt upgrade`. Delete the "What was tried and removed" subsection describing the old DaemonSet work (stale) and replace it with a brief "What didn't work" section summarising the watchdog.service failure mode above.

- [ ] **Step 2: Update MEMORY.md index line**

Replace the existing pi5 line with:

```
- [project_pi5_macb_silent_hang.md](project_pi5_macb_silent_hang.md) — RESOLVED 2026-04-15 via kernel pin to 6.14.0-1019-raspi (from plucky-updates); watchdog.service approach abandoned (RX-only check can't detect TX-only wedge)
```

---

### Task 13: Final cluster verification

**Files:** (cluster state inspection)

- [ ] **Step 1: All nodes Ready, all core workloads running, no restart spikes**

```bash
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl -n default get pods -o wide | grep -E "heracles|nyx" | head -30
```

Expected: all three nodes `Ready` with `6.14.0-1019-raspi` on the Pis and the Fedora kernel on Hestia; no non-Running/non-Succeeded pods in the abnormal list.

- [ ] **Step 2: Clean up staging**

```bash
rm -rf /tmp/pi5-kernel
ssh ben@192.168.1.6 'rm -rf /home/ben/pi5-kernel'
ssh ben@192.168.1.7 'rm -rf /home/ben/pi5-kernel'
```

Expected: directories removed on all three hosts.

---

## Self-Review Notes

- **Spec coverage:** Plan covers the user's request (investigate + downgrade) and my diagnosis (retire the broken watchdog). Tasks 3/5/6/7/8/9/10 implement the downgrade for Heracles; Task 11 repeats for Nyx; Task 12 updates memory; Task 13 verifies end state.
- **Staggering:** Heracles drained + downgraded + 10-min-soaked before Nyx is touched, so etcd quorum (Hestia + 1 Pi) is preserved throughout and any boot-time surprise on 6.14 is caught on one node, not both.
- **Rollback:** If Heracles fails to boot 6.14, Nyx is untouched and still on 6.17. Physical SSD recovery then edits `/boot/firmware/vmlinuz` symlink back to 6.17.0-1011-raspi (not in-plan because it needs a second machine + SSD reader).
- **No new commits to this repo needed.** The existing commit `b048864` already removed the Terraform pi5 modules. Memory file updates live outside the repo.
