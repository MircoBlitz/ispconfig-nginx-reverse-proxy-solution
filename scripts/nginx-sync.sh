#!/bin/bash
# nginx-sync.sh
# Detects ISPconfig vhost changes and regenerates nginx configs automatically.
#
# HOW IT WORKS:
#   Every minute (via cron), this script computes an MD5 hash of all Apache
#   vhost files. If the hash differs from the stored hash, ISPconfig has
#   changed something (new site, SSL cert issued, site deleted, etc.) and
#   nginx-vhost-gen.sh is re-run to regenerate all nginx configs.
#
# WHY MD5 OF ALL VHOSTS?
#   ISPconfig writes vhost files atomically via its own cron job. Watching
#   individual files with inotify would require a persistent daemon.
#   MD5 hashing is simpler, stateless, and robust — if ISPconfig adds,
#   removes, or modifies any vhost, the aggregate hash changes.
#
# CERTBOT INTEGRATION:
#   When certbot renews a cert, it does NOT modify the Apache vhost directly
#   (the cert path stays the same). However, the certbot post-renewal hook
#   (/etc/letsencrypt/renewal-hooks/post/reload-nginx.sh) should reload nginx.
#   This script does not need to handle certbot renewals.
#
# CRONJOB:
#   * * * * * root /root/bin/nginx-sync.sh >> /var/log/nginx-sync.log 2>&1
#
# LOGGING:
#   Output goes to stdout/stderr. Redirect to a log file in the crontab.
#   Only prints output when a change is detected — silent on no-op runs.

set -euo pipefail

VHOST_DIR=${VHOST_DIR:-/etc/apache2/sites-enabled}
HASH_FILE=${HASH_FILE:-/etc/nginx/.vhost-hash}
VHOST_GEN=${VHOST_GEN:-/root/bin/nginx-vhost-gen.sh}

# Compute aggregate MD5 of all vhost files.
# md5sum on each file, then md5sum of that combined output.
# This detects: file content changes, new files, deleted files (different count = different hash).
CURRENT=$(md5sum "$VHOST_DIR"/*.vhost 2>/dev/null | md5sum | cut -d' ' -f1)
STORED=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$CURRENT" != "$STORED" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') vhost change detected, regenerating nginx configs..."
    if "$VHOST_GEN"; then
        echo "$CURRENT" > "$HASH_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') nginx configs updated successfully"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') nginx-vhost-gen.sh failed — hash NOT updated, will retry next minute"
        exit 1
    fi
fi
