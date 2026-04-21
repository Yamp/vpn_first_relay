FROM golang:1.24-bookworm AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        make \
        gcc \
        libc6-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY awg-versions.env /src/awg-versions.env

RUN . /src/awg-versions.env \
    && git clone https://github.com/amnezia-vpn/amneziawg-go.git \
    && cd amneziawg-go \
    && git checkout "${AMNEZIAWG_GO_COMMIT}"
RUN . /src/awg-versions.env \
    && git clone https://github.com/amnezia-vpn/amneziawg-tools.git \
    && cd amneziawg-tools \
    && git checkout "${AMNEZIAWG_TOOLS_COMMIT}"

RUN make -C /src/amneziawg-go
RUN make -C /src/amneziawg-tools/src WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no

FROM debian:bookworm

ARG SING_BOX_VERSION=1.13.8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        iproute2 \
        nftables \
        python3 \
        procps \
        xz-utils \
    && curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "${SING_BOX_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/amneziawg-go/amneziawg-go /usr/local/bin/amneziawg-go
COPY --from=builder /src/amneziawg-tools/src/wg /usr/local/bin/awg
COPY --from=builder /src/amneziawg-tools/src/wg-quick/linux.bash /usr/local/bin/awg-quick

COPY admin /opt/awg-admin
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/render-sing-box-config.py /usr/local/bin/render-sing-box-config.py
COPY scripts/routing-lists.sh /usr/local/bin/routing-lists.sh
COPY config/upstream.conf /defaults/upstream.conf

RUN chmod +x /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg-quick /usr/local/bin/entrypoint.sh /usr/local/bin/render-sing-box-config.py /usr/local/bin/routing-lists.sh

VOLUME ["/config"]
EXPOSE 51820/udp
EXPOSE 8080/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
