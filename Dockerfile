# Jellyfin on Railway.
#
# The upstream image is used unchanged; this adds only the two things Railway
# needs that no Jellyfin environment variable can express — a boot adapter that
# folds config, cache and media onto the single volume and completes the setup
# wizard from variables, and an init that reaps the ffmpeg processes Jellyfin
# spawns for every transcode.
FROM jellyfin/jellyfin:10.11

RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests --yes \
      jq \
      tini \
 && rm -rf /var/lib/apt/lists/*

# The base image exports these already, at /config and /cache. A shell default in
# the entrypoint would therefore never fire, and Jellyfin would keep its library
# on the container layer while the volume sat empty — so the move onto the mount
# has to happen here. Each stays overridable from a Railway variable.
ENV JELLYFIN_DATA_DIR=/data/config \
    JELLYFIN_CACHE_DIR=/data/cache \
    JELLYFIN_CONFIG_DIR=/data/config/config \
    JELLYFIN_LOG_DIR=/data/config/log \
    XDG_CACHE_HOME=/data/cache \
    JELLYFIN_MEDIA_DIR=/data/media

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
