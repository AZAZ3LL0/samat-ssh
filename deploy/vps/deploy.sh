#!/bin/sh
# Installs the archive from `make agent-dist` on the test VPS and waits until the
# new build answers from outside. CI runs it on every push to main.
#
#   deploy/vps/deploy.sh <agent-url>
#
# Reaches the VPS through the `vps` host that ssh-setup.sh configures.
set -eu

url=${1:?usage: deploy.sh <agent-url>}

die() {
	echo "deploy.sh: $*" >&2
	exit 1
}

case $(ssh vps uname -m) in
x86_64) arch=amd64 ;;
aarch64) arch=arm64 ;;
*) die "unsupported VPS architecture" ;;
esac

set -- dist/pulse-agent_*_linux_"$arch".tar.gz
[ $# -eq 1 ] && [ -f "$1" ] || die "expected one $arch archive in dist/: run make agent-dist"
archive=$1
name=$(basename "$archive")
version=${name#pulse-agent_}
version=${version%_linux_*}

remote=$(ssh vps mktemp -d /tmp/pulse-deploy.XXXXXX)
case $remote in /tmp/pulse-deploy.*) ;; *) die "unexpected remote temp dir '$remote'" ;; esac
scp -q "$archive" deploy/install.sh "vps:$remote/"
# Expands locally on purpose: both values are checked above.
# shellcheck disable=SC2029
ssh vps "sudo sh $remote/install.sh --archive $remote/$name; status=\$?; rm -r -- $remote; exit \$status"

# Checks the port is reachable from outside; check.sh verifies the pin.
got=
for _ in $(seq 30); do
	got=$(curl -fsSk --max-time 5 "$url/v1/info" | jq -r .agentVersion) || true
	if [ "$got" = "$version" ]; then
		echo "pulse-agent $version is live at $url"
		exit 0
	fi
	sleep 2
done
die "$url reports agentVersion '$got', want $version"
