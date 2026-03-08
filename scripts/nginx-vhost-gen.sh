#!/bin/bash
# nginx-vhost-gen.sh
# Generates nginx reverse proxy configs from ISPconfig Apache vhost files.
#
# HOW IT WORKS:
#   ISPconfig manages Apache vhost files in /etc/apache2/sites-enabled/*.vhost.
#   This script reads those files and generates matching nginx configs in
#   /etc/nginx/sites-available/, then symlinks them into sites-enabled.
#
#   Three types of nginx configs are generated:
#     1. HTTPS proxy  — has an SSL cert in the Apache vhost (most sites)
#     2. HTTP-only    — no SSL cert found (new sites before first certbot run)
#     3. Redirect     — vhost contains a RewriteRule pointing elsewhere
#
# WHY NOT USE ISPconfig NGINX PLUGIN?
#   The ISPconfig nginx plugin would replace Apache entirely. We want to KEEP
#   Apache because ISPconfig's entire PHP-FPM, CGI, and per-site config
#   management is built around Apache. nginx acts purely as a frontend proxy.
#
# ACME CHALLENGE HANDLING:
#   certbot uses ISPconfig's webroot at /usr/local/ispconfig/interface/acme.
#   Apache handles the challenge files. nginx must PROXY /.well-known/acme-challenge/
#   to Apache:9080 — NOT serve it from disk. This keeps certbot working unchanged.
#
# STATIC ASSET SERVING:
#   For HTTPS sites, nginx serves common static files directly from the docroot.
#   This avoids a round-trip through Apache for assets that never change.
#   Falls back to @proxy for files that don't exist on disk (e.g. WordPress rewrites).
#
# SAFARI HTTP/2 FIX:
#   Apache may send Upgrade/Connection hop-by-hop headers in responses.
#   These headers are forbidden in HTTP/2 and cause Safari to abort with
#   PROTOCOL_ERROR. nginx.conf must hide them via proxy_hide_header.
#   (This script generates the proxy blocks; nginx.conf handles the hiding globally.)

set -euo pipefail

APACHE_HTTP_PORT=${APACHE_HTTP_PORT:-9080}
APACHE_PROXY_TARGET=${APACHE_PROXY_TARGET:-127.0.0.1}
OUTPUT_DIR=${OUTPUT_DIR:-/etc/nginx/sites-available}
NGINX_SITES_ENABLED=${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}
VHOST_DIR=${VHOST_DIR:-/etc/apache2/sites-enabled}
ISPCONFIG_DOMAIN=${ISPCONFIG_DOMAIN:-}

mkdir -p "$OUTPUT_DIR"

generated=0
skipped=0

echo "=== nginx-vhost-gen.sh ==="
echo "Source:  $VHOST_DIR"
echo "Output:  $OUTPUT_DIR"
echo "Proxy:   $APACHE_PROXY_TARGET:$APACHE_HTTP_PORT"
echo ""

for vhost_file in "$VHOST_DIR"/*.vhost; do
    [[ -f "$vhost_file" ]] || continue
    filename=$(basename "$vhost_file" .vhost)

    # Skip ISPconfig system vhosts — these are the ISPconfig panel and apps vhosts.
    # They run on non-standard ports and should not be proxied by nginx.
    case "$filename" in
        000-apps|000-ispconfig)
            echo "  SKIP     $filename (system vhost)"
            skipped=$((skipped + 1))
            continue
            ;;
    esac

    servername=$(grep -i '^\s*ServerName\s' "$vhost_file" | head -1 | awk '{print $2}')
    if [[ -z "$servername" ]]; then
        echo "  SKIP     $filename (no ServerName)"
        skipped=$((skipped + 1))
        continue
    fi

    # Collect all ServerAlias entries for the nginx server_name directive.
    # sort -u deduplicates aliases that ISPconfig sometimes duplicates across
    # HTTP and HTTPS blocks.
    serveralias=$(grep -i '^\s*ServerAlias\s' "$vhost_file" \
        | awk '{for(i=2;i<=NF;i++) print $i}' \
        | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)

    docroot=$(grep -i '^\s*DocumentRoot\s' "$vhost_file" | head -1 | awk '{print $2}')

    # SSL cert presence determines whether this is an HTTPS or HTTP-only site.
    # On first deployment, new sites may not have certs yet — they'll be
    # regenerated after the next certbot run (nginx-sync.sh handles this).
    sslcert=$(grep -i '^\s*SSLCertificateFile\s' "$vhost_file" | head -1 | awk '{print $2}' || true)
    sslkey=$(grep -i '^\s*SSLCertificateKeyFile\s' "$vhost_file" | head -1 | awk '{print $2}' || true)

    # Detect redirect-only vhosts: look for RewriteRule pointing to an absolute URL.
    # We exclude:
    #   - Comment lines (#)
    #   - Rules using %{HTTP_HOST} or %{SERVER_NAME} (self-referencing rules, e.g. www→non-www)
    #   - ACME challenge rules
    # If a redirect is found and uses $1 (capture group), we append $request_uri
    # so the full path is preserved in the nginx return redirect.
    redirect_raw=$(grep -i 'RewriteRule' "$vhost_file" \
        | grep -v '#\|%{HTTP_HOST}\|%{SERVER_NAME}\|acme-challenge' \
        | grep -oP 'https?://[^\s\[]+' | head -1 || true)

    redirect_target=""
    if [[ -n "$redirect_raw" ]]; then
        if echo "$redirect_raw" | grep -qF '$'; then
            redirect_target="$(echo "$redirect_raw" | grep -oP 'https?://[^/]+')\$request_uri"
        else
            redirect_target="$redirect_raw"
        fi
    fi

    server_names="$servername"
    [[ -n "$serveralias" ]] && server_names="$servername $serveralias"

    outfile="$OUTPUT_DIR/${filename}.conf"

    # --- TYPE 1: Redirect-only ---
    # ISPconfig creates redirect vhosts when a domain is configured as
    # "redirect" in the site settings. nginx handles this with a simple return.
    if [[ -n "$redirect_target" ]]; then
        cat > "$outfile" << NGINXEOF
# Generated by nginx-vhost-gen.sh -- DO NOT EDIT MANUALLY
# Source: $vhost_file
# Type: redirect-only
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;
    return 302 $redirect_target;
}
NGINXEOF
        echo "  REDIRECT $filename → $redirect_target"

    # --- TYPE 2: HTTP-only (no SSL cert yet) ---
    # Site exists but has no certificate yet. Serve over HTTP only.
    # ACME challenge is still proxied to Apache so certbot can issue a cert.
    elif [[ -z "$sslcert" ]]; then
        cat > "$outfile" << NGINXEOF
# Generated by nginx-vhost-gen.sh -- DO NOT EDIT MANUALLY
# Source: $vhost_file
# Type: HTTP-only (no SSL cert found in Apache vhost)
#
# This config will be upgraded to HTTPS once certbot issues a certificate
# and nginx-sync.sh detects the vhost change.
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

    # Proxy ACME challenge to Apache — certbot uses ISPconfig's webroot.
    # See: /usr/local/ispconfig/interface/acme/
    location /.well-known/acme-challenge/ {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
    }

    location / {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINXEOF
        echo "  HTTP     $filename (no SSL cert)"

    # --- TYPE 3: HTTPS proxy ---
    # Full HTTPS site with nginx handling TLS termination.
    # nginx serves static assets directly; everything else proxied to Apache.
    else
        cat > "$outfile" << NGINXEOF
# Generated by nginx-vhost-gen.sh -- DO NOT EDIT MANUALLY
# Source: $vhost_file
# Type: HTTPS proxy
server {
    listen 80;
    listen [::]:80;
    server_name $server_names;

    # ACME challenge must go to Apache — certbot uses ISPconfig's webroot plugin.
    # Do NOT serve /.well-known/acme-challenge/ from disk here.
    location /.well-known/acme-challenge/ {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
    }

    # Redirect all HTTP traffic to HTTPS.
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $server_names;

    # Use the same certificates that certbot manages for Apache.
    # This works because certbot stores certs in /etc/letsencrypt, which both
    # Apache and nginx can read. No need for separate cert management.
    ssl_certificate $sslcert;
    ssl_certificate_key $sslkey;

    # ACME challenge proxied even on port 443, for certbot --preferred-challenges tls-alpn-01
    # and for consistency. Also ensures cert renewals work without downtime.
    location /.well-known/acme-challenge/ {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
    }

    # Serve static assets directly from docroot — avoids Apache round-trip.
    # @proxy fallback ensures WordPress/CMS rewrite rules still work for
    # any "static" URL that is actually handled by PHP (e.g. /wp-content/... rewrites).
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|woff|ttf|svg|webp|pdf|gz|zip|mp4|mp3|webm|ogg|avi|mov|wmv|flv|m4v|m4a|aac|wav|doc|docx|xls|xlsx|ppt|pptx|odt|ods|odp)$ {
        root $docroot;
        try_files \$uri @proxy;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location @proxy {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
        # Tell Apache/PHP this is an HTTPS request — PHP checks \$_SERVER['HTTPS'].
        # apache-nginx-proxy.conf sets HTTPS=on for 127.0.0.1 at the Apache level,
        # but X-Forwarded-Proto is available for apps that check it explicitly.
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINXEOF
        echo "  HTTPS    $filename ($servername)"
    fi

    # Symlink into sites-enabled when running in production mode.
    # Skip if OUTPUT_DIR is non-default (e.g. dry-run to /tmp).
    if [[ "$OUTPUT_DIR" == "/etc/nginx/sites-available" && -d "$NGINX_SITES_ENABLED" ]]; then
        symlink="$NGINX_SITES_ENABLED/${filename}.conf"
        [[ ! -e "$symlink" ]] && ln -s "$outfile" "$symlink"
    fi

    generated=$((generated + 1))
done

# --- ISPconfig Panel Domain block ---
# The ISPconfig panel runs on port 8080 (or 8443). If ISPCONFIG_DOMAIN is set,
# generate a dedicated nginx block that:
#   - Handles ACME challenges (so the panel domain can have a valid cert)
#   - Redirects HTTP to the panel's HTTPS port
# This avoids conflicts with other sites and ensures the panel domain is reachable.
if [[ -n "$ISPCONFIG_DOMAIN" ]]; then
    outfile="$OUTPUT_DIR/ispconfig-panel.conf"
    cat > "$outfile" << NGINXEOF
# Generated by nginx-vhost-gen.sh -- DO NOT EDIT MANUALLY
# ISPconfig Panel domain: $ISPCONFIG_DOMAIN
# The panel itself runs on :8080 (HTTP) or :8443 (HTTPS) — not through nginx.
# This block only exists to handle ACME challenges and HTTP→panel redirects.
server {
    listen 80;
    listen [::]:80;
    server_name $ISPCONFIG_DOMAIN;

    location /.well-known/acme-challenge/ {
        proxy_pass http://$APACHE_PROXY_TARGET:$APACHE_HTTP_PORT;
        proxy_set_header Host \$host;
    }

    location / {
        return 301 https://$ISPCONFIG_DOMAIN:8080\$request_uri;
    }
}
NGINXEOF
    if [[ "$OUTPUT_DIR" == "/etc/nginx/sites-available" && -d "$NGINX_SITES_ENABLED" ]]; then
        symlink="$NGINX_SITES_ENABLED/ispconfig-panel.conf"
        [[ ! -e "$symlink" ]] && ln -s "$outfile" "$symlink"
    fi
    echo "  ISPCONFIG $ISPCONFIG_DOMAIN → :8080"
    generated=$((generated + 1))
fi

echo ""
echo "Generated: $generated | Skipped: $skipped"

# Only test and restart nginx when writing to the real production directory.
if [[ "$OUTPUT_DIR" == "/etc/nginx/sites-available" ]] && command -v nginx &>/dev/null; then
    echo ""
    if nginx -t 2>&1; then
        echo "nginx config OK"
        systemctl restart nginx && echo "nginx restarted"
    else
        echo "nginx -t failed — no restart performed"
        exit 1
    fi
fi
