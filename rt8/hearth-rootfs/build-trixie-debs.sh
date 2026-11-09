#!/usr/bin/env bash
# Rebuild Droidian's hardware-layer packages for Debian 13 (trixie), the base
# of Hearth OS. Droidian builds them against a newer glibc (2.43), so its
# binaries won't install on Hearth (2.41). Runs inside debian:trixie on arm64.
#
#   build-trixie-debs.sh <out dir> <source package>=<droidian version>...
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
for arg in "$@"; do
	pkg=${arg%%=*}; ver=${arg#*=}
	echo "::group::$pkg $ver"
	cd /src && rm -rf "$pkg" && mkdir "$pkg" && cd "$pkg"
	how=""
	if apt-get source -q --only-source "$pkg=$ver" >/dev/null 2>&1; then how="droidian deb-src"
	else
		# Droidian versions end in +git<date>.<commit>.<branch>: build that commit.
		sha=$(echo "$ver" | grep -oE 'git[0-9]{14}\.[0-9a-f]{7,}' | head -1 | cut -d. -f2)
		if git clone -q --filter=blob:none "https://github.com/droidian/$pkg" "$pkg-git" 2>/dev/null; then
			if [ -n "$sha" ] && git -C "$pkg-git" checkout -q "$sha" 2>/dev/null; then how="github droidian/$pkg @$sha"
			else how="github droidian/$pkg default branch (commit ${sha:-?} not found)"; fi
		fi
	fi
	dir=$(find . -mindepth 1 -maxdepth 1 -type d | head -1)
	if [ -z "$how" ] || [ ! -d "$dir/debian" ]; then
		echo "$pkg: FAIL no source found" | tee -a "$REPORT"; echo "::endgroup::"; continue
	fi
	cd "$dir"
	# Droidian's build tooling writes debian/changelog at build time.
	if [ ! -f debian/changelog ]; then
		DEBEMAIL="Dragongamer9 <game305.cl@gmail.com>" dch --create --package "$pkg" -v "${ver}~deb13" -D trixie \
			"Rebuilt from Droidian's sources for Debian 13 (Hearth OS)." >/dev/null 2>&1
	fi
	if ! mk-build-deps -i -r -t 'apt-get -y -q --no-install-recommends' debian/control > ../builddeps.log 2>&1; then
		echo "$pkg: FAIL build deps ($how): $(grep -E 'Depends|E:|but' ../builddeps.log | head -8 | tr '\n' ' ' | cut -c1-700)" | tee -a "$REPORT"
		echo "::endgroup::"; continue
	fi
	if dpkg-buildpackage -b -uc -us -j"$(nproc)" > ../build.log 2>&1; then
		cp ../*.deb "$OUT/" 2>/dev/null
		cp ../*.deb /localrepo/ 2>/dev/null
		(cd /localrepo && dpkg-scanpackages . > Packages 2>/dev/null); apt-get update -q >/dev/null 2>&1
		echo "$pkg: OK ($how) $(cd .. && ls *.deb | grep -v dbgsym | tr '\n' ' ')" | tee -a "$REPORT"
	else
		echo "$pkg: FAIL build ($how): $(tail -15 ../build.log | tr '\n' ' ' | cut -c1-700)" | tee -a "$REPORT"
	fi
	echo "::endgroup::"
done
echo "== glibc these were built against: $(dpkg-query -W -f '${Version}' libc6)" | tee -a "$REPORT"
cat "$REPORT"
