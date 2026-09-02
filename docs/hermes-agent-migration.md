# Hermes Agent migration to Kubernetes

This runbook moves the Hestia user-service Hermes gateway into the Flux-managed `default` namespace. The source is `/home/ben/.hermes`; the target is the retained `hermes-agent-state` 20 Gi `local-path-retain` PVC on Hestia.

> **Singleton rule:** only one active Hermes gateway authority is permitted. The Hestia `hermes-gateway.service` and the Kubernetes gateway must never run concurrently. Stop and resolve any uncertain authority state rather than proceeding.

The image is pinned by tag and digest. The API and webhook are ClusterIP-only; there is no Ingress. The copied `config.yaml`, `.env`, and `auth.json` on the state PVC remain the credential and configuration authority. Never paste their contents into Git, command output, tickets, or chat.

## Migration controls

`scripts/hermes-agent-migration.sh` must run as Ben on Hestia with the normal user systemd session and `/home/ben/.kube/config`. It has no implicit mutation: every write requires one of the explicit `initial-sync`, `final-sync`, or `rollback` subcommands. `preflight` is read-only. Run `final-sync` and `rollback` from a separate SSH/TTY or transient user unit outside the running Hermes gateway process: an in-gateway terminal is intentionally fenced from stopping its own parent gateway.

The sync is deliberately selective. It copies durable configuration, channel routing/thread state and aliases, webhook subscriptions and HMAC material, the allowlisted SQLite databases, pending-message recovery, sessions, skills, plugins, hooks, cron, memories, platform and pairing state, MCP tokens, scripts, plans, workflows, Kanban state, and only the five operational profiles. Nested symlinks are preserved without following them, but each allowlisted profile and database itself must be absent or the expected regular directory/file; symlinks, including dangling symlinks, and other path types fail closed. It recursively excludes source checkouts/workspaces, `.git`, virtual environments, dependency trees, caches, logs, backups, checkpoints, temporary directories, profile `bin`, and profile LSP state.

For the initial sync, the script first captures `/home/ben/.hermes` with a component-by-component `O_NOFOLLOW` host walk, then creates verified SQLite online backups on Hestia in a bounded host-side step using a fresh mode-0700 directory under `/var/tmp`. It writes an exact version-2 manifest containing the source-root identity, the absent/present and path-type state of every allowlisted top-level database, profiles parent, profile, and profile database, and the device/inode identity of every present directory. Devices are exact nonnegative integers, inodes are exact positive integers, and absent directory identities are exactly null. Each present staged database also carries its exact nonnegative byte size and lowercase SHA-256; the manifest contains no database contents or secrets. Before Kubernetes resolves the source hostPath, the host root identity is rechecked. The pod then compares the mounted `/source` root with that host proof and the manifest before any target mutation.

Both host staging and pod preflight open the complete fixed source path, `profiles` parent, and present allowlisted profile directories with no-follow descriptor walks, so dangling links, external-directory links, and same-shape directory replacement fail closed instead of being interpreted as absence or followed. The pod parses the bounded manifest with duplicate-key and non-finite-value rejection, requires exact schema and membership, and rejects missing, extra, wrong-type, wrong-identity, wrong-size, or wrong-digest staging content. It retains the source-root, profiles-parent, and profile descriptors through the entire copy; later selected reads are rooted at those descriptors rather than returning to `/source` pathnames, so a post-preflight rename or symlink replacement cannot redirect the transfer. Before target mutation, every present staged database is also opened through a no-follow walk, `fstat`/hashed, checked as self-contained, and passed through `quick_check`. Those staging descriptors remain open through installation; copying reads the descriptors rather than reopening paths, then re-hashes and SQLite-validates the copied bytes before atomic target replacement. The pod therefore never opens live WAL databases through its read-only source mount and cannot silently accept source-parent drift or a substituted staged database. The stopped-source final sync captures and rechecks the same host root identity before Pod creation, verifies the resolved mount identity, retains the same source descriptors through copying, and then copies the exact database/WAL/SHM files.

Migration-pod and SQLite-staging cleanup is armed before staging and runs on success, failure, or signal. Before create, the script rejects every pre-existing Pod carrying the migration application label, assigns a cryptographically random operation ID, derives the exact Pod name from it, and labels the Pod with that operation; it never depends on successful client stdout to learn ownership. Create, reconciliation GETs, readiness, deletion, and absence verification all have fixed outer deadlines and Kubernetes request timeouts. A failed create is ambiguous: the script polls the exact preassigned name through a fixed 45-second horizon, longer than the 15-second client request timeout. A later-visible Pod must carry the retained operation label and yields its UID for cleanup. One immediate absence or an API error never clears unknown ownership; handles clear after failed create only when the complete reconciliation window proves absence. Cleanup performs a fresh authoritative exact-name GET and requires the retained UID and operation label, then uses the real kubectl HTTP transport to issue a collection DELETE scoped by both the cryptographic operation-label selector and exact `metadata.name` field selector. This avoids the installed client's non-transmitted raw `DeleteOptions` body while ensuring an unowned same-name replacement does not match. Handles clear only after a bounded authoritative GET proves absence. Cleanup attempts both the Pod and SQLite staging resources even when one fails, and the `EXIT` trap remains armed after any cleanup error. Thus a successful sync cannot silently orphan a root migration Pod or discard ownership while it may still hold the target PVC writable.

These controls address accidental drift and pathname substitution, not a malicious same-UID process that can rewrite both the private manifest and staged databases before the Pod captures them. The live-source initial copy is only an unqualified candidate because selected non-database state is not one cross-file transaction; the stopped-source final sync closes ordinary source churn. `SIGKILL` or host power loss can still leave a private mode-0700 staging directory. Remove one only after proving that no migration process or Pod owns it.

## Commit 1: provision an inert candidate

1. Merge the package while `apps/hermes-agent/kustomization.yaml` contains the sole mode field:

   ```yaml
   literals:
   - mode=candidate
   ```

   Do not include the active-mode change in this commit. The candidate pod mounts the WaitForFirstConsumer PVC on Hestia but its PID 1 is only `sleep infinity`; it does not start the dispatcher, s6, gateway, cron, Matrix, API, or webhook services.

2. Reconcile the merged candidate revision and wait for it:

   ```bash
   flux reconcile source git cluster-state -n flux-system
   flux reconcile kustomization apps -n flux-system
   kubectl -n default rollout status deployment/hermes-agent --timeout=180s
   kubectl -n default get deployment/hermes-agent -o wide
   kubectl -n default get pod -l app.kubernetes.io/name=hermes-agent -o wide
   kubectl -n default get pvc/hermes-agent-state -o wide
   ```

   Require one Ready candidate pod on `hestia` and a `Bound` PVC. Do not continue if the source and any target gateway are both active or uncertain.

3. Run the read-only guard and the online initial copy:

   ```bash
   scripts/hermes-agent-migration.sh preflight
   scripts/hermes-agent-migration.sh initial-sync
   scripts/hermes-agent-migration.sh preflight
   ```

   The source user service may remain active for this step because the target is inert. Before creating the ephemeral migration pod, the script writes self-contained SQLite online backups and their source/directory identity plus database presence/type/size/SHA-256 manifest into a private transient Hestia directory outside `/home/ben/.hermes`. The pod mounts `/home/ben/.hermes` read-only for non-database state and mounts only that exact staging directory read-only for initial-sync databases. It verifies the mounted source root against the host proof and keeps no-follow root/profile descriptors open through copying. On completion the armed cleanup removes both resources. If create reconciliation, operation-owned collection deletion, or authoritative absence verification cannot prove a safe result, treat `initial-sync` as failed, keep the target in candidate mode, retain the reported exact operation/Pod identity for investigation, and do not continue merely because the copy itself completed.

4. Smoke the copied state through a one-shot CLI while keeping the gateway off:

   ```bash
   kubectl -n default exec deployment/hermes-agent -- \
     s6-setuidgid hermes /opt/hermes/bin/hermes status --all
   kubectl -n default exec deployment/hermes-agent -- \
     s6-setuidgid hermes /opt/hermes/bin/hermes sessions list
   kubectl -n default exec deployment/hermes-agent -- \
     sh -ec 'test "$(cat /etc/hermes-agent-state/mode)" = candidate; test "$(tr "\0" " " </proc/1/cmdline)" = "sleep infinity "'
   ```

   These are separate CLI processes, not a gateway start. Investigate any ownership, config, database, or profile failure before scheduling cutover.

## Commit 2: bounded cutover to active

1. Start a maintenance window. Confirm the candidate is still inert and run `preflight` again.

2. Stop the source and take the final exact copy:

   ```bash
   scripts/hermes-agent-migration.sh final-sync
   systemctl --user is-active hermes-gateway.service
   ```

   The script first rechecks candidate authority, captures and rechecks the no-follow host source-root identity, creates a Pod that must resolve the same mounted inode, stops `hermes-gateway.service`, proves `ActiveState` is inactive/failed with `MainPID=0`, rechecks the target, then copies final mutable state and exact SQLite DB/WAL/SHM files from retained descriptors. The expected `systemctl` result is `inactive`. If final sync fails, leave the source stopped and target candidate while repairing or rolling back; do not start both.

3. Change exactly one GitOps field from `mode=candidate` to `mode=active`, commit it separately, merge it, and reconcile the merged revision:

   ```bash
   flux reconcile source git cluster-state -n flux-system
   flux reconcile kustomization apps -n flux-system
   ```

   Kustomize changes the generated ConfigMap name when the literal changes. That changes the Deployment pod template, so `Recreate` replaces the inert pod. In active mode PID 1 execs `/opt/hermes/docker/entrypoint-dispatch.sh gateway run`, allowing the image's s6 initialization and UID/GID 10000 service drop to run.

4. Run the guarded target verification:

   ```bash
   scripts/hermes-agent-migration.sh verify-target
   ```

   It requires the source inactive, one Ready pod mounted to the active-mode ConfigMap, a healthy unauthenticated local webhook `/health` response on 8644, an authenticated API detailed-health response showing API Server, Feishu, Matrix, and webhook connected, expected state paths, and the exact ClusterIP Service ports. The API key is read inside the pod and is never printed.

5. Complete application-level checks before ending the window:

   - **Matrix:** send a test message to the bot and verify one reply arrives in the expected room; confirm no reply comes from the stopped Hestia service.
   - **API:** use the existing authenticated client through a temporary `kubectl port-forward service/hermes-agent 8642:8642`; do not print or paste the API key. Verify a read-only request and then stop the port-forward.
   - **Webhook:** through a temporary port-forward, `curl -fsS http://127.0.0.1:8644/health`, then remove the port-forward. Do not add an Ingress.
   - **Cron:** run `s6-setuidgid hermes /opt/hermes/bin/hermes cron status` and `cron list` in the pod; verify the expected schedules and observe one known-safe scheduled execution.
   - **Sessions:** run `sessions list` and resume/read a known recent session without altering credentials.
   - **State:** confirm the expected profiles, skills, plugins, memories, and Kanban/workflow state are available. Check application logs for SQLite errors without displaying message, token, or credential content.

## Rollback: target first, then Hestia

Rollback must remove Kubernetes authority before restarting the user service.

1. Change the sole GitOps mode field back from `active` to `candidate`, merge it, reconcile `apps`, and wait until the replacement candidate pod is Ready and inert. This durable candidate change is required so Flux cannot recreate an active gateway while Hestia is starting.

2. Run:

   ```bash
   scripts/hermes-agent-migration.sh rollback
   ```

   The script requires the live Deployment template to reference candidate mode, scales the target to zero, waits until all target pods are gone, then starts `hermes-gateway.service` and proves both the unit and its webhook health active. Flux may later restore the single candidate replica; it remains inert.

3. Verify Matrix, API, webhook, cron, sessions, and state on Hestia. Do not activate Kubernetes again until the source is stopped and a new final sync is completed.

Rollback does not copy post-cutover PVC writes back into `/home/ben/.hermes`. If Kubernetes accepted durable changes after activation, preserve both sides with both gateways stopped and reconcile that state deliberately before declaring rollback complete.
