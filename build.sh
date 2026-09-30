#!/bin/sh
# Builds the binaries and the OpenWrt package in Docker and drops them into
# ./dist. Any extra args are passed to `docker build`, e.g.:
#   ./build.sh --build-arg CLI_URL=http://192.168.1.2:8000/tailscale-cli
#
# The package is signed with keys/tailscale-min.pem, generated on first run.
# Copy keys/tailscale-min.pub.pem to /etc/apk/keys/ on the router once to
# install without --allow-untrusted.
set -eu
cd "$(dirname "$0")"

if [ ! -f keys/tailscale-min.pem ]; then
	mkdir -p keys
	(umask 077 && openssl ecparam -name prime256v1 -genkey -noout -out keys/tailscale-min.pem)
	openssl ec -in keys/tailscale-min.pem -pubout -out keys/tailscale-min.pub.pem 2>/dev/null
	echo "generated signing key in keys/"
fi

rm -rf dist
docker buildx build \
	--secret id=apk_key,src=keys/tailscale-min.pem \
	--output type=local,dest=dist \
	"$@" .
cp keys/tailscale-min.pub.pem dist/
ls -l dist
