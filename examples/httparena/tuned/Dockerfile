FROM alpine:3.20 AS build
ARG TARGETARCH
ARG ZIG_VERSION=0.17.0
RUN apk add --no-cache ca-certificates curl git tar xz

WORKDIR /server
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt; \
    mv "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

COPY build.zig build.zig.zon ./
COPY src ./src

RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU="x86_64_v3+aes+pclmul+adx" ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU=baseline ;; \
    esac; \
    zig build \
        -Dtarget="${ZIG_TARGET}" \
        -Dcpu="${ZIG_CPU}" \
        --release=fast --summary failures

FROM alpine:3.20
COPY --from=build /server/zig-out/bin/dusty-arena /dusty-arena
EXPOSE 8080 8081
ENTRYPOINT ["/dusty-arena"]
