# ISPconfig nginx Reverse Proxy

Put nginx in front of Apache on your ISPconfig server — without touching ISPconfig's configuration.

**What you get:**
- TLS termination, HTTP/2, Brotli and Gzip compression in nginx
- Static assets (images, CSS, JS, fonts, videos, documents) served directly by nginx
- Apache moves to `localhost:9080/9443` — ISPconfig keeps managing it unchanged
- Auto-sync: nginx configs regenerate automatically when ISPconfig adds or changes sites
- Works with WordPress, Joomla, Nextcloud, and any PHP application ISPconfig manages
- certbot keeps working exactly as before

**Tested on:** Ubuntu 24.04 LTS, ISPconfig 3.3.x, Apache 2.4, nginx 1.24

> ⚠️ **Platform:** This project is written and tested for **Ubuntu and Debian only**.
> ISPconfig also runs on AlmaLinux and Rocky Linux, but those systems use a different
> Apache layout (`/etc/httpd/`, `apachectl`, no `a2enconf`) which is not yet supported.
> See [TODO](#todo) below.

---

## Motivation

After moving away from Plesk, I chose ISPconfig to manage my servers. It's powerful and flexible, but many of the sites I run are tightly coupled to Apache — `.htaccess` rules, PHP-FPM per-site configs, ISPconfig's vhost management. Replacing Apache with nginx entirely was not an option.

What I wanted was nginx handling TLS termination, HTTP/2, compression, and static assets at the front, while Apache continues doing what ISPconfig tells it to do in the back. I wrote this toolset to automate that setup across multiple ISPconfig installations, and I'm sharing it in case it's useful to others in the same situation.

---

## Architecture

```
Browser
   │
   │ :80 / :443
   ▼
┌─────────────────────────────────────┐
│              nginx                  │
│  TLS termination, HTTP/2, Brotli    │
│  Static asset serving               │
│  HTTP→HTTPS redirect                │
└────────────────┬────────────────────┘
                 │ proxy_pass :9080
                 │ X-Forwarded-Proto: https
                 ▼
┌─────────────────────────────────────┐
│              Apache                 │
│  localhost:9080/9443                │
│  ISPconfig-managed vhosts           │
│  PHP-FPM, .htaccess, all CMS logic  │
└─────────────────────────────────────┘
```

certbot continues using the ISPconfig webroot method — ACME challenges are proxied through nginx to Apache transparently.

---

## Prerequisites

- Ubuntu 22.04 or 24.04 LTS
- ISPconfig 3.2 or newer
- Root access
- All sites already have SSL certificates (new sites without certs get HTTP-only nginx configs and upgrade automatically after certbot runs)

---

## Quick Start

```bash
git clone https://github.com/youruser/ispconfig-nginx-reverse-proxy-solution.git
cd ispconfig-nginx-reverse-proxy-solution
sudo bash setup.sh
```

The setup script is interactive and walks you through every step. Use `--dry-run` to preview without making changes:

```bash
sudo bash setup.sh --dry-run
```

---

## Manual Steps (Required — cannot be automated)

The setup script will pause and show you these steps at the right moment. They require clicking through the ISPconfig admin UI.

### Step 1 — Disable HTTP→HTTPS auto-redirects

ISPconfig generates HTTP→HTTPS redirect rules in Apache vhosts. Once nginx handles redirects, these would cause redirect loops. Disable them via MySQL:

```sql
-- Run on your server as root:
mysql dbispconfig -e "UPDATE web_domain SET rewrite_to_https = 'n' WHERE rewrite_to_https = 'y';"
```

Then go to **ISPconfig Admin → Tools → Sync Tools → Resync Websites** to regenerate vhosts.

### Step 2 — Configure ISPconfig PROXY Protocol

In **ISPconfig Admin → System → Server Config → Web**, set:

| Setting | Value |
|---------|-------|
| Enable PROXY Protocol | ✅ on |
| Use PROXY Protocol (IPv4 + IPv6) | ✅ on |
| Use PROXY Protocol (IPv6) | ✅ on |
| PROXY Protocol HTTP Port | `9080` |
| PROXY Protocol HTTPS Port | `9443` |

Click **Save**, then go to **Tools → Sync Tools → Resync Websites** again.

ISPconfig will now add `<VirtualHost *:9080>` blocks to all vhosts. **Note:** ISPconfig does NOT update `/etc/apache2/ports.conf` — the setup script handles that.

### Step 3 — For Nextcloud instances

Add these two lines to each Nextcloud `config/config.php`:

```php
'trusted_proxies' => ['127.0.0.1'],
'overwriteprotocol' => 'https',
```

This tells Nextcloud to trust the `X-Forwarded-Proto` header from nginx and generate correct HTTPS URLs. Without this, CalDAV/CardDAV sync clients may break.

---

## How It Works

### Config Generator (`scripts/nginx-vhost-gen.sh`)

Reads all `*.vhost` files from `/etc/apache2/sites-enabled/` and generates matching nginx configs. Three site types are handled automatically:

| Type | Detection | nginx output |
|------|-----------|--------------|
| **HTTPS proxy** | `SSLCertificateFile` present | `listen 443 ssl http2` + proxy to `:9080` |
| **HTTP-only** | No SSL cert found | `listen 80` + proxy to `:9080` |
| **Redirect** | `RewriteRule` to external URL | `return 302 <target>` |

The ISPconfig panel domain (e.g. `server.example.com`) gets its own block that handles ACME challenges and redirects to the ISPconfig UI on port 8080.

**ACME challenges** are proxied to Apache, which serves them from ISPconfig's webroot at `/usr/local/ispconfig/interface/acme`. certbot continues working with no changes to renewal configs.

**Static assets** use `try_files $uri @proxy` — nginx serves files that exist on disk directly and falls through to Apache for anything dynamic. This also works correctly with WordPress page caches (WP Super Cache, etc.) since cached HTML files are served by nginx when they exist.

### Auto-Sync (`scripts/nginx-sync.sh`)

Runs every minute via cron. Computes an MD5 checksum of all Apache vhost files. If the checksum changes (new site added, site modified, site deleted), it re-runs `nginx-vhost-gen.sh` and restarts nginx. If nothing changed, it exits in under a millisecond with no system impact.

```
* * * * * root /root/bin/nginx-sync.sh
```

### PHP HTTPS Detection (`configs/apache-nginx-proxy.conf`)

Apache sets `$_SERVER['HTTPS'] = 'on'` for all requests coming from the nginx proxy (127.0.0.1). This is applied globally to all PHP sites — present and future — with no per-site configuration:

```apache
SetEnvIf Remote_Addr "^127\.0\.0\.1$" HTTPS=on
SetEnvIf Remote_Addr "^127\.0\.0\.1$" SERVER_PORT=443
```

Without this, WordPress and Joomla would see plain HTTP from Apache's perspective and try to redirect to HTTPS, causing redirect loops.

---

## Configuration Reference

All scripts are configured via environment variables with sensible defaults:

### `nginx-vhost-gen.sh`

| Variable | Default | Description |
|----------|---------|-------------|
| `APACHE_HTTP_PORT` | `9080` | Apache's HTTP port after migration |
| `APACHE_PROXY_TARGET` | `127.0.0.1` | Apache host to proxy to |
| `OUTPUT_DIR` | `/etc/nginx/sites-available` | Where to write nginx configs |
| `VHOST_DIR` | `/etc/apache2/sites-enabled` | Where to read Apache vhosts from |
| `ISPCONFIG_DOMAIN` | *(empty)* | ISPconfig panel hostname (gets special block) |

**Test run without affecting live nginx:**
```bash
OUTPUT_DIR=/tmp/nginx-preview APACHE_HTTP_PORT=9080 ./scripts/nginx-vhost-gen.sh
ls /tmp/nginx-preview/
```

### `nginx-sync.sh`

| Variable | Default | Description |
|----------|---------|-------------|
| `VHOST_DIR` | `/etc/apache2/sites-enabled` | Watched directory |

---

## Known Issues & Gotchas

### Safari "connection unexpectedly closed"

Apache sends an `Upgrade: h2,h2c` header that is forbidden in HTTP/2. Chrome and Firefox ignore it; Safari strictly closes the connection with a PROTOCOL_ERROR. The provided `nginx.conf` includes `proxy_hide_header Upgrade` which fixes this.

### Sites without SSL certificates

Sites where certbot hasn't run yet (e.g. new domains, or domains whose DNS hasn't been switched yet) get HTTP-only nginx configs. Once certbot issues a certificate, ISPconfig updates the Apache vhost, the sync script detects the change and regenerates the nginx config with full HTTPS support automatically.

### ISPconfig `rewrite_to_https` vs HTTP redirects in `.htaccess`

ISPconfig's `rewrite_to_https` setting adds redirect rules to Apache vhosts. These are the ones you disable via MySQL. However, if a site has manually added HTTP→HTTPS redirects in `.htaccess`, those will still fire. The Apache global conf (`HTTPS=on` via `SetEnvIf`) prevents `.htaccess` redirect loops for PHP apps, since they check `$_SERVER['HTTPS']` rather than mod_rewrite's `%{HTTPS}`.

### PROXY Protocol header (`Upgrade: h2,h2c`)

ISPconfig's PROXY Protocol mode adds `RemoteIPProxyProtocol On` to the port 9080 vhosts inside `<IfModule mod_remoteip.c>`. Since `mod_remoteip` is not loaded (and shouldn't be), this directive is silently ignored. Apache accepts plain HTTP from nginx on port 9080 with no issues. Real client IPs are passed via `X-Forwarded-For`.

### ISPconfig panel SSL

The ISPconfig panel on port 8080 uses its own self-signed or Let's Encrypt cert managed separately. The nginx block for the panel domain only handles HTTP (ACME + redirect to `:8080`). The SSL connection to `:8080` goes directly to Apache, bypassing nginx entirely.

---

## File Overview

```
ispconfig-nginx-reverse-proxy-solution/
├── setup.sh                        # Interactive installer
├── scripts/
│   ├── nginx-vhost-gen.sh          # Generates nginx configs from Apache vhosts
│   └── nginx-sync.sh               # Cron script — detects changes, reruns generator
└── configs/
    ├── nginx.conf                   # Drop-in /etc/nginx/nginx.conf replacement
    └── apache-nginx-proxy.conf      # Apache conf for PHP HTTPS detection
```

**Installed locations on server:**
- `/root/bin/nginx-vhost-gen.sh`
- `/root/bin/nginx-sync.sh`
- `/etc/nginx/nginx.conf` (replaces default)
- `/etc/apache2/conf-available/nginx-proxy.conf` (enabled via `a2enconf`)
- `/etc/cron.d/nginx-sync`
- `/etc/letsencrypt/renewal-hooks/post/reload-nginx.sh`

---

## Rollback

If something goes wrong, restoring is straightforward:

```bash
# Restore Apache to ports 80/443
cat > /etc/apache2/ports.conf << 'EOF'
Listen 80
<IfModule ssl_module>
Listen 443
</IfModule>
EOF

# Stop nginx
systemctl stop nginx
systemctl disable nginx

# Restart Apache
systemctl restart apache2
```

The setup script creates backups of `/etc/apache2/` and `/etc/letsencrypt/` before making any changes.

---

## TODO

### RHEL-based systems (AlmaLinux / Rocky Linux)

ISPconfig also supports AlmaLinux 8/9 and Rocky Linux 8/9. These systems use a different Apache layout that would require the following changes to `setup.sh` and `nginx-vhost-gen.sh`:

| Aspect | Debian/Ubuntu (current) | AlmaLinux/Rocky (future) |
|--------|------------------------|--------------------------|
| Package manager | `apt-get` | `dnf` |
| Brotli packages | `libnginx-mod-http-brotli-*` | `nginx-mod-http-brotli` (EPEL) |
| Apache service | `apache2` | `httpd` |
| Apache config test | `apache2ctl configtest` | `apachectl configtest` |
| Apache conf dir | `/etc/apache2/` | `/etc/httpd/` |
| Enable conf | `a2enconf` | drop file in `/etc/httpd/conf.d/` |
| ISPconfig vhost dir | `/etc/apache2/sites-enabled/` | TBD — needs verification on RHEL install |

The core logic (nginx config generation, MD5-based sync, Safari fix, certbot integration) is identical on both platforms and would not need changes.

**Open question:** The exact vhost directory ISPconfig uses on RHEL-based systems needs to be verified on a live installation before implementation.

---

## License

MIT