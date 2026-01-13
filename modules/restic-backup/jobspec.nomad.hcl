job "restic-backup" {
  type = "batch"

  periodic {
    crons            = ["0 3 * * *"] # Daily at 3am
    prohibit_overlap = true
    time_zone        = "Europe/London"
  }

  group "backup" {
    constraint {
      attribute = "${node.unique.name}"
      value     = "Hestia"
    }

    task "backup" {
      driver = "docker"

      config {
        image = "restic/restic:0.17.3"
        args  = ["/local/backup.sh"]
        entrypoint = ["/bin/sh"]

        mount {
          type     = "bind"
          source   = "/storage/v"
          target   = "/data"
          readonly = true
        }

        mount {
          type     = "bind"
          source   = "/mnt/csi/backups/restic"
          target   = "/repo"
          readonly = false
        }
      }

      template {
        destination = "local/backup.sh"
        perms       = "755"
        data        = <<-EOF
        #!/bin/sh
        set -e

        export RESTIC_REPOSITORY=/repo
        export RESTIC_PASSWORD_FILE=/local/password

        # Initialize repo if needed
        if ! restic snapshots >/dev/null 2>&1; then
          echo "Initializing restic repository..."
          restic init
        fi

        echo "Starting backup of GlusterFS volumes..."

        restic backup /data \
          --verbose \
          --tag glusterfs \
          --tag scheduled \
          --iexclude-file=/local/excludes.txt \
          --exclude-caches \
          --exclude-if-present .nobackup \
          --one-file-system \
          --skip-if-unchanged

        echo "Backup complete. Running cleanup..."

        # Keep 7 daily, 4 weekly, 6 monthly snapshots
        restic forget \
          --keep-daily 7 \
          --keep-weekly 4 \
          --keep-monthly 6 \
          --prune

        echo "Checking repository integrity..."
        restic check

        echo "Backup job finished successfully"
        EOF
      }

      template {
        destination = "local/excludes.txt"
        data        = <<-EOF
        # Temporary and log files
        *.tmp
        *.log
        *.sock

        # SQLite temp files
        *-wal
        *-shm

        # Cache directories
        cache
        .cache

        # Log directories
        logs
        log

        # Plex/Jellyfin regenerable data
        codecs
        crash reports
        diagnostics
        updates
        media
        metadata
        transcodes

        # Ollama models (downloadable)
        glusterfs_ollama_data
        EOF
      }

      template {
        destination = "local/password"
        perms       = "400"
        data        = <<-EOF
{{ with secret "nomad/default/restic-backup" }}{{ .Data.data.RESTIC_PASSWORD }}{{ end }}
        EOF
      }

      vault {}

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 2048
      }
    }
  }
}
