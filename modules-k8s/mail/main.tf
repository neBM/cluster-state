# mail - Kubernetes-native mail stack
#
# Components: Postfix (SMTP), Dovecot (IMAP/POP3), Rspamd (spam + DKIM),
# Redis (Rspamd backend), SoGO (webmail — Phase 5, currently commented out).
# All mail TCP ports (25/465/587/143/993/110/995/4190) exposed via hostPort on Hestia.
# SoGO webmail served via Traefik IngressRoute at mail.brmartin.co.uk.

locals {
  app_name = "mail"
  labels = {
    managed-by  = "terraform"
    environment = "prod"
  }
  ldap_people_dn = "ou=people,${var.ldap_base_dn}"
}

# =============================================================================
# Redis — Rspamd backend (T018)
# =============================================================================

resource "kubernetes_deployment" "mail_redis" {
  metadata {
    name      = "mail-redis"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "mail-redis" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mail-redis" }
    }

    template {
      metadata {
        labels = merge(local.labels, { app = "mail-redis" })
      }

      spec {
        container {
          name = "redis"
          # renovate: datasource=docker depName=redis
          image = "redis:${var.image_tag_redis}"

          port {
            container_port = 6379
            name           = "redis"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 10
            period_seconds        = 15
            timeout_seconds       = 5
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "mail_redis" {
  metadata {
    name      = "mail-redis"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "mail-redis" })
  }

  spec {
    selector = { app = "mail-redis" }

    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Rspamd — Spam filter + DKIM signing (T019)
# =============================================================================

resource "kubernetes_config_map" "rspamd_config" {
  metadata {
    name      = "rspamd-config"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "rspamd" })
  }

  data = {
    # Milter proxy binding — Postfix sends mail here for scanning
    "worker-proxy.inc" = <<-EOF
      bind_socket = "*:11332";
      upstream "local" {
        self_scan = yes;
      }
    EOF

    # Redis backend for bayes, greylisting, rate limiting
    "redis.conf" = <<-EOF
      servers = "mail-redis:6379";
    EOF

    # DKIM signing — uses private keys mounted from dkim-keys Secret
    "dkim_signing.conf" = <<-EOF
      enabled = true;
      allow_username_mismatch = true;

      domain {
        brmartin.co.uk {
          path = "/etc/rspamd/dkim/brmartin.co.uk.dkim.key";
          selector = "dkim";
        }
        martinilink.co.uk {
          path = "/etc/rspamd/dkim/martinilink.co.uk.dkim.key";
          selector = "dkim";
        }
      }
    EOF
  }
}

resource "kubernetes_persistent_volume_claim" "rspamd_data" {
  metadata {
    name      = "rspamd-data"
    namespace = var.namespace
    annotations = {
      "volume-name" = "rspamd_data"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]

    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "rspamd" {
  metadata {
    name      = "rspamd"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "rspamd" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "rspamd" }
    }

    template {
      metadata {
        labels = merge(local.labels, { app = "rspamd" })
      }

      spec {
        container {
          name = "rspamd"
          # renovate: datasource=docker depName=rspamd/rspamd
          image = "rspamd/rspamd:${var.image_tag_rspamd}"

          port {
            container_port = 11332
            name           = "milter"
          }

          port {
            container_port = 11334
            name           = "web"
          }

          volume_mount {
            name       = "dkim-keys"
            mount_path = "/etc/rspamd/dkim"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/rspamd/local.d/worker-proxy.inc"
            sub_path   = "worker-proxy.inc"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/rspamd/local.d/redis.conf"
            sub_path   = "redis.conf"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/rspamd/local.d/dkim_signing.conf"
            sub_path   = "dkim_signing.conf"
            read_only  = true
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/rspamd"
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = 11334
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = 11334
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "dkim-keys"
          secret {
            secret_name = data.kubernetes_secret.dkim_keys.metadata[0].name
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.rspamd_config.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.rspamd_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "rspamd" {
  metadata {
    name      = "rspamd"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "rspamd" })
    annotations = {
      # T052: Prometheus scraping for VictoriaMetrics
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "11334"
      "prometheus.io/path"   = "/metrics"
    }
  }

  spec {
    selector = { app = "rspamd" }

    port {
      name        = "milter"
      port        = 11332
      target_port = 11332
      protocol    = "TCP"
    }

    port {
      name        = "web"
      port        = 11334
      target_port = 11334
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Postfix — SMTP MTA (T020)
# =============================================================================

resource "kubernetes_config_map" "postfix_main" {
  metadata {
    name      = "postfix-main"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "postfix" })
  }

  data = {
    # run.config is sourced by tozd/postfix's runit run script before Postfix starts.
    # It uses postconf -e to configure Postfix (avoids read-only main.cf mount issues)
    # and runs postmap to build hash tables for vmailbox and virtual alias maps.
    "run.config" = <<-EOF
      # Identity
      postconf -e "myhostname=mail.brmartin.co.uk"
      postconf -e "myorigin=\$myhostname"
      postconf -e "mydestination="

      # Virtual domains
      postconf -e "virtual_mailbox_domains=${join(", ", var.domains)}"
      postconf -e "virtual_mailbox_maps=hash:/etc/postfix/vmailbox"
      postconf -e "virtual_alias_maps=hash:/etc/postfix/virtual"

      # Local delivery via Dovecot LMTP (FQDN required: Postfix's own DNS resolver
      # does not use the pod's search domain list)
      postconf -e "virtual_transport=lmtp:inet:dovecot.default.svc.cluster.local:24"

      # TLS (inbound)
      postconf -e "smtpd_tls_cert_file=/etc/ssl/mail/tls.crt"
      postconf -e "smtpd_tls_key_file=/etc/ssl/mail/tls.key"
      postconf -e "smtpd_use_tls=yes"
      postconf -e "smtpd_tls_security_level=may"
      postconf -e "smtpd_tls_loglevel=1"

      # TLS (outbound)
      postconf -e "smtp_tls_security_level=may"
      postconf -e "smtp_tls_loglevel=1"

      # SASL authentication — delegated to Dovecot
      postconf -e "smtpd_sasl_type=dovecot"
      postconf -e "smtpd_sasl_path=inet:dovecot.default.svc.cluster.local:12345"
      postconf -e "smtpd_sasl_auth_enable=yes"
      postconf -e "smtpd_sasl_security_options=noanonymous"
      postconf -e "smtpd_sasl_tls_security_options=noanonymous"
      postconf -e "broken_sasl_auth_clients=yes"

      # Submission restrictions
      postconf -e "smtpd_recipient_restrictions=permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"

      # Milter (Rspamd) — accept mail even if Rspamd unreachable
      postconf -e "milter_default_action=accept"
      postconf -e "milter_protocol=6"
      postconf -e "smtpd_milters=inet:rspamd.default.svc.cluster.local:11332"
      postconf -e "non_smtpd_milters=inet:rspamd.default.svc.cluster.local:11332"
      postconf -e "milter_mail_macros=i {mail_addr} {client_addr} {client_name} {auth_authen}"

       # Outbound relay (Mailgun) — credentials injected from postfix-relay-secret
       postconf -e "relayhost=$RELAY_HOST"
       postconf -e "smtp_sasl_auth_enable=yes"
       postconf -e "smtp_sasl_security_options=noanonymous"
       postconf -e "smtp_sasl_tls_security_options=noanonymous"
       postconf -e "smtp_tls_security_level=encrypt"
       postconf -e "smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd"
       echo "$RELAY_HOST $RELAY_USERNAME:$RELAY_PASSWORD" > /tmp/sasl_passwd
       postmap /tmp/sasl_passwd
       cp /tmp/sasl_passwd.db /etc/postfix/sasl_passwd.db
       rm -f /tmp/sasl_passwd

       # Misc
       postconf -e "inet_interfaces=all"
       postconf -e "inet_protocols=ipv4"
       postconf -e "compatibility_level=3.8"

       # Build hash tables for virtual mailbox and alias maps
      cp /etc/postfix/vmailbox /tmp/vmailbox
      cp /etc/postfix/virtual /tmp/virtual_alias
      postmap /tmp/vmailbox
      postmap /tmp/virtual_alias
      cp /tmp/vmailbox.db /etc/postfix/vmailbox.db
      cp /tmp/virtual_alias.db /etc/postfix/virtual.db
    EOF

    # master.cf for Postfix 3.8 on Ubuntu Noble
    "master.cf" = <<-EOF
      # Postfix master process configuration for Postfix 3.8
      smtp      inet  n       -       n       -       1       postscreen
      smtpd     pass  -       -       n       -       -       smtpd
      dnsblog   unix  -       -       n       -       0       dnsblog
      tlsproxy  unix  -       -       n       -       0       tlsproxy
      submission inet n       -       n       -       -       smtpd
        -o syslog_name=postfix/submission
        -o smtpd_tls_security_level=encrypt
        -o smtpd_sasl_auth_enable=yes
        -o smtpd_reject_unlisted_recipient=no
        -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
        -o milter_macro_daemon_name=ORIGINATING
      smtps     inet  n       -       n       -       -       smtpd
        -o syslog_name=postfix/smtps
        -o smtpd_tls_wrappermode=yes
        -o smtpd_sasl_auth_enable=yes
        -o smtpd_reject_unlisted_recipient=no
        -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
        -o milter_macro_daemon_name=ORIGINATING
      pickup    unix  n       -       n       60      1       pickup
      cleanup   unix  n       -       n       -       0       cleanup
      qmgr      unix  n       -       n       300     1       qmgr
      tlsmgr    unix  -       -       n       1000?   1       tlsmgr
      rewrite   unix  -       -       n       -       -       trivial-rewrite
      bounce    unix  -       -       n       -       0       bounce
      defer     unix  -       -       n       -       0       bounce
      trace     unix  -       -       n       -       0       bounce
      verify    unix  -       -       n       -       1       verify
      flush     unix  n       -       n       1000?   0       flush
      proxymap  unix  -       -       n       -       -       proxymap
      proxywrite unix -       -       n       -       1       proxymap
      smtp      unix  -       -       n       -       -       smtp
      relay     unix  -       -       n       -       -       smtp
      showq     unix  n       -       n       -       -       showq
      error     unix  -       -       n       -       -       error
      retry     unix  -       -       n       -       -       error
      discard   unix  -       -       n       -       -       discard
      local     unix  -       n       n       -       -       local
      virtual   unix  -       n       n       -       -       virtual
      lmtp      unix  -       -       n       -       -       lmtp
      anvil     unix  -       -       n       -       1       anvil
      scache    unix  -       -       n       -       1       scache
      postlog   unix-dgram n  -       n       -       1       postlogd
    EOF

    # Static virtual mailbox map — lists real mailboxes (one entry per real mailbox)
    "vmailbox" = "ben@brmartin.co.uk    brmartin.co.uk/ben/\n"
  }
}

resource "kubernetes_config_map" "postfix_ldap" {
  metadata {
    name      = "postfix-ldap"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "postfix" })
  }

  data = {
    # Virtual mailbox lookup — resolves recipient addresses to mailbox paths
    "ldap-mailboxes.cf" = <<-EOF
      server_host = ldap://${var.lldap_host}:3890
      bind = yes
      bind_dn = uid=postfix,${local.ldap_people_dn}
      bind_pw = $LDAP_BIND_PW
      search_base = ${local.ldap_people_dn}
      query_filter = (&(objectClass=inetOrgPerson)(mail=%s))
      result_attribute = mail
    EOF
  }
}

resource "kubernetes_config_map" "postfix_aliases" {
  metadata {
    name      = "postfix-aliases"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "postfix" })
  }

  data = {
    # Virtual alias map — migrated from mailcow: ben@martinilink.co.uk → ben@brmartin.co.uk
    "virtual" = "ben@martinilink.co.uk    ben@brmartin.co.uk\n"
  }
}

resource "kubernetes_persistent_volume_claim" "postfix_spool" {
  metadata {
    name      = "postfix-spool"
    namespace = var.namespace
    annotations = {
      "volume-name" = "postfix_spool"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_stateful_set" "postfix" {
  metadata {
    name      = "postfix"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "postfix" })
  }

  spec {
    service_name = "postfix"
    replicas     = 1

    selector {
      match_labels = { app = "postfix" }
    }

    template {
      metadata {
        labels = merge(local.labels, { app = "postfix" })
      }

      spec {
        node_selector = {
          "kubernetes.io/hostname" = "hestia"
        }

        container {
          name = "postfix"
          # renovate: datasource=docker depName=tozd/postfix
          image = "tozd/postfix:${var.image_tag_postfix}"

          # SMTP (inbound relay)
          port {
            container_port = 25
            host_port      = 25
            name           = "smtp"
            protocol       = "TCP"
          }

          # SMTPS (submission, implicit TLS)
          port {
            container_port = 465
            host_port      = 465
            name           = "smtps"
            protocol       = "TCP"
          }

          # Submission (STARTTLS)
          port {
            container_port = 587
            host_port      = 587
            name           = "submission"
            protocol       = "TCP"
          }

          env {
            name = "RELAY_HOST"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.postfix_relay.metadata[0].name
                key  = "RELAY_HOST"
              }
            }
          }

          env {
            name = "RELAY_USERNAME"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.postfix_relay.metadata[0].name
                key  = "RELAY_USERNAME"
              }
            }
          }

          env {
            name = "RELAY_PASSWORD"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.postfix_relay.metadata[0].name
                key  = "RELAY_PASSWORD"
              }
            }
          }

          # tozd/postfix sources this file in its runit run script before Postfix starts
          volume_mount {
            name       = "postfix-main"
            mount_path = "/etc/service/postfix/run.config"
            sub_path   = "run.config"
            read_only  = true
          }

          volume_mount {
            name       = "postfix-main"
            mount_path = "/etc/postfix/master.cf"
            sub_path   = "master.cf"
            read_only  = true
          }

          volume_mount {
            name       = "postfix-main"
            mount_path = "/etc/postfix/vmailbox"
            sub_path   = "vmailbox"
            read_only  = true
          }

          volume_mount {
            name       = "postfix-aliases"
            mount_path = "/etc/postfix/virtual"
            sub_path   = "virtual"
            read_only  = true
          }

          volume_mount {
            name       = "mail-tls"
            mount_path = "/etc/ssl/mail"
            read_only  = true
          }

          volume_mount {
            name       = "spool"
            mount_path = "/var/spool/postfix"
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "postfix check && echo ok"]
            }
            initial_delay_seconds = 30
            period_seconds        = 60
            timeout_seconds       = 10
          }

          readiness_probe {
            tcp_socket {
              port = 25
            }
            initial_delay_seconds = 15
            period_seconds        = 15
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "postfix-main"
          config_map {
            name = kubernetes_config_map.postfix_main.metadata[0].name
          }
        }

        volume {
          name = "postfix-aliases"
          config_map {
            name = kubernetes_config_map.postfix_aliases.metadata[0].name
          }
        }

        volume {
          name = "mail-tls"
          secret {
            secret_name = "mail-tls"
          }
        }

        volume {
          name = "spool"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postfix_spool.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postfix" {
  metadata {
    name      = "postfix"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "postfix" })
  }

  spec {
    selector = { app = "postfix" }

    # externalIPs causes Cilium to create iptables DNAT rules on the node's
    # physical interface (enp34s0) for inbound mail ports. hostPort alone does
    # not work in Cilium VXLAN mode (no TC BPF filter on the physical NIC).
    external_ips = [var.mail_node_ip]

    port {
      name        = "smtp"
      port        = 25
      target_port = 25
      protocol    = "TCP"
    }

    port {
      name        = "smtps"
      port        = 465
      target_port = 465
      protocol    = "TCP"
    }

    port {
      name        = "submission"
      port        = 587
      target_port = 587
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Dovecot — IMAP / POP3 / LMTP / SASL (T021)
# =============================================================================

resource "kubernetes_config_map" "dovecot_main" {
  metadata {
    name      = "dovecot-main"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "dovecot" })
  }

  data = {
    "dovecot.conf" = <<-EOF
      # Dovecot main configuration for K8s mail stack
      # Managed by Terraform — do not edit manually

      # Protocols
      protocols = imap pop3 lmtp sieve

      # Mail storage — NFS-safe settings (AGENTS.md)
      mail_location = maildir:/var/mail/%d/%n:INDEX=/var/indexes/%d/%n
      mmap_disable = yes
      mail_fsync = always
      maildir_copy_with_hardlinks = no

      # User identity (static vmail uid/gid)
      mail_privileged_group = vmail

      # TLS
      ssl = yes
      ssl_cert = </etc/ssl/mail/tls.crt
      ssl_key = </etc/ssl/mail/tls.key
      ssl_min_protocol = TLSv1.2

      # Authentication
      auth_mechanisms = plain login
      # Allow plaintext auth on port 143 for internal SoGO connections
      disable_plaintext_auth = no

      # LMTP listener (Postfix delivery)
      service lmtp {
        inet_listener lmtp {
          address = 0.0.0.0
          port = 24
        }
      }

      # SASL listener (Postfix auth delegation)
      service auth {
        inet_listener {
          port = 12345
        }
      }

      # IMAP listener
      service imap-login {
        inet_listener imap {
          port = 143
        }
        inet_listener imaps {
          port = 993
          ssl = yes
        }
      }

      # POP3 listener
      service pop3-login {
        inet_listener pop3 {
          port = 110
        }
        inet_listener pop3s {
          port = 995
          ssl = yes
        }
      }

      # ManageSieve listener
      service managesieve-login {
        inet_listener sieve {
          port = 4190
        }
      }

      # Include LDAP auth config
      !include auth-ldap.conf.ext
    EOF

    "auth-ldap.conf.ext" = <<-EOF
       # passdb step 1: check user is member of mail-users group.
       # Searches ou=groups for the group entry with member=uid=%n,...
       # If user is NOT in the group, the search returns nothing → auth fails.
       # result_success=continue passes to step 2 for password verification.
       passdb {
         driver = ldap
         args = /etc/dovecot/dovecot-ldap-passdb.conf.ext
         result_success = continue
         result_failure = return-fail
         result_internalfail = return-fail
       }

       # passdb step 2: verify password via direct bind (auth_bind_userdn).
       # Only reached if group membership check passed.
       passdb {
         driver = ldap
         args = /etc/dovecot/dovecot-ldap.conf.ext
       }

       # userdb: resolves uid/gid/home for mail delivery.
       userdb {
         driver = ldap
         args = /etc/dovecot/dovecot-ldap.conf.ext
       }
     EOF
  }
}

resource "kubernetes_config_map" "dovecot_ldap" {
  metadata {
    name      = "dovecot-ldap"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "dovecot" })
  }

  data = {
    # Template: $${LDAP_BIND_PW} → Terraform renders as ${LDAP_BIND_PW} for envsubst.
    # initContainer runs envsubst to inject the real password before Dovecot starts.
    "dovecot-ldap.conf.ext.tmpl" = <<-EOF
      # Dovecot LDAP userdb configuration — used only for userdb (uid/gid/home lookup).
      # passdb uses dovecot-ldap-passdb.conf.ext which enforces mail-users group membership.
      ldap_version = 3
      hosts = ${var.lldap_host}:3890
      dn = uid=dovecot,${local.ldap_people_dn}
      dnpass = $${LDAP_BIND_PW}
      auth_bind = yes
      auth_bind_userdn = uid=%n,${local.ldap_people_dn}

      base = ${local.ldap_people_dn}
      scope = subtree

      pass_filter = (&(objectClass=inetOrgPerson)(uid=%n))
      user_filter = (&(objectClass=inetOrgPerson)(uid=%n))
      user_attrs = \
        =uid=5000, \
        =gid=5000, \
        =home=/var/mail/%Ld/%Ln, \
        =mail=maildir:~/Maildir
    EOF

    # passdb step 1: group membership check only (no password verification).
    # Binds as dovecot service account and searches ou=groups for the mail-users
    # group entry that has member=uid=%n,... . If the user is NOT a member,
    # the search returns no results → Dovecot fails the auth before step 2.
    # pass_attrs returns nopassword so Dovecot skips password check at this step.
    "dovecot-ldap-passdb.conf.ext.tmpl" = <<-EOF
      ldap_version = 3
      hosts = ${var.lldap_host}:3890
      dn = uid=dovecot,${local.ldap_people_dn}
      dnpass = $${LDAP_BIND_PW}
      auth_bind = no

      base = ou=groups,${var.ldap_base_dn}
      scope = subtree

      # Succeeds only if user is in mail-users group; returns no password (nopassword).
      pass_filter = (&(objectClass=groupOfNames)(cn=mail-users)(member=uid=%n,${local.ldap_people_dn}))
      pass_attrs = =nopassword=y
    EOF
  }
}

resource "kubernetes_persistent_volume_claim" "dovecot_mailboxes" {
  metadata {
    name      = "dovecot-mailboxes"
    namespace = var.namespace
    annotations = {
      "volume-name" = "dovecot_mailboxes"
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_stateful_set" "dovecot" {
  metadata {
    name      = "dovecot"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "dovecot" })
  }

  spec {
    service_name = "dovecot"
    replicas     = 1

    selector {
      match_labels = { app = "dovecot" }
    }

    template {
      metadata {
        labels = merge(local.labels, { app = "dovecot" })
      }

      spec {
        node_selector = {
          "kubernetes.io/hostname" = "hestia"
        }

        # initContainer: resolves LDAP_BIND_PW into dovecot-ldap.conf.ext using sed.
        # Dovecot image has sed but not envsubst.
        init_container {
          name = "init-ldap-conf"
          # renovate: datasource=docker depName=dovecot/dovecot
          image = "dovecot/dovecot:${var.image_tag_dovecot}"

          command = ["/bin/sh", "-c"]
          args = [
            "sed \"s|\\$${LDAP_BIND_PW}|$LDAP_BIND_PW|g\" /tmpl/dovecot-ldap.conf.ext.tmpl > /ldap-conf/dovecot-ldap.conf.ext && sed \"s|\\$${LDAP_BIND_PW}|$LDAP_BIND_PW|g\" /tmpl/dovecot-ldap-passdb.conf.ext.tmpl > /ldap-conf/dovecot-ldap-passdb.conf.ext && echo 'ldap conf files written'"
          ]

          env {
            name = "LDAP_BIND_PW"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.dovecot_ldap.metadata[0].name
                key  = "LDAP_BIND_PW"
              }
            }
          }

          volume_mount {
            name       = "dovecot-ldap"
            mount_path = "/tmpl"
            read_only  = true
          }

          volume_mount {
            name       = "ldap-conf"
            mount_path = "/ldap-conf"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }
        }

        container {
          name = "dovecot"
          # renovate: datasource=docker depName=dovecot/dovecot
          image = "dovecot/dovecot:${var.image_tag_dovecot}"

          # IMAP (STARTTLS)
          port {
            container_port = 143
            host_port      = 143
            name           = "imap"
            protocol       = "TCP"
          }

          # IMAPS (implicit TLS)
          port {
            container_port = 993
            host_port      = 993
            name           = "imaps"
            protocol       = "TCP"
          }

          # POP3 (STARTTLS)
          port {
            container_port = 110
            host_port      = 110
            name           = "pop3"
            protocol       = "TCP"
          }

          # POP3S (implicit TLS)
          port {
            container_port = 995
            host_port      = 995
            name           = "pop3s"
            protocol       = "TCP"
          }

          # ManageSieve
          port {
            container_port = 4190
            host_port      = 4190
            name           = "sieve"
            protocol       = "TCP"
          }

          volume_mount {
            name       = "dovecot-main"
            mount_path = "/etc/dovecot/dovecot.conf"
            sub_path   = "dovecot.conf"
            read_only  = true
          }

          volume_mount {
            name       = "dovecot-main"
            mount_path = "/etc/dovecot/auth-ldap.conf.ext"
            sub_path   = "auth-ldap.conf.ext"
            read_only  = true
          }

          # Resolved LDAP configs (written by initContainer with real password)
          volume_mount {
            name       = "ldap-conf"
            mount_path = "/etc/dovecot/dovecot-ldap.conf.ext"
            sub_path   = "dovecot-ldap.conf.ext"
            read_only  = true
          }

          volume_mount {
            name       = "ldap-conf"
            mount_path = "/etc/dovecot/dovecot-ldap-passdb.conf.ext"
            sub_path   = "dovecot-ldap-passdb.conf.ext"
            read_only  = true
          }

          volume_mount {
            name       = "mail-tls"
            mount_path = "/etc/ssl/mail"
            read_only  = true
          }

          volume_mount {
            name       = "mailboxes"
            mount_path = "/var/mail"
          }

          # Indexes on emptyDir — avoids NFS mmap issues; rebuilt on pod restart
          volume_mount {
            name       = "indexes"
            mount_path = "/var/indexes"
          }

          liveness_probe {
            tcp_socket {
              port = 143
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            tcp_socket {
              port = 143
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "dovecot-main"
          config_map {
            name = kubernetes_config_map.dovecot_main.metadata[0].name
          }
        }

        # LDAP config templates (read-only, initContainer reads from here)
        volume {
          name = "dovecot-ldap"
          config_map {
            name = kubernetes_config_map.dovecot_ldap.metadata[0].name
            items {
              key  = "dovecot-ldap.conf.ext.tmpl"
              path = "dovecot-ldap.conf.ext.tmpl"
            }
            items {
              key  = "dovecot-ldap-passdb.conf.ext.tmpl"
              path = "dovecot-ldap-passdb.conf.ext.tmpl"
            }
          }
        }

        # Resolved LDAP config (initContainer writes the real password here)
        volume {
          name = "ldap-conf"
          empty_dir {}
        }

        volume {
          name = "mail-tls"
          secret {
            secret_name = "mail-tls"
          }
        }

        volume {
          name = "mailboxes"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.dovecot_mailboxes.metadata[0].name
          }
        }

        volume {
          name = "indexes"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "dovecot" {
  metadata {
    name      = "dovecot"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "dovecot" })
  }

  spec {
    selector = { app = "dovecot" }

    # externalIPs causes Cilium to create iptables DNAT rules on the node's
    # physical interface (enp34s0) for inbound mail client ports.
    external_ips = [var.mail_node_ip]

    # Internal cluster ports
    port {
      name        = "lmtp"
      port        = 24
      target_port = 24
      protocol    = "TCP"
    }

    port {
      name        = "sasl"
      port        = 12345
      target_port = 12345
      protocol    = "TCP"
    }

    # External mail client ports
    port {
      name        = "imap"
      port        = 143
      target_port = 143
      protocol    = "TCP"
    }

    port {
      name        = "imaps"
      port        = 993
      target_port = 993
      protocol    = "TCP"
    }

    port {
      name        = "pop3"
      port        = 110
      target_port = 110
      protocol    = "TCP"
    }

    port {
      name        = "pop3s"
      port        = 995
      target_port = 995
      protocol    = "TCP"
    }

    port {
      name        = "sieve"
      port        = 4190
      target_port = 4190
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Network Policies — Cilium (T022)
# =============================================================================

# mail-redis: only Rspamd may connect on port 6379
resource "kubernetes_manifest" "np_mail_redis" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "mail-redis"
      namespace = var.namespace
    }
    spec = {
      endpointSelector = { matchLabels = { app = "mail-redis" } }
      ingress = [
        {
          fromEndpoints = [{ matchLabels = { app = "rspamd" } }]
          toPorts       = [{ ports = [{ port = "6379", protocol = "TCP" }] }]
        }
      ]
    }
  }
}

# Rspamd: Postfix milter (11332) + Traefik web UI (11334)
resource "kubernetes_manifest" "np_rspamd" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "rspamd"
      namespace = var.namespace
    }
    spec = {
      endpointSelector = { matchLabels = { app = "rspamd" } }
      ingress = [
        {
          fromEndpoints = [{ matchLabels = { app = "postfix" } }]
          toPorts       = [{ ports = [{ port = "11332", protocol = "TCP" }] }]
        },
        {
          fromEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"          = "traefik"
              "k8s:io.kubernetes.pod.namespace" = "traefik"
            }
          }]
          toPorts = [{ ports = [{ port = "11334", protocol = "TCP" }] }]
        },
      ]
    }
  }
}

# Dovecot: Postfix LMTP+SASL (24/12345) + SoGO IMAP (143)
# Note: hostPort traffic (143/993/110/995/4190) bypasses NetworkPolicy and is
# controlled by the host firewall on Hestia — no cluster-side rule needed for external clients.
resource "kubernetes_manifest" "np_dovecot" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "dovecot"
      namespace = var.namespace
    }
    spec = {
      endpointSelector = { matchLabels = { app = "dovecot" } }
      ingress = [
        # Postfix: LMTP delivery and SASL auth
        {
          fromEndpoints = [{ matchLabels = { app = "postfix" } }]
          toPorts = [
            { ports = [{ port = "24", protocol = "TCP" }] },
            { ports = [{ port = "12345", protocol = "TCP" }] },
          ]
        },
        # SoGO: internal IMAP access
        {
          fromEndpoints = [{ matchLabels = { app = "sogo" } }]
          toPorts       = [{ ports = [{ port = "143", protocol = "TCP" }, { port = "993", protocol = "TCP" }] }]
        },
        # External mail clients (IMAP/POP3) via externalIPs service.
        # fromEntities "world" covers external IPs; "host" covers traffic
        # SNAT'd to cilium_host IP by Cilium kube-proxy-replacement before
        # reaching the endpoint. fromCIDR 0.0.0.0/0 alone does NOT cover
        # reserved:host identity in Cilium policy evaluation.
        {
          fromEntities = ["world", "host"]
          toPorts = [{ ports = [
            { port = "143", protocol = "TCP" },
            { port = "993", protocol = "TCP" },
            { port = "110", protocol = "TCP" },
            { port = "995", protocol = "TCP" },
            { port = "4190", protocol = "TCP" },
          ] }]
        },
      ]
    }
  }
}

# Postfix: allow egress to rspamd, dovecot, lldap, and external SMTP (port 25)
resource "kubernetes_manifest" "np_postfix" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "postfix"
      namespace = var.namespace
    }
    spec = {
      endpointSelector = { matchLabels = { app = "postfix" } }
      egress = [
        # Rspamd milter
        {
          toEndpoints = [{ matchLabels = { app = "rspamd" } }]
          toPorts     = [{ ports = [{ port = "11332", protocol = "TCP" }] }]
        },
        # Dovecot LMTP + SASL
        {
          toEndpoints = [{ matchLabels = { app = "dovecot" } }]
          toPorts = [
            { ports = [{ port = "24", protocol = "TCP" }] },
            { ports = [{ port = "12345", protocol = "TCP" }] },
          ]
        },
        # lldap virtual mailbox lookup
        {
          toEndpoints = [{ matchLabels = { app = "lldap" } }]
          toPorts     = [{ ports = [{ port = "3890", protocol = "TCP" }] }]
        },
        # External SMTP — direct delivery (port 25) and Mailgun relay (port 587)
        {
          toCIDR = ["0.0.0.0/0"]
          toPorts = [{ ports = [
            { port = "25", protocol = "TCP" },
            { port = "587", protocol = "TCP" },
          ] }]
        },
        # DNS resolution
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "kube-system" } }]
          toPorts     = [{ ports = [{ port = "53", protocol = "UDP" }] }]
        },
      ]
    }
  }
}

# =============================================================================
# SoGO — Webmail (T038, Phase 5)
# Uses salvoxia/sogo: standalone SoGO image with Apache, no MySQL dependency.
# Config is mounted at /srv/etc/sogo.conf via initContainer envsubst injection.
# =============================================================================

resource "kubernetes_config_map" "sogo_config" {
  metadata {
    name      = "sogo-config"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "sogo" })
  }

  data = {
    # Template: uses shell $${VAR} syntax (Terraform escapes $$ → $).
    # initContainer runs envsubst to inject SOGO_DB_URL and LDAP_BIND_PW
    # and writes the result to the shared /srv/etc emptyDir volume.
    "sogo.conf.tmpl" = <<-EOF
      {
        /* SoGO configuration — email-only mode
           Managed by Terraform — do not edit manually */

        /* PostgreSQL session/profile/folder storage */
        SOGoProfileURL = "$${SOGO_DB_URL}/sogo_user_profile";
        OCSFolderInfoURL = "$${SOGO_DB_URL}/sogo_folder_info";
        OCSSessionsFolderURL = "$${SOGO_DB_URL}/sogo_sessions_folder";
        OCSEMailAlarmsFolderURL = "$${SOGO_DB_URL}/sogo_alarms_folder";
        OCSAdminURL = "$${SOGO_DB_URL}/sogo_admin";
        OCSAclURL = "$${SOGO_DB_URL}/sogo_acl";
        OCSCacheFolderURL = "$${SOGO_DB_URL}/sogo_cache_folder";
        OCSStoreURL = "$${SOGO_DB_URL}/sogo_store";

        /* LDAP user source (lldap) */
        SOGoUserSources = (
          {
            type = ldap;
            CNFieldName = cn;
            IDFieldName = uid;
            UIDFieldName = uid;
            IMAPLoginFieldName = mail;
            bindDN = "uid=sogo,${local.ldap_people_dn}";
            bindPassword = "$${LDAP_BIND_PW}";
            baseDN = "${local.ldap_people_dn}";
            canAuthenticate = YES;
            displayName = "Users";
            hostname = "ldap://${var.lldap_host}:3890";
            id = ldap_users;
            isAddressBook = NO;
            filter = "(objectClass=inetOrgPerson)";
          }
        );

        /* Mail protocols */
        SOGoMailingMechanism = smtp;
        SOGoIMAPServer = "imap://dovecot.default.svc.cluster.local:143";
        SOGoSMTPServer = "smtp://postfix.default.svc.cluster.local:587";
        SOGoSMTPAuthenticationType = PLAIN;

        /* Email-only mode */
        SOGoMailModuleEnabled = YES;
        SOGoCalendarModuleEnabled = NO;
        SOGoContactsModuleEnabled = NO;

        /* UI */
        SOGoPageTitle = "Mail";
        SOGoLanguage = English;
        SOGoSupportedLanguages = ("English");

        /* Server binding — salvoxia/sogo uses Apache on port 80 proxying to sogod */
        WOPort = "0.0.0.0:20000";
        WOWorkersCount = 3;

        /* Disable cron inside container (K8s CronJob handles it if needed) */
        /* SOGoEnableEMailAlarms = NO; */
      }
    EOF
  }
}

resource "kubernetes_deployment" "sogo" {
  metadata {
    name      = "sogo"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "sogo" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "sogo" }
    }

    template {
      metadata {
        labels = merge(local.labels, { app = "sogo" })
      }

      spec {
        # initContainer: runs envsubst to produce /srv/etc/sogo.conf from template
        init_container {
          name = "init-config"
          # Use same image as main container — it has envsubst (/usr/bin/envsubst)
          # renovate: datasource=docker depName=salvoxia/sogo
          image = "salvoxia/sogo:${var.image_tag_sogo}"

          command = ["/bin/sh", "-c"]
          args = [
            "envsubst '$$SOGO_DB_URL $$LDAP_BIND_PW' < /tmpl/sogo.conf.tmpl > /srv/etc/sogo.conf && echo 'sogo.conf written'"
          ]

          env {
            name = "SOGO_DB_URL"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.sogo_db.metadata[0].name
                key  = "SOGO_DB_URL"
              }
            }
          }

          env {
            name = "LDAP_BIND_PW"
            value_from {
              secret_key_ref {
                name = data.kubernetes_secret.sogo_ldap.metadata[0].name
                key  = "LDAP_BIND_PW"
              }
            }
          }

          volume_mount {
            name       = "sogo-tmpl"
            mount_path = "/tmpl"
            read_only  = true
          }

          volume_mount {
            name       = "srv-etc"
            mount_path = "/srv/etc"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }
        }

        container {
          name = "sogo"
          # renovate: datasource=docker depName=salvoxia/sogo
          image = "salvoxia/sogo:${var.image_tag_sogo}"

          # salvoxia/sogo exposes Apache on port 80 (proxies to sogod on 20000)
          port {
            container_port = 80
            name           = "http"
            protocol       = "TCP"
          }

          env {
            name  = "DISABLE_CRON"
            value = "1"
          }

          # /srv/etc is populated by initContainer with resolved sogo.conf.
          # Must be writable — entrypoint also copies apache-SOGo.conf here.
          volume_mount {
            name       = "srv-etc"
            mount_path = "/srv/etc"
          }

          liveness_probe {
            http_get {
              path = "/SOGo"
              port = 80
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 5
          }

          readiness_probe {
            http_get {
              path = "/SOGo"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 15
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        # Shared emptyDir for /srv/etc — initContainer writes sogo.conf here
        volume {
          name = "srv-etc"
          empty_dir {}
        }

        # ConfigMap template volume (read-only)
        volume {
          name = "sogo-tmpl"
          config_map {
            name = kubernetes_config_map.sogo_config.metadata[0].name
            items {
              key  = "sogo.conf.tmpl"
              path = "sogo.conf.tmpl"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "sogo" {
  metadata {
    name      = "sogo"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "sogo" })
  }

  spec {
    selector = { app = "sogo" }

    # salvoxia/sogo exposes Apache on port 80
    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "sogo" {
  metadata {
    name      = "sogo"
    namespace = var.namespace
    labels    = merge(local.labels, { app = "sogo" })
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts       = [var.hostname]
      secret_name = "wildcard-brmartin-tls"
    }

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.sogo.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# Network policy: SoGO → lldap (LDAP), dovecot (IMAP), postfix (SMTP)
resource "kubernetes_manifest" "np_sogo" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "sogo"
      namespace = var.namespace
    }
    spec = {
      endpointSelector = { matchLabels = { app = "sogo" } }
      egress = [
        {
          toEndpoints = [{ matchLabels = { app = "lldap" } }]
          toPorts     = [{ ports = [{ port = "3890", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { app = "dovecot" } }]
          toPorts     = [{ ports = [{ port = "143", protocol = "TCP" }, { port = "993", protocol = "TCP" }] }]
        },
        {
          toEndpoints = [{ matchLabels = { app = "postfix" } }]
          toPorts     = [{ ports = [{ port = "587", protocol = "TCP" }] }]
        },
        # External PostgreSQL (192.168.1.10:5433)
        {
          toCIDR  = ["192.168.1.10/32"]
          toPorts = [{ ports = [{ port = "5433", protocol = "TCP" }] }]
        },
        # DNS resolution
        {
          toEndpoints = [{ matchLabels = { "k8s:io.kubernetes.pod.namespace" = "kube-system" } }]
          toPorts     = [{ ports = [{ port = "53", protocol = "UDP" }] }]
        },
      ]
      ingress = [
        {
          fromEndpoints = [{
            matchLabels = {
              "app.kubernetes.io/name"          = "traefik"
              "k8s:io.kubernetes.pod.namespace" = "traefik"
            }
          }]
          # salvoxia/sogo exposes Apache on port 80
          toPorts = [{ ports = [{ port = "80", protocol = "TCP" }] }]
        }
      ]
    }
  }
}
