#!/bin/bash
# setup.sh
# Interactive setup script for ISPconfig nginx reverse proxy.
#
# USAGE:
#   sudo bash setup.sh           # full interactive setup
#   sudo bash setup.sh --dry-run # preview actions without making changes
#
# WHAT THIS SCRIPT DOES:
#   1. Checks prerequisites (root, Ubuntu, ISPconfig)
#   2. Asks for ISPconfig panel domain
#   3. Installs nginx + brotli modules
#   4. Backs up existing Apache config and /etc/letsencrypt
#   5. Deploys nginx.conf (backs up existing)
#   6. Deploys apache-nginx-proxy.conf and enables it
#   7. Copies scripts to /root/bin/
#   8. Shows MANUAL STEPS that require ISPconfig admin UI interaction
#   9. After confirmation: runs nginx-vhost-gen.sh and starts nginx
#  10. Sets up certbot post-renewal hook
#  11. Sets up cronjob for nginx-sync.sh
#
# PHILOSOPHY:
#   This script does NOT touch ISPconfig's configuration or database directly.
#   ISPconfig manages Apache; nginx is layered in front. The script is
#   designed to be safe to re-run and to roll back cleanly if something fails.

set -euo pipefail

##
# Color output helpers
##
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
step()   { echo -e "\n${BOLD}==> $*${NC}"; }
hr()     { echo -e "${BLUE}────────────────────────────────────────────────${NC}"; }
anykey() { echo -e "${YELLOW}--- Press any key when done ---${NC}"; read -rp "" -n1 -s; echo ""; }

##
# Dry-run mode
##
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    warn "DRY-RUN mode: no changes will be made."
    echo ""
fi

run() {
    # Wrapper: in dry-run mode, just print the command.
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

##
# STEP 0: Prerequisite checks
##
step "Checking prerequisites"

# Must be root
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    echo "  Try: sudo bash $0"
    exit 1
fi
ok "Running as root"

# Must be Ubuntu (ISPconfig is Linux-only; Apache paths differ on other distros)
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    err "This script requires Ubuntu or Debian (Debian-based Apache layout)."
    err "ISPconfig on AlmaLinux/Rocky Linux uses a different Apache structure"
    err "(/etc/httpd/, apachectl, no a2enconf) and is not supported by this script."
    grep PRETTY_NAME /etc/os-release || true
    exit 1
fi
OS_NAME=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
ok "$OS_NAME $OS_VERSION detected"

# Check ISPconfig is installed
if [[ ! -d /usr/local/ispconfig ]]; then
    err "ISPconfig not found at /usr/local/ispconfig"
    echo "  This script is designed for servers with ISPconfig 3.2+ installed."
    exit 1
fi
ok "ISPconfig installation found"

# Check Apache is running
if ! systemctl is-active --quiet apache2; then
    err "Apache2 is not running. Start it first: systemctl start apache2"
    exit 1
fi
ok "Apache2 is running"

# Check for existing nginx — warn if already installed
if systemctl is-active --quiet nginx 2>/dev/null; then
    warn "nginx is already running. This script will overwrite /etc/nginx/nginx.conf."
    warn "Existing site configs in /etc/nginx/sites-available/ will NOT be removed."
fi

##
# STEP 1: Gather configuration
##
step "Configuration"

hr
echo ""
echo "This setup places nginx in front of Apache on your ISPconfig server."
echo "After setup:"
echo "  - nginx listens on ports 80 and 443"
echo "  - Apache moves to 127.0.0.1:9080 and 127.0.0.1:9443"
echo "  - ISPconfig continues to manage Apache vhosts unchanged"
echo ""
hr

# Auto-detect: ISPconfig always runs on the server's FQDN
DETECTED_DOMAIN=$(hostname -f 2>/dev/null)
if [[ -n "$DETECTED_DOMAIN" ]]; then
    info "Detected ISPconfig panel domain: $DETECTED_DOMAIN"
    read -rp "Use '$DETECTED_DOMAIN'? Press Enter to confirm or type a different domain: " INPUT_DOMAIN
    ISPCONFIG_DOMAIN="${INPUT_DOMAIN:-$DETECTED_DOMAIN}"
else
    read -rp "Enter your ISPconfig panel domain (e.g. server.example.com): " ISPCONFIG_DOMAIN
fi
if [[ -z "$ISPCONFIG_DOMAIN" ]]; then
    warn "No ISPconfig domain entered. The panel redirect block will be skipped."
fi

echo ""
while true; do
    read -rp "Install scripts to directory [/root/bin]: " SCRIPTS_DIR
    SCRIPTS_DIR="${SCRIPTS_DIR:-/root/bin}"
    if [[ "$SCRIPTS_DIR" != /* ]]; then
        warn "Please enter an absolute path (starting with /). Got: '$SCRIPTS_DIR'"
        continue
    fi
    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        read -rp "  Directory '$SCRIPTS_DIR' does not exist. Create it? (yes/no): " CREATE_DIR
        if [[ "$CREATE_DIR" == "yes" ]]; then
            run mkdir -p "$SCRIPTS_DIR"
            ok "Created: $SCRIPTS_DIR"
            break
        else
            warn "Please enter an existing directory."
        fi
    else
        break
    fi
done
info "Scripts will be installed to: $SCRIPTS_DIR"

echo ""
info "Using ISPconfig domain: ${ISPCONFIG_DOMAIN:-'(none)'}"
echo ""

##
# STEP 2: Install nginx + brotli
##
step "Installing nginx and brotli modules"

run apt-get update -qq
run apt-get install -y nginx libnginx-mod-http-brotli-filter libnginx-mod-http-brotli-static

if command -v nginx &>/dev/null; then
    ok "nginx installed: $(nginx -v 2>&1 | head -1)"
else
    ok "nginx will be installed"
fi

##
# STEP 3: Backup existing configs
##
step "Backing up existing configurations"

BACKUP_DIR="/root/nginx-setup-backup-$(date +%Y%m%d-%H%M%S)"
info "Backup directory: $BACKUP_DIR"

run mkdir -p "$BACKUP_DIR"

# Backup Apache ports.conf and existing nginx.conf
for f in /etc/apache2/ports.conf /etc/nginx/nginx.conf; do
    if [[ -f "$f" ]]; then
        run cp "$f" "$BACKUP_DIR/"
        ok "Backed up: $f"
    fi
done

# Backup Let's Encrypt config (just the config, not the certs themselves)
if [[ -d /etc/letsencrypt ]]; then
    run cp -r /etc/letsencrypt "$BACKUP_DIR/letsencrypt"
    ok "Backed up: /etc/letsencrypt"
fi

##
# STEP 4: Deploy nginx.conf
##
step "Deploying nginx.conf"

if [[ -f /etc/nginx/nginx.conf ]]; then
    run cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    ok "Backed up existing nginx.conf to nginx.conf.bak"
fi

run cp "$SCRIPT_DIR/configs/nginx.conf" /etc/nginx/nginx.conf
ok "nginx.conf deployed"

# Disable the default nginx site if it exists
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    run rm /etc/nginx/sites-enabled/default
    ok "Removed default nginx site"
fi

##
# STEP 5: Deploy Apache HTTPS detection config
##
step "Deploying Apache nginx-proxy conf"

run cp "$SCRIPT_DIR/configs/apache-nginx-proxy.conf" /etc/apache2/conf-available/nginx-proxy.conf
ok "apache-nginx-proxy.conf deployed"

run a2enconf nginx-proxy
ok "nginx-proxy conf enabled"

# Test Apache config before reloading
if apache2ctl configtest; then
    run systemctl reload apache2
    ok "Apache reloaded"
else
    err "Apache config test failed. Check /etc/apache2/conf-available/nginx-proxy.conf"
    exit 1
fi

##
# STEP 6: Install scripts
##
step "Installing scripts to $SCRIPTS_DIR"

run mkdir -p "$SCRIPTS_DIR"
run cp "$SCRIPT_DIR/scripts/nginx-vhost-gen.sh" "$SCRIPTS_DIR/nginx-vhost-gen.sh"
run cp "$SCRIPT_DIR/scripts/nginx-sync.sh" "$SCRIPTS_DIR/nginx-sync.sh"
run chmod +x "$SCRIPTS_DIR/nginx-vhost-gen.sh" "$SCRIPTS_DIR/nginx-sync.sh"
ok "Scripts installed and made executable"

##
# STEP 7: Stop nginx (not yet safe to start)
##
step "Stopping nginx"

# nginx must NOT be started yet — Apache still listens on 80/443.
# We need to complete the ISPconfig manual steps first, which move
# Apache to port 9080, before nginx can take over ports 80/443.
if systemctl is-active --quiet nginx; then
    run systemctl stop nginx
    ok "nginx stopped"
else
    ok "nginx was not running (expected)"
fi

##
# STEP 8: Manual steps instructions
##
step "MANUAL STEPS REQUIRED"

hr
echo ""
echo -e "${BOLD}The following steps must be completed in ISPconfig before nginx can start.${NC}"
echo -e "${BOLD}nginx is currently stopped. Do NOT start it until all steps are done.${NC}"
echo ""

echo -e "${BOLD}Step A — ISPconfig Admin UI${NC}"
echo "  1. Log in to ISPconfig as admin"
echo "  2. Go to: System → Server Config → Web"
echo "  3. Set the following:"
echo ""
echo -e "     ${YELLOW}Enable PROXY Protocol:${NC}     on (all sites)"
echo -e "     ${YELLOW}Use PROXY Protocol:${NC}        on (IPv4 + IPv6)"
echo -e "     ${YELLOW}PROXY Protocol HTTP Port:${NC}  9080"
echo -e "     ${YELLOW}PROXY Protocol HTTPS Port:${NC} 9443"
echo ""
echo "  4. Click Save"
echo "  5. Go to: Tools → Sync Tools → Resync Websites"
echo "  6. Wait for ISPconfig to rewrite all vhost files (check:"
echo "     grep -l ':9080' /etc/apache2/sites-enabled/*.vhost | wc -l)"
echo ""
anykey

echo -e "${BOLD}Step B — Disable HTTP→HTTPS redirects${NC}"
echo "  nginx will handle HTTP→HTTPS redirects. ISPconfig's built-in redirect"
echo "  would cause a redirect loop. Disable it using ONE of these options:"
echo ""
echo -e "  ${BOLD}Option 1 — Via ISPconfig UI (per site):${NC}"
echo "    For each site: Sites → Website → Redirect → uncheck 'Redirect to HTTPS' and save"
echo ""
echo -e "  ${BOLD}Option 2 — Via MySQL (all sites at once, recommended):${NC}"
echo -e "     ${YELLOW}mysql dbispconfig -e \"UPDATE web_domain SET rewrite_to_https = 'n' WHERE rewrite_to_https = 'y';\"${NC}"
echo "    Then resync in ISPconfig: Tools → Sync Tools → Resync Websites"
echo ""
anykey

echo -e "${BOLD}Step C — Nextcloud (if applicable)${NC}"
echo "  For each Nextcloud instance, add to config/config.php:"
echo ""
echo -e "     ${YELLOW}'trusted_proxies' => ['127.0.0.1'],${NC}"
echo -e "     ${YELLOW}'overwriteprotocol' => 'https',${NC}"
echo ""
anykey

echo -e "${BOLD}Step D — Update ports.conf${NC}"
echo "  ISPconfig does NOT update /etc/apache2/ports.conf automatically."
echo ""
read -rp "  Should this script update ports.conf for you? (yes/no): " UPDATE_PORTS
if [[ "$UPDATE_PORTS" == "yes" ]]; then
    run cp /etc/apache2/ports.conf /etc/apache2/ports.conf.bak
    ok "Backup created: /etc/apache2/ports.conf.bak"
    if ! $DRY_RUN; then
        cat > /etc/apache2/ports.conf << 'EOF'
# Managed by nginx reverse proxy setup
# nginx listens on 80/443 — Apache only on localhost
Listen 9080

<IfModule ssl_module>
Listen 9443
</IfModule>

<IfModule mod_gnutls.c>
Listen 9443
</IfModule>
EOF
    fi
    ok "ports.conf updated"
    if ! $DRY_RUN && ! apache2ctl configtest; then
        err "Apache config test failed — restoring backup and aborting"
        cp /etc/apache2/ports.conf.bak /etc/apache2/ports.conf
        exit 1
    fi
    run systemctl restart apache2
    ok "Apache restarted"
else
    echo ""
    echo "  Do it manually:"
    echo -e "     ${YELLOW}cp /etc/apache2/ports.conf /etc/apache2/ports.conf.bak${NC}"
    echo -e "     ${YELLOW}cat > /etc/apache2/ports.conf << 'EOF'"
    echo "     Listen 9080"
    echo "     <IfModule ssl_module>"
    echo "         Listen 9443"
    echo "     </IfModule>"
    echo -e "     EOF${NC}"
    echo "  Then: systemctl restart apache2"
    echo ""
    anykey
fi

sleep 10

echo -e "${BOLD}Step E — Verify Apache moved off port 80 and 443 ${NC}"
echo "You should see apache only on port 9080 and 9433"
echo ""
echo "  Current listening ports:"
ss -tlnp | grep -E ':80|:443|:9080|:9443' | awk '{match($0, /users:\(\("([^"]+)"/, a); printf "  %-20s %s\n", $4, a[1]}' || echo "  (none found)"
echo ""
read -rp "  Do you still see Apache on port 80 or 443? (yes/no): " PORTS_CLEAR
if [[ "$PORTS_CLEAR" == "yes" ]]; then
    warn "Apache is still on port 80/443. Complete steps A-C before continuing."
    warn "Re-run this script when done."
    exit 1
fi
ok "Ports look good — Apache is off 80/443"

hr

##
# STEP 9: Generate nginx configs and start nginx
##
step "Generating nginx vhost configs"

ISPCONFIG_DOMAIN="$ISPCONFIG_DOMAIN" run "$SCRIPTS_DIR/nginx-vhost-gen.sh"

ok "nginx vhost configs generated"

step "Starting nginx"

if ! $DRY_RUN; then
    if nginx -t; then
        ok "nginx config test passed"
        systemctl enable nginx
        systemctl start nginx
        ok "nginx started and enabled"
    else
        err "nginx config test failed. Check the generated configs in /etc/nginx/sites-available/"
        err "nginx is NOT running. Fix the errors and start it manually."
        exit 1
    fi
else
    run nginx -t
    run systemctl enable nginx
    run systemctl start nginx
fi

##
# STEP 10: certbot post-renewal hook
##
step "Setting up certbot post-renewal hook"

HOOK_DIR=/etc/letsencrypt/renewal-hooks/post
HOOK_FILE="$HOOK_DIR/reload-nginx.sh"

run mkdir -p "$HOOK_DIR"
if ! $DRY_RUN; then
    cat > "$HOOK_FILE" << 'EOF'
#!/bin/bash
# Restart nginx after certbot renews a certificate.
# certbot runs post hooks after successful renewals.
# nginx must restart to pick up new certificate files.
systemctl restart nginx
EOF
    chmod +x "$HOOK_FILE"
fi

ok "certbot post-renewal hook installed: $HOOK_FILE"

##
# STEP 11: Cronjob for nginx-sync.sh
##
step "Setting up nginx-sync cronjob"

echo "How often should nginx-sync run?"
echo "  This determines how quickly nginx picks up changes made in ISPconfig"
echo "  (new sites, deleted sites, changed domains). Lower = faster sync."
echo ""
echo "  1) Every minute   — changes apply within 60s (recommended)"
echo "  2) Every 2 minutes"
echo "  3) Every 5 minutes"
echo "  4) Every 10 minutes"
read -rp "  Choose [1-4, default=1]: " SYNC_FREQ
case "${SYNC_FREQ:-1}" in
    2) CRON_SCHEDULE="*/2 * * * *" ;;
    3) CRON_SCHEDULE="*/5 * * * *" ;;
    4) CRON_SCHEDULE="*/10 * * * *" ;;
    *) CRON_SCHEDULE="* * * * *" ;;
esac
info "Cronjob schedule: $CRON_SCHEDULE"

CRON_FILE=/etc/cron.d/nginx-sync
CRON_LINE="$CRON_SCHEDULE root VHOST_GEN=$SCRIPTS_DIR/nginx-vhost-gen.sh $SCRIPTS_DIR/nginx-sync.sh >> /var/log/nginx-sync.log 2>&1"

if ! $DRY_RUN; then
    echo "$CRON_LINE" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
fi

ok "Cronjob installed: $CRON_FILE"
info "Log file: /var/log/nginx-sync.log"

##
# Done
##
echo ""
hr
echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "What's running now:"
echo "  - nginx: listening on ports 80 and 443 (TLS termination)"
echo "  - Apache: listening on 127.0.0.1:9080 / 9443 (backend)"
echo "  - Auto-sync: every minute via cron (nginx-sync.sh)"
echo ""
echo "Useful commands:"
echo "  nginx -t                           # test nginx config"
echo "  systemctl status nginx             # nginx status"
echo "  journalctl -u nginx -f             # nginx logs"
echo "  tail -f /var/log/nginx-sync.log    # sync log"
echo "  $SCRIPTS_DIR/nginx-vhost-gen.sh    # manual config regeneration"
echo ""
echo "If something breaks:"
echo "  systemctl stop nginx"
echo "  cp /etc/apache2/ports.conf.bak /etc/apache2/ports.conf && systemctl restart apache2"
echo "  # revert ISPconfig settings (undo PROXY Protocol changes)"
echo ""
hr

exit 0
