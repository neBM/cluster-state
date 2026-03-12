# LDAP Schema Contract: lldap

**Feature**: 012-k8s-mail-server  
**Date**: 2026-03-11

This document defines the LDAP schema as provided by lldap and consumed by Postfix, Dovecot, SoGO, and Keycloak.

---

## Base DN

```
dc=brmartin,dc=co,dc=uk
```

## Organisational Units

| OU | DN | Contents |
|----|----|----|
| People | `ou=people,dc=brmartin,dc=co,dc=uk` | All user accounts |
| Groups | `ou=groups,dc=brmartin,dc=co,dc=uk` | All groups |

---

## User Object

**Object classes**: `inetOrgPerson`, `person`  
**DN pattern**: `uid=<username>,ou=people,dc=brmartin,dc=co,dc=uk`

| Attribute | Required | Example | Used by |
|-----------|----------|---------|---------|
| `uid` | Yes | `ben` | Dovecot (login), Postfix (alias), SoGO, Keycloak |
| `cn` | Yes | `Ben Martin` | SoGO (display name), Keycloak |
| `sn` | Yes | `Martin` | Required by schema |
| `givenName` | No | `Ben` | Keycloak first name mapper |
| `mail` | Yes | `ben@brmartin.co.uk` | Postfix routing, SoGO, Keycloak |
| `userPassword` | N/A | — | **Never exposed via LDAP** (Argon2, server-side) |

---

## Group Object

**Object class**: `groupOfUniqueNames`  
**DN pattern**: `cn=<group>,ou=groups,dc=brmartin,dc=co,dc=uk`

| Attribute | Example |
|-----------|---------|
| `cn` | `mail-users` |
| `member` | `uid=ben,ou=people,dc=brmartin,dc=co,dc=uk` |

**Required group**: `mail-users` — all mail account holders must be members. Mail components filter by this group membership.

---

## Service Accounts (provisioned in lldap)

These accounts are created in lldap for inter-service authentication. They are placed in the `ou=people` tree as regular users but are not in the `mail-users` group.

| Account | UID | Purpose | Permissions |
|---------|-----|---------|-------------|
| `dovecot` | `dovecot` | Dovecot initial bind for user lookup | Read-only `ou=people` |
| `postfix` | `postfix` | Postfix virtual mailbox/domain lookup | Read-only `ou=people` |
| `sogo` | `sogo` | SoGO user directory | Read-only `ou=people` |
| `keycloak` | `keycloak` | Keycloak federation | Read-only `ou=people` + `ou=groups` |

---

## Mail Account Example

A fully provisioned mail account for `ben@brmartin.co.uk`:

```ldif
dn: uid=ben,ou=people,dc=brmartin,dc=co,dc=uk
objectClass: inetOrgPerson
objectClass: person
uid: ben
cn: Ben Martin
sn: Martin
givenName: Ben
mail: ben@brmartin.co.uk
```

---

## Notes

- lldap does not support `posixAccount` by default. The `uid=5000` and `gid=5000` used by Dovecot for mailbox ownership are **static defaults** set in Dovecot's `user_attrs`, not read from LDAP.
- The `userPassword` attribute is intentionally absent from LDAP responses. All authentication must use bind-mode (`auth_bind = yes`).
- lldap does not support LDAP paged results (RFC 2696). All LDAP consumers must have pagination disabled.
- Custom attribute `shadowExpire` or equivalent for account disablement is not natively supported in lldap. Account disablement is achieved by **deleting or removing from group** rather than setting a flag.
