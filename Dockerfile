# syntax=docker/dockerfile:1
#
# openwrt-tailscale-min: cross-compiles a minimal tailscaled + tailscale CLI
# and packs them into an OpenWrt apk. Defaults target mipsel_24kc (ramips).
# See README.md for usage.

ARG GO_VERSION=1.26.6

FROM golang:${GO_VERSION}-alpine AS build

RUN apk add --no-cache git gzip

ARG TS_VERSION=v1.102.5
ARG TS_FEATURES=osrouter,ipnbus,advertiseexitnode
# Tags for the CLI. Empty = full-featured CLI, same as the reference repo.
ARG CLI_TAGS=
ARG GOARCH=mipsle
ARG GOMIPS=softfloat

WORKDIR /src
RUN git clone --depth 1 --branch "${TS_VERSION}" https://github.com/tailscale/tailscale.git .

COPY patches/ /patches/
RUN for p in /patches/*.patch; do git apply -v "$p"; done

# Use exactly the Go version from the image; don't let go.mod trigger a download.
ENV GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=${GOARCH} GOMIPS=${GOMIPS}

RUN go mod download

RUN mkdir /out && \
    GOOS= GOARCH= go run ./cmd/featuretags --min --add="${TS_FEATURES}" > /out/daemon-tags.txt && \
    TAGS="$(cat /out/daemon-tags.txt)" ./build_dist.sh --strip -o /out/tailscaled-min ./cmd/tailscaled && \
    TAGS="${CLI_TAGS}" ./build_dist.sh --strip -o /out/tailscale-cli ./cmd/tailscale && \
    gzip -9 -k -n /out/tailscaled-min /out/tailscale-cli && \
    cd /out && sha256sum tailscaled-min tailscaled-min.gz tailscale-cli tailscale-cli.gz > SHA256SUMS && \
    ls -l /out

FROM alpine:3.24 AS package

RUN apk add --no-cache findutils

ARG TS_VERSION=v1.102.5
ARG PKG_RELEASE=1
ARG PKG_ARCH=mipsel_24kc
# Default URL the `tailscale` wrapper downloads the uncompressed CLI from:
# the GitHub release matching TS_VERSION. Forks should point GITHUB_REPO at
# their own repo. Can be changed on the router via
# `uci set tailscale.settings.cli_url=...`.
ARG GITHUB_REPO=s8n/openwrt-tailscale-min
ARG CLI_URL=https://github.com/${GITHUB_REPO}/releases/download/${TS_VERSION}/tailscale-cli

COPY --from=build /out/ /out/
COPY package/ /package/
RUN --mount=type=secret,id=apk_key,required=false \
    TS_VERSION="${TS_VERSION}" PKG_RELEASE="${PKG_RELEASE}" PKG_ARCH="${PKG_ARCH}" \
    CLI_URL="${CLI_URL}" APK_KEY=/run/secrets/apk_key \
    /package/pack.sh /out /package/files /out && \
    cd /out && sha256sum tailscale-min-*.apk tailscaled-min tailscaled-min.gz \
        tailscale-cli tailscale-cli.gz > SHA256SUMS

FROM scratch
COPY --from=package /out/ /
