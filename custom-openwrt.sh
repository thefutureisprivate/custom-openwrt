#!/usr/bin/env bash
set -euo pipefail

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.4}"
OPENWRT_TAG="${OPENWRT_TAG:-v${OPENWRT_VERSION}}"
OPENWRT_REPO="${OPENWRT_REPO:-https://git.openwrt.org/openwrt/openwrt.git}"
MODE="${1:-help}"

CONTAINER_BASE="${CONTAINER_BASE:-registry.fedoraproject.org/fedora:44}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-custom-openwrt-fedora:latest}"

DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-4}"
BUILD_JOBS="${BUILD_JOBS:-16}"
BUILD_CACHE="${BUILD_CACHE:-1}"
MENUCONFIG="${MENUCONFIG:-0}"
UPDATE_CONFIG="${UPDATE_CONFIG:-0}"
GIT_USER_NAME="${GIT_USER_NAME:-custom-openwrt}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-custom-openwrt@example.invalid}"

case "${MODE}" in
	prepare|env|setup)
		;;
	build)
		;;
	menuconfig|config)
		MENUCONFIG=1
		UPDATE_CONFIG=1
		;;
	help|-h|--help)
		cat <<'EOF'
Usage:
  ./custom-openwrt.sh              show this help
  ./custom-openwrt.sh prepare      refresh caches and verify the disposable env
  ./custom-openwrt.sh build        build firmware with the mounted .config
  ./custom-openwrt.sh menuconfig   open make menuconfig and write changes back to .config

Options:
  BUILD_ROOT=build        repo-local output directory
  DL_CACHE=build/cache/dl repo-local OpenWrt download cache
  SOURCE_CACHE=build/cache/openwrt
                          repo-local OpenWrt source/build cache
  FEEDS_CACHE=build/cache/feeds
                          repo-local bare OpenWrt feeds cache
  BUILD_CACHE=1           keep compiled OpenWrt build state
  BUILD_CACHE=0           bypass compiled build cache for this run
  MENUCONFIG=1            open make menuconfig before building
  UPDATE_CONFIG=1         copy the final OpenWrt .config back to this repo
  DOWNLOAD_JOBS=4         jobs for make download
  BUILD_JOBS=16           jobs for make
  GIT_USER_NAME=...       git identity used for applying patches
  GIT_USER_EMAIL=...      git identity used for applying patches
EOF
		exit 0
		;;
	*)
		echo "Unknown mode: ${MODE}" >&2
		echo "Use ./custom-openwrt.sh help" >&2
		exit 2
		;;
esac

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"
DL_CACHE="${DL_CACHE:-${BUILD_ROOT}/cache/dl}"
SOURCE_CACHE="${SOURCE_CACHE:-${BUILD_ROOT}/cache/openwrt}"
FEEDS_CACHE="${FEEDS_CACHE:-${BUILD_ROOT}/cache/feeds}"
CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/.config}"
CONTAINER_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/custom-openwrt-container.XXXXXX")"
trap 'rm -rf "${CONTAINER_CONTEXT}"' EXIT

mkdir -p "${BUILD_ROOT}" "${DL_CACHE}" "${SOURCE_CACHE}" "${FEEDS_CACHE}"

if [ ! -f "${CONFIG_FILE}" ]; then
	echo "Config file not found: ${CONFIG_FILE}" >&2
	exit 1
fi

if [ "${MENUCONFIG}" = "1" ] && [ ! -t 0 ]; then
	echo "make menuconfig requires an interactive terminal." >&2
	exit 1
fi

podman build --pull=missing \
	--build-arg "CONTAINER_BASE=${CONTAINER_BASE}" \
	--tag "${CONTAINER_IMAGE}" \
	-f - "${CONTAINER_CONTEXT}" <<'EOF'
ARG CONTAINER_BASE
FROM ${CONTAINER_BASE}
RUN dnf --setopt=install_weak_deps=False install --skip-broken -y \
	bash bc binutils bison bzip2 ccache diffutils elfutils-libelf-devel \
	file findutils flex gawk gcc gcc-c++ gettext git-core grep gzip \
	intltool libusb1-devel libxslt make ncurses-devel openssl-devel patch \
	perl-base perl-Data-Dumper perl-ExtUtils-MakeMaker perl-File-Compare \
	perl-File-Copy perl-FindBin perl-IPC-Cmd perl-JSON-PP perl-lib \
	perl-Thread-Queue perl-Time-Piece perl-XML-Parser python3 \
	python3-setuptools rsync subversion swig tar time unzip wget which \
	xz zlib-devel zstd \
	&& dnf clean all
EOF

tty_args=()
if [ -t 0 ]; then
	tty_args=(-it)
fi

podman run --rm "${tty_args[@]}" \
	--security-opt label=disable \
	--userns keep-id \
	--user "$(id -u):$(id -g)" \
	--workdir /tmp \
	-e HOME=/tmp/custom-openwrt-work/home \
	-e TERM="${TERM:-xterm-256color}" \
	-e OPENWRT_TAG="${OPENWRT_TAG}" \
	-e OPENWRT_REPO="${OPENWRT_REPO}" \
	-e DOWNLOAD_JOBS="${DOWNLOAD_JOBS}" \
	-e BUILD_JOBS="${BUILD_JOBS}" \
	-e BUILD_CACHE="${BUILD_CACHE}" \
	-e GIT_USER_NAME="${GIT_USER_NAME}" \
	-e GIT_USER_EMAIL="${GIT_USER_EMAIL}" \
	-e MENUCONFIG="${MENUCONFIG}" \
	-e UPDATE_CONFIG="${UPDATE_CONFIG}" \
	-e MODE="${MODE}" \
	-e CCACHE_DIR=/tmp/custom-openwrt-work/ccache \
	-e HOST_BUILD_ROOT="${BUILD_ROOT}" \
	-e HOST_DL_CACHE="${DL_CACHE}" \
	-e HOST_SOURCE_CACHE="${SOURCE_CACHE}" \
	-e HOST_FEEDS_CACHE="${FEEDS_CACHE}" \
	-v "${REPO_ROOT}:/repo:ro" \
	-v "${CONFIG_FILE}:/tmp/repo.config:rw" \
	-v "${BUILD_ROOT}:/output:rw" \
	-v "${DL_CACHE}:/cache/dl:rw" \
	-v "${SOURCE_CACHE}:/cache/openwrt:rw" \
	-v "${FEEDS_CACHE}:/cache/feeds:rw" \
	"${CONTAINER_IMAGE}" \
	bash -lc '
set -euo pipefail
work_root=/tmp/custom-openwrt-work
: "${CCACHE_DIR:=${work_root}/ccache}"
export CCACHE_DIR
mkdir -p "${work_root}" "${work_root}/home" "${CCACHE_DIR}" /cache/dl /cache/feeds
export HOME="${work_root}/home"

update_git_mirror() {
	local mirror_dir="$1"
	local repo_url="$2"

	if git -C "${mirror_dir}" rev-parse --is-bare-repository >/dev/null 2>&1; then
		git -C "${mirror_dir}" remote set-url origin "${repo_url}"
		git -C "${mirror_dir}" fetch --prune --tags origin
	else
		find "${mirror_dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
		git clone --mirror "${repo_url}" "${mirror_dir}"
	fi
}

clean_openwrt_tree() {
	local reset_ref="${1:-HEAD}"

	git -C "${openwrt_tree}" am --abort >/dev/null 2>&1 || true
	git -C "${openwrt_tree}" reset --hard "${reset_ref}" >/dev/null 2>&1 || true
	if [ "${BUILD_CACHE}" = "1" ]; then
		git -C "${openwrt_tree}" clean -ffdx \
			-e bin \
			-e build_dir \
			-e feeds \
			-e logs \
			-e package/feeds \
			-e staging_dir \
			-e tmp >/dev/null 2>&1 || true
	else
		git -C "${openwrt_tree}" clean -ffdx -e feeds -e package/feeds >/dev/null 2>&1 || true
	fi
}

openwrt_tree=/cache/openwrt
if [ -d "${openwrt_tree}/.git" ]; then
	clean_openwrt_tree HEAD
	git -C "${openwrt_tree}" remote set-url origin "${OPENWRT_REPO}"
	git -C "${openwrt_tree}" fetch --prune --tags origin
else
	find "${openwrt_tree}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
	git clone "${OPENWRT_REPO}" "${openwrt_tree}"
fi

cd "${openwrt_tree}"
git checkout --detach "${OPENWRT_TAG}"
git reset --hard "${OPENWRT_TAG}"
clean_openwrt_tree "${OPENWRT_TAG}"
git config pull.rebase true
git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

cleanup_openwrt_tree() {
	clean_openwrt_tree "${OPENWRT_TAG}"
}
trap cleanup_openwrt_tree EXIT

python_bin="$(command -v python3)"
mkdir -p staging_dir/host/bin
ln -sf "${python_bin}" staging_dir/host/bin/python
ln -sf "${python_bin}" staging_dir/host/bin/python3

exec 3> feeds.conf
while IFS= read -r line || [ -n "${line}" ]; do
	if [[ "${line}" =~ ^(src-git|src-git-full)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)(.*)$ ]]; then
		feed_type="${BASH_REMATCH[1]}"
		feed_name="${BASH_REMATCH[2]}"
		feed_spec="${BASH_REMATCH[3]}"
		feed_rest="${BASH_REMATCH[4]}"
		feed_rev=""
		feed_source="${feed_spec}"

		if [[ "${feed_source}" == *^* ]]; then
			feed_rev="^${feed_source#*^}"
			feed_source="${feed_source%%^*}"
		fi

		feed_selector=""
		feed_url="${feed_source}"
		if [[ "${feed_url}" == *";"* ]]; then
			feed_selector=";${feed_url#*;}"
			feed_url="${feed_url%%;*}"
		fi

		feed_mirror="/cache/feeds/${feed_name}.git"
		mkdir -p "${feed_mirror}"
		update_git_mirror "${feed_mirror}" "${feed_url}"
		printf "%s %s %s%s%s%s\n" "${feed_type}" "${feed_name}" "${feed_mirror}" "${feed_selector}" "${feed_rev}" "${feed_rest}" >&3
	else
		printf "%s\n" "${line}" >&3
	fi
done < feeds.conf.default
exec 3>&-

./scripts/feeds update -a -f
./scripts/feeds install -a -f

cp /tmp/repo.config .config

shopt -s nullglob
patches=(/repo/patches/*.patch)
if [ "${#patches[@]}" -gt 0 ]; then
	patchset_id="$(sha256sum "${patches[@]}" | sha256sum | awk '\''{print $1}'\'')"
else
	patchset_id="empty"
fi

if [ ! -f .custom-openwrt-patches-applied ] || ! grep -qx "${patchset_id}" .custom-openwrt-patches-applied; then
	if [ -d .git/rebase-apply ]; then
		git am --abort
	fi
	git reset --hard "${OPENWRT_TAG}"
	if [ "${#patches[@]}" -gt 0 ]; then
		git am --whitespace=nowarn "${patches[@]}"
	fi
	printf "%s\n%s\n" "${OPENWRT_TAG}" "${patchset_id}" > .custom-openwrt-patches-applied
else
	echo "Patch set already applied."
fi

make defconfig
if [ "${MENUCONFIG}" = "1" ]; then
	make menuconfig
	make defconfig
fi

if [ "${UPDATE_CONFIG}" = "1" ]; then
	cp .config /tmp/repo.config
	echo "Updated mounted config: /tmp/repo.config"
fi

if [ "${MODE}" = "menuconfig" ] || [ "${MODE}" = "config" ]; then
	exit 0
fi

if [ "${MODE}" = "prepare" ] || [ "${MODE}" = "env" ] || [ "${MODE}" = "setup" ]; then
	make download -j"${DOWNLOAD_JOBS}" DL_DIR=/cache/dl
	echo
	echo "Prepared caches:"
	echo "  OpenWrt tree: ${HOST_SOURCE_CACHE}"
	echo "  feeds git:   ${HOST_FEEDS_CACHE}"
	echo "  downloads:   ${HOST_DL_CACHE}"
	echo "  build cache: ${BUILD_CACHE}"
	echo "Persistent output directory: ${HOST_BUILD_ROOT}"
	exit 0
fi

make download -j"${DOWNLOAD_JOBS}" DL_DIR=/cache/dl
make -j"${BUILD_JOBS}" DL_DIR=/cache/dl

rm -rf /output/images
mkdir -p /output/images
cp -a bin/targets/ipq40xx/generic/. /output/images/

echo
echo "Images:"
echo "${HOST_BUILD_ROOT}/images"
'
