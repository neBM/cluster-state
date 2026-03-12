# Feature Specification: Kubernetes Mail Server Migration

**Feature Branch**: `012-k8s-mail-server`  
**Created**: 2026-03-11  
**Status**: Draft  
**Input**: User description: "Hestia currently hosts mailcow through docker docker compose. We are to migrate mailcows components onto k8s. Mailcow manages the mail server components and versions. As part of this migration, we are to migrate away from mailcow. Data loss is not acceptable. Downtime is acceptable. After the migration, the mailcow system can be undeployed. Since we are no longer going to be tied to the components enforced by mailcow, this specification includes exploring alternative components such as SoGO. The new deployment should NOT include the Watchdog. As a minimum, the server should support IMAP, POP3, and SMTP with mail relay support. Accounts should be managed centrally, a potential solution we could explore could be to use Keycloak. IMAP, POP3, and SMTP need to be accessible from outside the cluster."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Email Delivery and Retrieval (Priority: P1)

An email user sends and receives email using a standard mail client (e.g. Thunderbird, Apple Mail, mobile app). After migration, the same mail client configuration works without reconfiguration — the same hostnames, ports, and credentials continue to function. Incoming mail from external senders is received and inbound mail is retrievable via IMAP and POP3. Outbound mail is relayed and delivered externally.

**Why this priority**: Core mail functionality is the entire purpose of the system. Without working SMTP, IMAP, and POP3, no other capability has value. This is the minimum viable outcome.

**Independent Test**: Can be fully tested by configuring a mail client against the new system and verifying send and receive across both authenticated SMTP submission and IMAP/POP3 retrieval, including cross-domain delivery from an external address.

**Acceptance Scenarios**:

1. **Given** a configured mail client using IMAP, **When** the user logs in with their credentials, **Then** the client connects successfully and displays the full mailbox contents.
2. **Given** a configured mail client, **When** the user sends an email to an external address, **Then** the message is delivered to the recipient and passes SPF, DKIM, and DMARC validation.
3. **Given** an external sender, **When** they send an email to a managed address, **Then** the message appears in the recipient's IMAP/POP3 mailbox.
4. **Given** a configured mail client using POP3, **When** the user logs in with their credentials, **Then** the client connects and downloads available messages.

---

### User Story 2 - Migrated Data Availability (Priority: P1)

An existing mail user accesses their email after the migration and finds all previously received messages, folder structures, and sent items intact. No email history has been lost. The user does not need to take any manual steps to recover data — the migration transparently carries all existing mailboxes to the new system.

**Why this priority**: Data loss is explicitly unacceptable. Preserving the full mail history for all accounts is a hard constraint on the migration, not an optional enhancement.

**Independent Test**: Can be tested by comparing mailbox message counts, folder names, and a sample of message contents against a snapshot taken from the mailcow system before migration.

**Acceptance Scenarios**:

1. **Given** a user with existing email in mailcow, **When** they access their mailbox on the new system after migration, **Then** all messages, folders, and sent items are present and match the pre-migration state.
2. **Given** any account that existed in mailcow, **When** the migration completes, **Then** the account is present and accessible in the new system.
3. **Given** a mailbox with emails containing attachments, **When** the user retrieves those messages after migration, **Then** all attachments are intact and not corrupted.

---

### User Story 3 - Webmail Access (Priority: P2)

A user opens a browser and accesses their email via a webmail interface without needing to install any client software. They can read, compose, and send email. Calendar and contacts management are out of scope; the webmail provides email access only.

**Why this priority**: Webmail provides a fallback access method and may be the primary interface for some users. It is important for usability but does not block core mail delivery.

**Independent Test**: Can be tested independently by accessing the webmail URL in a browser, logging in, and performing basic email operations (read, compose, send, reply).

**Acceptance Scenarios**:

1. **Given** a mail account holder, **When** they navigate to the webmail URL and log in, **Then** they can view their inbox and read messages.
2. **Given** a logged-in webmail user, **When** they compose and send a message to an external address, **Then** the message is delivered and passes mail authentication checks.

---

### User Story 4 - Centralized Account Management (Priority: P2)

An administrator creates, modifies, or removes a mail account and the change takes effect without restarting any mail services. All mail account credentials and lifecycle events are managed exclusively through Keycloak — the cluster's central identity provider. A standalone mail-specific admin panel is not acceptable. Where a mail component cannot integrate directly with Keycloak, an intermediary identity service that Keycloak federates with (such as an LDAP directory) is an acceptable bridge, provided Keycloak remains the authoritative source for account management.

**Why this priority**: Centralized account management reduces administrative overhead and eliminates a separate credential silo. It is a stated goal but does not affect the ability to send and receive email.

**Independent Test**: Can be tested independently by creating a new mail account via the account management interface and verifying that the account can immediately authenticate and receive mail.

**Acceptance Scenarios**:

1. **Given** an administrator with management access, **When** they create a new mail account, **Then** the account becomes active and the user can log in via IMAP and webmail without any manual server-side steps.
2. **Given** an existing mail account, **When** an administrator disables or deletes it, **Then** the account can no longer authenticate to any mail service.
3. **Given** a password change via the central identity system, **When** the user authenticates to any mail service, **Then** the new password is accepted and the old password is rejected.

---

### User Story 5 - Mailcow Decommission (Priority: P3)

After the new mail system has been validated, the administrator removes the mailcow Docker Compose deployment from Hestia entirely. The cluster state no longer references mailcow. No mail service is degraded by the removal.

**Why this priority**: Decommissioning is the cleanup phase that confirms the migration is complete. It does not deliver user-facing value but is a stated goal and validates full independence from mailcow.

**Independent Test**: Can be tested by stopping and removing the mailcow containers and verifying all mail protocols remain functional on the new system.

**Acceptance Scenarios**:

1. **Given** the new mail system fully operational, **When** the mailcow Docker Compose stack is stopped and removed, **Then** all mail protocols (SMTP, IMAP, POP3) continue to function without interruption.
2. **Given** the mailcow stack removed, **When** any external sender sends mail, **Then** the mail is received by the new system and not lost.

---

### Edge Cases

- What happens when a mail client attempts to connect during the migration downtime window? External SMTP servers should queue and retry; clients should receive appropriate connection-refused responses.
- How does the system handle very large mailboxes during migration? Migration tooling must handle mailboxes of any size without truncation or corruption.
- What happens if a message is queued in the mailcow SMTP queue at the time of migration? Queued messages must be flushed or manually transferred to avoid loss.
- How does the system handle mail sent to a deleted account? Mail for non-existent addresses must be rejected with a 550 response; silent discarding is not acceptable.
- What happens if DKIM keys change during migration? DNS records must be updated to reflect any new keys, or existing keys must be preserved and carried over.
- How does the system behave when the spam filter or antivirus component is unavailable? Mail delivery must continue; filtering failures must be logged and must not silently drop messages.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST receive inbound email from external senders for all configured domains via SMTP.
- **FR-002**: System MUST allow authenticated users to retrieve email via IMAP from outside the cluster.
- **FR-003**: System MUST allow authenticated users to retrieve email via POP3 from outside the cluster.
- **FR-004**: System MUST relay outbound email for authenticated users to external mail servers.
- **FR-005**: System MUST provide a browser-accessible webmail interface for reading and composing email.
- **FR-006**: System MUST source all mail account credentials and lifecycle events exclusively from Keycloak, so that creating, modifying, or disabling an account in Keycloak is immediately reflected across all mail protocols (IMAP, POP3, SMTP, webmail) with no additional manual steps.
- **FR-006a**: Where a mail component cannot authenticate directly against Keycloak, an intermediary identity service federated with Keycloak (e.g. an LDAP directory managed by Keycloak) is acceptable, provided Keycloak remains the sole authoritative interface for administrators.
- **FR-007**: System MUST migrate all mailbox data from mailcow with no message loss, preserving folder structure and message content.
- **FR-008**: System MUST sign outbound email with DKIM for all managed domains.
- **FR-009**: System MUST enforce TLS for all client-facing connections on IMAP, POP3, and SMTP submission.
- **FR-010**: System MUST filter inbound email for spam and reject or quarantine messages classified as spam.
- **FR-011**: System MUST scan inbound email attachments and message content for malware.
- **FR-012**: System MUST NOT include any automated Watchdog or self-healing supervisor component that operates outside standard Kubernetes health management.
- **FR-013**: SMTP (submission), IMAP, and POP3 ports MUST be reachable by clients located outside the Kubernetes cluster.
- **FR-014**: System MUST reject mail sent to non-existent addresses with a proper SMTP error response.
- **FR-015**: System MUST support mail aliases that redirect messages from one address to another.

### Key Entities

- **Mail Domain**: A domain for which the system accepts and sends email. Carries configuration for routing, DKIM, and SPF policy.
- **Mail Account**: A user account with an email address, credentials, mailbox storage, and quota. Subject to create, modify, disable, and delete lifecycle operations.
- **Mailbox**: The persistent email storage container for a mail account, organized into folders (Inbox, Sent, Drafts, etc.).
- **Mail Message**: An individual email with headers, body, and zero or more attachments, stored in a specific mailbox folder.
- **Mail Alias**: A routing rule that maps one or more email addresses to one or more target accounts or external addresses.
- **DKIM Key Pair**: A signing key pair associated with a mail domain, used to authenticate outbound messages.

## Assumptions

- SoGO is selected as the webmail component for email-only access (read, compose, send). Calendar and contacts management are explicitly out of scope; SoGO's groupware features (calendar, address book) will not be configured or exposed.
- Spam filtering is a hard requirement, not optional. A production mail server without spam filtering is not viable.
- Antivirus scanning is included. Disabling ClamAV or equivalent was not requested.
- Existing DNS records (MX, SPF, DMARC) for managed domains remain unchanged. Only DKIM records may need updating if keys are not migrated.
- The migration window involves a planned downtime. External SMTP senders will queue during the window; no messages will be permanently lost provided the DNS TTLs are managed appropriately.
- Mail storage will use persistent cluster storage. SQLite is not used for mailbox data given network storage constraints documented in the cluster guidelines.
- The new system runs entirely within Kubernetes. No Docker Compose components remain after decommissioning.
- Mail ports are exposed externally via a mechanism supported by the K3s cluster (e.g., NodePort or a dedicated LoadBalancer). The exact exposure method is an implementation decision.
- Existing DKIM private keys from mailcow will be extracted and reused in the new system to avoid DNS propagation delays.
- Keycloak is already operational in the cluster (it is an existing service). This feature does not provision Keycloak itself; it integrates the mail system with it.
- Where direct Keycloak protocol support is not available in a mail component, a Keycloak-managed LDAP directory is the preferred intermediary, as Keycloak supports acting as an LDAP provider.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero email messages are lost during migration — all messages present in mailcow mailboxes before migration are accessible in the new system after migration.
- **SC-002**: All mail protocols (SMTP submission, IMAP, POP3) are fully operational and reachable from outside the cluster within the planned maintenance window.
- **SC-003**: Outbound mail from the new system passes SPF, DKIM, and DMARC validation as verified by an external mail testing tool.
- **SC-004**: A new mail account can be created via the central account management interface and is immediately usable across IMAP, POP3, SMTP, and webmail — with no manual mail-server-side steps required.
- **SC-005**: Existing mail clients that were configured for the mailcow system can connect to the new system using the same server hostnames and ports with no client-side reconfiguration.
- **SC-006**: The mailcow Docker Compose deployment is fully removed from Hestia with no residual impact on mail service availability.
- **SC-007**: Inbound spam is filtered such that a standard spam test message (e.g., GTUBE test string) is rejected or quarantined and does not appear in the user's inbox.
