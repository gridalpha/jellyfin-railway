#!/bin/sh
# Boot adapter for Jellyfin on Railway.
#
# Railway gives a service exactly one volume and no way to run a step after the
# container is up, so four things happen here at start:
#
#   1. config, cache and media are folded onto the single mount
#   2. the setup wizard is completed from variables, so a fresh deployment is
#      never claimable by whoever reaches the URL first
#   3. Railway's edge is registered as a trusted proxy, so Jellyfin reads the
#      real client address and scheme out of X-Forwarded-For / -Proto
#   4. ffmpeg's thread count is taken from the container's CPU quota — Jellyfin
#      defaults to `-threads 0` and ffmpeg then sizes itself from the host's
#      core count, which on Railway is several times the container's quota
#
# Steps 2-4 run once, gated on the wizard still being incomplete, so nothing an
# operator changes afterwards is rewritten by a later deploy.

set -eu

: "${JELLYFIN_DATA_DIR:=/data/config}"
: "${JELLYFIN_CACHE_DIR:=/data/cache}"
: "${JELLYFIN_CONFIG_DIR:=${JELLYFIN_DATA_DIR}/config}"
: "${JELLYFIN_LOG_DIR:=${JELLYFIN_DATA_DIR}/log}"
: "${JELLYFIN_MEDIA_DIR:=/data/media}"
: "${JELLYFIN_ADMIN_USERNAME:=admin}"
: "${JELLYFIN_ADMIN_PASSWORD:=}"
: "${JELLYFIN_SERVER_NAME:=Jellyfin}"
: "${JELLYFIN_BOOTSTRAP:=true}"
: "${JELLYFIN_ENCODING_THREADS:=}"
# Railway reaches the container from CGNAT space and appends its own edge
# address to X-Forwarded-For; both hops have to be trusted before ASP.NET will
# walk back to the real client. If Railway ever moves off 152.233.0.0/17 this
# degrades to reporting the edge address, which is the unconfigured behaviour.
: "${JELLYFIN_TRUSTED_PROXIES:=100.64.0.0/10,152.233.0.0/17}"

export JELLYFIN_DATA_DIR JELLYFIN_CACHE_DIR JELLYFIN_CONFIG_DIR JELLYFIN_LOG_DIR
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$JELLYFIN_CACHE_DIR}"

# Jellyfin's listen port lives in network.xml, not in an environment variable,
# so it stays at the upstream default. Railway's PORT has to match it for the
# platform health check to reach the app.
JF_PORT=8096
API="http://127.0.0.1:${JF_PORT}"
AUTH='MediaBrowser Client="railway-bootstrap", Device="railway", DeviceId="railway-bootstrap", Version="1.0.0"'

log() { printf 'railway-bootstrap: %s\n' "$*"; }

mkdir -p \
  "$JELLYFIN_DATA_DIR" "$JELLYFIN_CACHE_DIR" "$JELLYFIN_CONFIG_DIR" "$JELLYFIN_LOG_DIR" \
  "$JELLYFIN_MEDIA_DIR/movies" "$JELLYFIN_MEDIA_DIR/shows" "$JELLYFIN_MEDIA_DIR/music"
log "data=${JELLYFIN_DATA_DIR} cache=${JELLYFIN_CACHE_DIR} media=${JELLYFIN_MEDIA_DIR}"

# Threads for ffmpeg: the container's CPU quota, not the host's core count.
encoding_threads() {
  if [ -n "$JELLYFIN_ENCODING_THREADS" ]; then
    printf '%s' "$JELLYFIN_ENCODING_THREADS"
    return
  fi
  quota=$(cut -d' ' -f1 /sys/fs/cgroup/cpu.max 2>/dev/null || echo max)
  period=$(cut -d' ' -f2 /sys/fs/cgroup/cpu.max 2>/dev/null || echo 100000)
  if [ "$quota" = "max" ] || [ -z "$quota" ] || [ -z "$period" ]; then
    printf '%s' "$(nproc 2>/dev/null || echo 2)"
    return
  fi
  n=$(( quota / period ))
  [ "$n" -lt 1 ] && n=1
  printf '%s' "$n"
}

api_get() { curl -fsS --noproxy '*' -H "Authorization: ${AUTH}${1:+, Token=\"$1\"}" "${API}$2"; }

api_post() {
  # $1 token (may be empty) | $2 path | $3 JSON body
  curl -fsS --noproxy '*' -X POST \
    -H "Authorization: ${AUTH}${1:+, Token=\"$1\"}" \
    -H 'Content-Type: application/json' \
    --data "$3" "${API}$2"
}

add_library() {
  # $1 display name | $2 collection type | $3 folder under the media root
  if api_post '' "/Library/VirtualFolders?name=$1&collectionType=$2&paths=${JELLYFIN_MEDIA_DIR}/$3&refreshLibrary=false" '{}' >/dev/null 2>&1; then
    log "library '$1' -> ${JELLYFIN_MEDIA_DIR}/$3"
  else
    log "library '$1' could not be created; add it from Dashboard -> Libraries"
  fi
}

bootstrap() {
  set +e

  # /health answers 200 with the body "Degraded" while Jellyfin is still starting,
  # and every API route returns 503 until then — so wait for the body, not the
  # status code.
  i=0
  while [ "$i" -lt 150 ]; do
    [ "$(curl -fsS --noproxy '*' "${API}/health" 2>/dev/null)" = "Healthy" ] && break
    i=$((i + 1))
    sleep 2
  done
  if [ "$i" -ge 150 ]; then
    log "server never reported Healthy at ${API}/health; skipping first-run setup"
    return
  fi

  done_already=$(api_get '' /System/Info/Public | jq -r '.StartupWizardCompleted // false')
  if [ "$done_already" = "true" ]; then
    log "setup wizard already completed; leaving configuration alone"
    return
  fi

  if [ -z "$JELLYFIN_ADMIN_PASSWORD" ]; then
    log "JELLYFIN_ADMIN_PASSWORD is empty; leaving the setup wizard for the operator"
    return
  fi

  # GET /Startup/User is what materialises the first user row; the later POST
  # renames it and sets the password.
  api_get '' /Startup/User >/dev/null || log "could not initialise the first user"

  api_post '' /Startup/Configuration "$(jq -n --arg n "$JELLYFIN_SERVER_NAME" \
    '{ServerName:$n,UICulture:"en-US",MetadataCountryCode:"US",PreferredMetadataLanguage:"en"}')" \
    >/dev/null || log "could not set the server name"

  add_library Movies movies movies
  add_library Shows tvshows shows
  add_library Music music music

  if ! api_post '' /Startup/User "$(jq -n --arg n "$JELLYFIN_ADMIN_USERNAME" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
      '{Name:$n,Password:$p}')" >/dev/null; then
    log "could not create the administrator; the setup wizard is still open at /web/#/wizardstart"
    return
  fi
  log "administrator '${JELLYFIN_ADMIN_USERNAME}' created from JELLYFIN_ADMIN_USERNAME/JELLYFIN_ADMIN_PASSWORD"

  # No inbound UDP on Railway, so autodiscovery and UPnP port mapping are dead
  # weight; remote access is the entire point of the deployment.
  api_post '' /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
    >/dev/null || log "could not set remote access"

  api_post '' /Startup/Complete '{}' >/dev/null \
    && log "setup wizard completed" \
    || { log "could not complete the setup wizard"; return; }

  token=$(api_post '' /Users/AuthenticateByName "$(jq -n --arg u "$JELLYFIN_ADMIN_USERNAME" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
    '{Username:$u,Pw:$p}')" | jq -r '.AccessToken // empty')
  if [ -z "$token" ]; then
    log "could not sign in as '${JELLYFIN_ADMIN_USERNAME}'; proxy and encoder settings left at defaults"
    return
  fi

  proxies=$(printf '%s' "$JELLYFIN_TRUSTED_PROXIES" | jq -R 'split(",") | map(select(length > 0))')
  net=$(api_get "$token" /System/Configuration/network)
  if [ -n "$net" ]; then
    printf '%s' "$net" \
      | jq --argjson p "$proxies" '.KnownProxies=$p | .AutoDiscovery=false | .EnableUPnP=false | .EnableRemoteAccess=true' \
      > /tmp/network.json
    api_post "$token" /System/Configuration/network "$(cat /tmp/network.json)" >/dev/null \
      && log "trusted proxies set to ${JELLYFIN_TRUSTED_PROXIES}; autodiscovery and UPnP off" \
      || log "could not write the network configuration"
    rm -f /tmp/network.json
  fi

  threads=$(encoding_threads)
  enc=$(api_get "$token" /System/Configuration/encoding)
  if [ -n "$enc" ]; then
    printf '%s' "$enc" | jq --argjson t "$threads" '.EncodingThreadCount=$t' > /tmp/encoding.json
    api_post "$token" /System/Configuration/encoding "$(cat /tmp/encoding.json)" >/dev/null \
      && log "ffmpeg thread count capped at ${threads} (container CPU quota)" \
      || log "could not write the encoding configuration"
    rm -f /tmp/encoding.json
  fi

  log "first-run setup finished"
}

if [ "$JELLYFIN_BOOTSTRAP" = "true" ]; then
  # Started detached so it is reparented to the init and reaped there rather
  # than left as a zombie under the server process.
  ( bootstrap & )
fi

exec /jellyfin/jellyfin
