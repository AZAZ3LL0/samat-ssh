#!/bin/sh
# Installs or upgrades pulse-agent as a systemd service. Run as root.
#
#   install.sh                     latest release from GitHub
#   install.sh --version 1.2.0     a given release
#   install.sh --archive <file>    a local release archive (test VPS deploys from main)
#
# The app's SSH install (S1.3) uploads and runs this script, so it needs only
# POSIX sh, curl, tar and sha256sum.
set -eu

REPO=AZAZ3LL0/samat-ssh
BIN=/usr/local/bin/pulse-agent
CONFIG=/etc/pulse-agent/config.yaml
UNIT=/etc/systemd/system/pulse-agent.service

die() {
	echo "install.sh: $*" >&2
	exit 1
}

version=
archive=
while [ $# -gt 0 ]; do
	case $1 in
	--version) [ $# -ge 2 ] || die "--version needs a value"; version=${2#v}; shift 2 ;;
	--archive) [ $# -ge 2 ] || die "--archive needs a value"; archive=$2; shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$(uname -s)" = Linux ] || die "pulse-agent runs on Linux only"
[ -d /run/systemd/system ] || die "systemd is not running"
# The agent starts on cgroup v1 too, but without per-project metrics (tech.md 3).
[ -f /sys/fs/cgroup/cgroup.controllers ] ||
	echo "install.sh: warning: cgroup v2 is not mounted, per-project metrics will be unavailable" >&2

case $(uname -m) in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "unsupported architecture $(uname -m)" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -z "$archive" ]; then
	command -v curl >/dev/null || die "curl is required"
	if [ -z "$version" ]; then
		# Only the agent publishes GitHub releases, so the latest one is the agent's.
		tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
			sed -n 's/.*"tag_name": *"\(agent\/v[^"]*\)".*/\1/p')
		[ -n "$tag" ] || die "cannot find the latest agent release"
		version=${tag#agent/v}
	fi
	name="pulse-agent_${version}_linux_${arch}.tar.gz"
	base="https://github.com/$REPO/releases/download/agent/v$version"
	echo "Downloading pulse-agent $version ($arch)"
	curl -fsSL -o "$work/$name" "$base/$name" || die "download $base/$name failed"
	curl -fsSL -o "$work/checksums.txt" "$base/checksums.txt" || die "download checksums failed"
	(cd "$work" && grep " $name\$" checksums.txt | sha256sum -c -) >/dev/null || die "checksum mismatch for $name"
	archive=$work/$name
else
	version=$(basename "$archive" | sed -n 's/^pulse-agent_\(.*\)_linux_[a-z0-9]*\.tar\.gz$/\1/p')
fi

mkdir "$work/pkg"
tar -xzf "$archive" -C "$work/pkg" || die "cannot unpack $archive"
for f in pulse-agent pulse-agent.service config.example.yaml; do
	[ -f "$work/pkg/$f" ] || die "$archive has no $f"
done

# Rename over the old binary: writing into a running executable fails with ETXTBSY.
install -m 0755 "$work/pkg/pulse-agent" "$BIN.new"
mv -f "$BIN.new" "$BIN"
install -m 0644 "$work/pkg/pulse-agent.service" "$UNIT"
# An upgrade keeps the operator's config.
if [ ! -f "$CONFIG" ]; then
	install -d -m 0755 "$(dirname "$CONFIG")"
	install -m 0644 "$work/pkg/config.example.yaml" "$CONFIG"
fi

systemctl daemon-reload
systemctl enable --quiet pulse-agent
systemctl restart pulse-agent
sleep 1
if ! systemctl is-active --quiet pulse-agent; then
	journalctl -u pulse-agent -n 20 --no-pager >&2 || true
	die "pulse-agent failed to start"
fi

echo "pulse-agent ${version:-(unknown version)} is running."
echo "Pair a device: sudo pulse-agent pair"
