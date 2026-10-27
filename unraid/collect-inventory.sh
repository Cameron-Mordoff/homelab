#!/bin/bash
# =============================================================================
# collect-inventory.sh - read-only snapshot of an unRAID server's configuration
#
# Dumps system, storage, share, network, docker, remote-access and plugin
# config as plain text, so the setup can be reviewed and documented. It changes
# nothing.
#
# REDACTION
# ---------
# Container env vars print NAMES only, except SAFE_ENV (PUID/PGID/UMASK/TZ).
# WireGuard configs print interface/peer metadata, never keys. The go file is
# passed through a key/password mask. Unraid Connect config prints only the
# remote-access settings, not the API key.
#
# What it does NOT redact: LAN IPs, MACs, hostnames, share and file paths, a
# WireGuard Endpoint (your DDNS name). Fine for review - DON'T COMMIT IT.
# inventory-*.txt is gitignored.
#
# Usage (SSH, or User Scripts > Run Script):
#   bash collect-inventory.sh > /boot/inventory-$(date +%F).txt
# The flash share (\\tower\flash) then gets it onto a PC.
# =============================================================================

SAFE_ENV='["PUID","PGID","UMASK","UMASK_SET","TZ"]'

section() { printf '\n\n########## %s ##########\n' "$*"; }
run()     { printf '\n$ %s\n' "$1"; bash -c "$1" 2>&1; }
# Masks "<something>pass/key/token/secret<something>=value" style assignments.
mask()    { sed -E 's/([A-Za-z_]*(pass(word)?|key|token|secret)[A-Za-z_]*[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1<redacted>/Ig'; }
export -f mask   # run() executes in a child bash, which can't see functions otherwise

echo "collect-inventory $(date '+%F %T')"

# -----------------------------------------------------------------------------
section SYSTEM
run 'cat /etc/unraid-version; hostname; uname -r; uptime'
run 'nproc; free -h'
run "mdcmd status 2>/dev/null | grep -E '^(mdState|mdNumDisks|mdNumInvalid|mdResync|sbSynced|sbSyncErrs)='"

# -----------------------------------------------------------------------------
section STORAGE
run "df -hT | grep -E '/mnt/|Filesystem'"
run 'for f in /boot/config/pools/*.cfg; do [ -e "$f" ] && { echo "--- $f"; grep -v "^#" "$f"; }; done'
# Depth 3 shows data/media/movies style layout; appdata is cut at one level.
# Walking /mnt/user can spin up disks unless the cache_dirs plugin is in use.
run "find /mnt/user -mindepth 1 -maxdepth 3 -type d -not -path '/mnt/user/appdata/*/*' 2>/dev/null | sort | head -400"

# -----------------------------------------------------------------------------
section SHARES
run 'for f in /boot/config/shares/*.cfg; do echo "--- $(basename "$f" .cfg)"; grep -E "^share(UseCache|CachePool|CachePool2|Allocator|SplitLevel|Floor|Include|Exclude|Export|Security|ExportNFS|SecurityNFS|Cow)=" "$f"; done'
run "grep -E '^(NAME|WORKGROUP|LOCAL_TLD|USE_SSL|PORT|PORTSSL|USE_SSH|PORTSSH|USE_TELNET|USE_UPNP|USE_NETBIOS|USE_WSD|START_PAGE)=' /boot/config/ident.cfg"
run 'cat /boot/config/smb-extra.conf 2>/dev/null | mask'

# -----------------------------------------------------------------------------
section NETWORK
run "grep -v '^#' /boot/config/network.cfg"
run 'ip -br link; echo; ip -br addr'
run 'ip route; echo; ip -6 route 2>/dev/null | head -20'
run 'cat /etc/resolv.conf'
run 'ss -tulpn'

# -----------------------------------------------------------------------------
section DOCKER
run "grep -v '^#' /boot/config/docker.cfg"
run "docker version --format 'engine {{.Server.Version}}'; docker system df"
run 'docker network ls'
run "docker network inspect \$(docker network ls -q) | jq -r '.[] | select(.Name | IN(\"bridge\",\"host\",\"none\") | not) |
  \"--- \(.Name)  driver=\(.Driver)  parent=\(.Options.parent // \"-\")\",
  (.IPAM.Config[]? | \"    subnet=\(.Subnet // \"-\")  gateway=\(.Gateway // \"-\")  range=\(.IPRange // \"-\")\"),
  (.Containers // {} | to_entries[] | \"    \(.value.Name)  \(.value.IPv4Address)\")'"
run "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"

ids=$(docker ps -aq 2>/dev/null)
if [ -n "$ids" ]; then
    printf '\n$ docker inspect (redacted)\n'
    # shellcheck disable=SC2086
    docker inspect $ids | jq -r --argjson safe "$SAFE_ENV" '.[] |
      "\n--- \(.Name | ltrimstr("/"))",
      "image:    \(.Config.Image)",
      "state:    \(.State.Status)  restart=\(.HostConfig.RestartPolicy.Name)  autostart-label=\(.Config.Labels["net.unraid.docker.managed"] // "-")",
      "network:  mode=\(.HostConfig.NetworkMode)  " + ([.NetworkSettings.Networks // {} | to_entries[] | "\(.key)=\(.value.IPAddress)"] | join(" ")),
      "ports:    " + ([.HostConfig.PortBindings // {} | to_entries[] | "\(.value[0].HostIp // "")\(.value[0].HostPort // "?")->\(.key)"] | join(" ")),
      "access:   privileged=\(.HostConfig.Privileged)  caps=\((.HostConfig.CapAdd // []) | join(","))  devices=\((.HostConfig.Devices // []) | map(.PathOnHost) | join(","))",
      "user:     \(.Config.User // "" | if . == "" then "(image default)" else . end)",
      "env:      " + ([.Config.Env[]? | (split("=")[0]) as $k
                       | select($k | IN("PATH","HOME","TERM","LANG","LANGUAGE","LC_ALL") or startswith("S6_") | not)
                       | if ($k | IN($safe[])) then . else $k end] | join(" ")),
      "webui:    \(.Config.Labels["net.unraid.docker.webui"] // "-")",
      "mounts:",
      (.Mounts[]? | "    \(.Source) -> \(.Destination)  (\(if .RW then "rw" else "ro" end))")'
fi

run 'ls /boot/config/plugins/dockerMan/templates-user/ 2>/dev/null'
run "echo \"dangling images: \$(docker images -qf dangling=true | wc -l)\"; echo \"unused volumes: \$(docker volume ls -qf dangling=true | wc -l)\""

# -----------------------------------------------------------------------------
section REMOTE ACCESS
run 'wg show interfaces 2>/dev/null || echo "wg: none"'
run "for f in /boot/config/wireguard/*.conf; do [ -e \"\$f\" ] && { echo \"--- \$f\"; grep -E '^\[|^#|^(Address|ListenPort|AllowedIPs|Endpoint|DNS)[[:space:]]*=' \"\$f\"; }; done"
run 'command -v tailscale >/dev/null && tailscale status || echo "tailscale: not installed"'
run "grep -iE '^(wanaccess|wanport|upnpEnabled|dynamicRemoteAccessType)=' /boot/config/plugins/dynamix.my.servers/myservers.cfg 2>/dev/null || echo 'Unraid Connect: not configured'"

# -----------------------------------------------------------------------------
section PLUGINS AND AUTOMATION
run 'ls /boot/config/plugins/*.plg | xargs -n1 basename'
run 'ls /boot/config/plugins/user.scripts/scripts/ 2>/dev/null'
run "jq -r 'to_entries[] | \"\(.value.frequency)\t\(.value.custom // \"\")\t\(.key)\"' /boot/config/plugins/user.scripts/schedule.json 2>/dev/null"
run 'crontab -l 2>/dev/null; ls /etc/cron.d/'
run 'cat /boot/config/go | mask'

echo
echo "End of inventory. Review before sharing; do not commit."
