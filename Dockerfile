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

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8096

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
