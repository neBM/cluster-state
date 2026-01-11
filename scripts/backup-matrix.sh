#!/bin/bash
set -euo pipefail

# Matrix Backup Script
# CRITICAL: This backs up Matrix signing keys and all data

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PHASE2_BACKUP="/mnt/csi/backups/glusterfs-migration-$TIMESTAMP/phase2"

echo "=== Matrix Critical Backup ==="
echo "Backup destination: $PHASE2_BACKUP"
echo "Started: $(date)"

# Create backup directory
mkdir -p "$PHASE2_BACKUP"

# CRITICAL: Backup signing keys
echo "Backing up signing keys..."
sudo cp -a /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key \
  "$PHASE2_BACKUP/signing-key-CRITICAL" || { echo "SIGNING KEY BACKUP FAILED!"; exit 1; }

# Backup all Synapse config
echo "Backing up Synapse config..."
sudo rsync -avP /mnt/docker/matrix/synapse/ "$PHASE2_BACKUP/synapse/"

# Backup media store (this may take time)
echo "Backing up media store..."
sudo rsync -avP /mnt/docker/matrix/media_store/ "$PHASE2_BACKUP/media_store/"

# Backup WhatsApp bridge
echo "Backing up WhatsApp bridge..."
sudo rsync -avP /mnt/docker/matrix/whatsapp-data/ "$PHASE2_BACKUP/whatsapp-data/"

# Backup static configs
echo "Backing up static configs..."
sudo rsync -avP /mnt/docker/matrix/synapse-mas/ "$PHASE2_BACKUP/synapse-mas/"
sudo rsync -avP /mnt/docker/matrix/nginx/ "$PHASE2_BACKUP/nginx/"
sudo rsync -avP /mnt/docker/matrix/cinny/ "$PHASE2_BACKUP/cinny/"

# Verify backup
echo "Verifying critical signing key..."
diff /mnt/docker/matrix/synapse/brmartin.co.uk.signing.key \
  "$PHASE2_BACKUP/signing-key-CRITICAL"

if [ $? -eq 0 ]; then
  echo "✓ Signing key backup verified"
else
  echo "✗ SIGNING KEY BACKUP FAILED!"
  exit 1
fi

# Calculate checksums
echo "Calculating checksums..."
find "$PHASE2_BACKUP" -type f -exec sha256sum {} \; > "$PHASE2_BACKUP/checksums.txt"

echo "Completed: $(date)"
echo "Backup size:"
du -sh "$PHASE2_BACKUP"

echo ""
echo "CRITICAL: Copy signing key to offline/offsite storage NOW!"
echo "Location: $PHASE2_BACKUP/signing-key-CRITICAL"
echo ""
echo "Backup location: $PHASE2_BACKUP"