#!/bin/sh
# Assembles and packs tailscale-min into an OpenWrt apk (v3) package, laid
# out the way OpenWrt's include/package-pack.mk does it.
#
# Usage: pack.sh <build-output-dir> <files-dir> <dest-dir>
# Env: TS_VERSION, PKG_RELEASE, PKG_ARCH, CLI_URL, APK_KEY (optional)
set -eu

out=$1 files=$2 dest=$3
name=tailscale-min
version="${TS_VERSION#v}-r${PKG_RELEASE}"
root=$(mktemp -d)
chmod 755 "$root"
scripts=$(mktemp -d)

install -Dm644 "$out/tailscaled-min.gz" "$root/usr/lib/tailscale/tailscaled.gz"
install -Dm755 "$files/tailscale.init" "$root/etc/init.d/tailscale"
install -Dm644 "$files/tailscale.conf" "$root/etc/config/tailscale"
install -Dm755 "$files/tailscale" "$root/usr/sbin/tailscale"
install -Dm755 "$files/tailscale.uci-defaults" "$root/etc/uci-defaults/90-tailscale-firewall"
sed -i \
	-e "s|@TS_VERSION@|${TS_VERSION#v}|" \
	-e "s|@CLI_URL@|${CLI_URL}|" \
	-e "s|@CLI_SHA256@|$(sha256sum "$out/tailscale-cli" | cut -d' ' -f1)|" \
	-e "s|@CLI_SIZE@|$(stat -c %s "$out/tailscale-cli")|" \
	"$root/usr/sbin/tailscale"

meta="$root/lib/apk/packages"
mkdir -p "$meta"
(cd "$root" && find . -type f,l -printf '/%P\n' | sort) > "$scripts/list"
mv "$scripts/list" "$meta/$name.list"
printf '%s\n' /etc/config/tailscale /etc/tailscale/ > "$meta/$name.conffiles"
echo "/etc/config/tailscale $(sha256sum "$root/etc/config/tailscale" | cut -d' ' -f1)" \
	> "$meta/$name.conffiles_static"

# Same scripts OpenWrt generates: default_postinst enables and starts the
# init scripts listed in the .list file, default_prerm stops/disables them.
cat > "$scripts/post-install" <<EOS
#!/bin/sh
[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s "\${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. \${IPKG_INSTROOT}/lib/functions.sh
export root="\${IPKG_INSTROOT}"
export pkgname="$name"
add_group_and_user
default_postinst
EOS
# default_postinst only calls `start` on upgrade, which leaves the old daemon
# running; restart it so the new binary is used.
cat > "$scripts/post-upgrade" <<EOS
#!/bin/sh
export PKG_UPGRADE=1
$(sed '1d' "$scripts/post-install")
[ -z "\${IPKG_INSTROOT}" ] && /etc/init.d/tailscale enabled && /etc/init.d/tailscale restart
exit 0
EOS
cat > "$scripts/pre-deinstall" <<EOS
#!/bin/sh
[ -s "\${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. \${IPKG_INSTROOT}/lib/functions.sh
export root="\${IPKG_INSTROOT}"
export pkgname="$name"
default_prerm
[ -z "\${IPKG_INSTROOT}" ] || exit 0
rm -f /tmp/tailscale-cli /tmp/tailscale-cli.sha256 /tmp/tailscaled
# Remove the firewall zone and forwardings added by the uci-defaults script.
if uci -q get firewall.tailscale >/dev/null; then
	for s in tailscale tailscale_wan tailscale_lan lan_tailscale; do
		uci -q delete firewall.\$s
	done
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
fi
exit 0
EOS

mkdir -p "$dest"
pkg="$dest/$name-$version.apk"
apk mkpkg \
	--info "name:$name" \
	--info "version:$version" \
	--info "description:Minimal tailscaled (osrouter, ipnbus, advertiseexitnode) stored gzipped and unpacked to RAM at start, plus a tailscale CLI wrapper that downloads the CLI to /tmp on demand" \
	--info "arch:$PKG_ARCH" \
	--info "license:BSD-3-Clause" \
	--info "origin:$name" \
	--info "url:https://tailscale.com" \
	--info "depends:ca-bundle kmod-tun !tailscale" \
	--script "post-install:$scripts/post-install" \
	--script "post-upgrade:$scripts/post-upgrade" \
	--script "pre-deinstall:$scripts/pre-deinstall" \
	--files "$root" \
	--output "$pkg"

if [ -n "${APK_KEY:-}" ] && [ -s "$APK_KEY" ]; then
	apk adbsign --allow-untrusted --sign-key "$APK_KEY" "$pkg"
	echo "signed $pkg"
else
	echo "no signing key given; $pkg is unsigned (install with --allow-untrusted)"
fi

rm -rf "$root" "$scripts"
