# Runtime image: docker run --rm -v "$PWD":/data <image> optimize /data/Photos /data/Photos_opt
FROM debian:trixie-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        imagemagick \
        libheif-plugin-libde265 \
        python3 \
        rsync \
    && rm -rf /var/lib/apt/lists/*

COPY bin/ /opt/mot/bin/
COPY lib/ /opt/mot/lib/
RUN ln -s /opt/mot/bin/mot /usr/local/bin/mot

WORKDIR /data
ENTRYPOINT ["mot"]
CMD ["--help"]

# Test image: the runtime image plus bats-core from its official image and a HEIC encoder for fixtures.
FROM bats/bats:1.12.0 AS bats

FROM runtime AS test

RUN apt-get update \
    && apt-get install -y --no-install-recommends libheif-plugin-x265 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=bats /opt/bats /opt/bats
RUN ln -s /opt/bats/bin/bats /usr/local/bin/bats

COPY run.sh /opt/mot/
COPY tests/ /opt/mot/tests/
WORKDIR /opt/mot
ENTRYPOINT ["bats"]
CMD ["tests"]
