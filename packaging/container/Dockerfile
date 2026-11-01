# syntax=docker/dockerfile:1
#
# fs-meta daemon in a container, as an unprivileged numeric user.
#
# Build from the repository root, after producing a Linux binary:
#   docker build -f packaging/container/Dockerfile -t fs-meta:local .
#
# The default source is zig-out/bin/fsmeta. A Windows build (fsmeta.exe) is not
# usable here; cross-compile or build on Linux first. Override with
# --build-arg FSMETA_BINARY=<path> if the binary lives elsewhere in the context.
#
# This image never runs as root and needs no Linux capabilities. It listens only
# on AF_UNIX sockets, so the compose example disables networking entirely.

FROM debian:bookworm-slim

ARG UID=10001
ARG GID=10001
ARG FSMETA_BINARY=zig-out/bin/fsmeta

RUN groupadd --system --gid "${GID}" fsmeta \
 && useradd --system --uid "${UID}" --gid fsmeta \
        --home-dir /var/lib/fsmeta --no-create-home --shell /usr/sbin/nologin fsmeta \
 && install -d -o fsmeta -g fsmeta -m 0700 /var/lib/fsmeta /run/fsmeta \
 && install -d -o fsmeta -g fsmeta -m 0750 /srv/fsmeta

COPY ${FSMETA_BINARY} /usr/local/bin/fsmeta
RUN chmod 0755 /usr/local/bin/fsmeta

# Numeric USER: no passwd lookup is needed at runtime, and the image never
# carries a root process. FSMETA_CONFIG_HOME is a prefix, so roots.json is
# /var/lib/fsmeta/roots.json; FSMETA_RUNTIME_DIR is used as-is.
USER ${UID}:${GID}
ENV FSMETA_RUNTIME_DIR=/run/fsmeta \
    FSMETA_CONFIG_HOME=/var/lib

ENTRYPOINT ["/usr/local/bin/fsmeta"]
CMD ["daemon", "start", "--foreground"]
