#!/usr/bin/env bash
# Rebuild Droidian's hardware-layer packages for Debian 13 (trixie), the base
# of Hearth OS. Droidian builds them against a newer glibc (2.43), so its
# binaries won't install on Hearth (2.41). Runs inside debian:trixie on arm64.
#
#   build-trixie-debs.sh <out dir> <source package>...
#
# For each source package: take the source from Droidian's archive (deb-src)
# or, failing that, from github.com/droidian/<name>; install its build deps
# (Droidian's archive is added at low priority so only what trixie lacks comes
# from it); build; put the .debs in <out>. A failed package is reported and
# the rest still build.
set -uo pipefail
OUT=$(realpath -m "$1"); shift
mkdir -p "$OUT" /src
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends build-essential devscripts equivs git ca-certificates \
	dpkg-dev fakeroot gnupg curl quilt >/dev/null

# Droidian's archive: sources, plus binaries pinned low (build deps only).
# The key comes from Droidian's own rootfs (the workflow copies it to $KEY).
cp "${KEY:?set KEY to droidian.gpg}" /etc/apt/trusted.gpg.d/droidian.gpg
cat > /etc/apt/sources.list.d/droidian.sources <<'EOF'
Types: deb deb-src
URIs: http://releases.droidian.org/snapshots/current/
Suites: rolling
Components: main
Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg
EOF
printf 'Package: *\nPin: origin releases.droidian.org\nPin-Priority: 100\n' > /etc/apt/preferences.d/droidian-low
# Already-built trixie debs from earlier packages satisfy later build deps.
mkdir -p /localrepo; touch /localrepo/Packages
echo "deb [trusted=yes] file:/localrepo ./" > /etc/apt/sources.list.d/local.list
apt-get update -q 2>&1 | tail -3

REPORT="$OUT/report.txt"; : > "$REPORT"
for pkg in "$@"; do
	echo "::group::$pkg"
	cd /src && rm -rf "$pkg" && mkdir "$pkg" && cd "$pkg"
	how=""
	if apt-get source -q --only-source "$pkg" >/dev/null 2>&1; then how="droidian deb-src"
	elif git clone -q --depth 1 "https://github.com/droidian/$pkg" "$pkg-git" 2>/dev/null; then how="github droidian/$pkg"
	fi
	dir=$(find . -mindepth 1 -maxdepth 1 -type d | head -1)
	if [ -z "$how" ] || [ ! -d "$dir/debian" ]; then
		echo "$pkg: FAIL no source found" | tee -a "$REPORT"; echo "::endgroup::"; continue
	fi
	cd "$dir"
	# Droidian's git trees sometimes keep the version in a template.
	[ -f debian/changelog ] || { echo "$pkg: FAIL no debian/changelog ($how)" | tee -a "$REPORT"; echo "::endgroup::"; continue; }
	if ! mk-build-deps -i -r -t 'apt-get -y -q --no-install-recommends' debian/control > ../builddeps.log 2>&1; then
		echo "$pkg: FAIL build deps ($how): $(grep -E 'Depends|E:' ../builddeps.log | head -5 | tr '\n' ' ')" | tee -a "$REPORT"
		echo "::endgroup::"; continue
	fi
	if dpkg-buildpackage -b -uc -us -j"$(nproc)" > ../build.log 2>&1; then
		cp ../*.deb "$OUT/" 2>/dev/null
		cp ../*.deb /localrepo/ 2>/dev/null
		(cd /localrepo && dpkg-scanpackages . > Packages 2>/dev/null); apt-get update -q >/dev/null 2>&1
		echo "$pkg: OK ($how) $(cd .. && ls *.deb | tr '\n' ' ')" | tee -a "$REPORT"
	else
		echo "$pkg: FAIL build ($how): $(tail -15 ../build.log | tr '\n' ' ' | cut -c1-600)" | tee -a "$REPORT"
	fi
	echo "::endgroup::"
done
echo "== glibc these were built against: $(dpkg-query -W -f '${Version}' libc6)" | tee -a "$REPORT"
cat "$REPORT"
