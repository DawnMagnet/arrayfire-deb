#!/usr/bin/env bash
set -euo pipefail

# make_deb.sh
# Usage: ./make_deb.sh <type> [version] [arch]
# type: cpu | cuda | opencl | oneapi | full
# Builds a .deb package containing the ArrayFire runtime for the selected backend.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Use an absolute, normalized repository root (script dir's parent)
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

# parse args and compute paths
TYPE="${1:-}" || true
if [[ -z "${TYPE}" ]]; then
  echo "Usage: $0 <cpu|cuda|opencl|oneapi|full> [version] [arch]"
  exit 2
fi

VERSION_ARG="${2:-}"
ARCH="${3:-amd64}"

# Get version from etc/arrayfire_version.txt if not passed
if [[ -z "${VERSION_ARG}" ]]; then
  if [[ -r "${ROOT_DIR}/etc/arrayfire_version.txt" ]]; then
    VERSION_ARG=$(tr -d ' \n\r' < "${ROOT_DIR}/etc/arrayfire_version.txt")
  else
    VERSION_ARG="3.10.0"
  fi
fi

PACKAGE_NAME="arrayfire-${TYPE}"
PKG_DIR="${SCRIPT_DIR}/debbuild/${PACKAGE_NAME}_${VERSION_ARG}_${ARCH}"

echo "Building package: ${PACKAGE_NAME} version ${VERSION_ARG} arch ${ARCH}"

rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}/DEBIAN"

# Where to place files in package
USR_LIB_DIR="${PKG_DIR}/usr/lib/x86_64-linux-gnu"
USR_INCLUDE_DIR="${PKG_DIR}/usr/include/arrayfire"
USR_SHARE_CMAKE="${PKG_DIR}/usr/share/ArrayFire/cmake"
ETC_DIR="${PKG_DIR}/etc"

mkdir -p "${USR_LIB_DIR}" "${USR_INCLUDE_DIR}" "${USR_SHARE_CMAKE}" "${ETC_DIR}"

# Determine which libraries to include per package type
COMMON_LIBS=(libaf.so.3 libforge.so.1)
declare -a BACKEND_LIBS
case "${TYPE}" in
  cpu)
    BACKEND_LIBS=(libafcpu.so.3)
    ;;
  cuda)
    BACKEND_LIBS=(libafcuda.so.3)
    ;;
  opencl)
    BACKEND_LIBS=(libafopencl.so.3 libur_adapter_opencl.so.0 libur_loader.so.0)
    ;;
  oneapi)
    BACKEND_LIBS=(libafoneapi.so.3 libsycl.so.8 libmkl_sycl_blas.so.5)
    ;;
  full)
    BACKEND_LIBS=(libafcpu.so.3 libafcuda.so.3 libafopencl.so.3 libafoneapi.so.3)
    ;;
  *)
    echo "Unknown type: ${TYPE}" >&2
    exit 2
    ;;
esac

# Helper: copy a library name from lib64 to package lib dir, preserving symlinks
copy_lib() {
  local libname="$1"
  local src="${ROOT_DIR}/lib64"
  # Find files matching libname* (to capture version and symlinks)
  shopt -s nullglob
  # expand the wildcard (do NOT quote the pattern with *) so the shell can glob
  local files=("${src}/${libname}" ${src}/${libname}*)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Warning: library ${libname} not found in ${src}" >&2
    return 1
  fi

  for f in "${files[@]}"; do
    # use cp -a to preserve symlinks/permissions
    mkdir -p "${USR_LIB_DIR}"
    cp -a "${f}" "${USR_LIB_DIR}/"
  done
}

# copy common libs
for l in "${COMMON_LIBS[@]}"; do
  copy_lib "${l}" || true
done

# copy backend libs
for l in "${BACKEND_LIBS[@]}"; do
  copy_lib "${l}" || true
done

# Copy headers: only include top-level headers and af/ folder
if [[ -d "${ROOT_DIR}/include/af" ]]; then
  cp -a "${ROOT_DIR}/include/af" "${USR_INCLUDE_DIR}/"
fi
if [[ -f "${ROOT_DIR}/include/arrayfire.h" ]]; then
  cp -a "${ROOT_DIR}/include/arrayfire.h" "${USR_INCLUDE_DIR}/"
fi

# Copy etc version file
if [[ -f "${ROOT_DIR}/etc/arrayfire_version.txt" ]]; then
  install -D -m644 "${ROOT_DIR}/etc/arrayfire_version.txt" "${ETC_DIR}/arrayfire_version.txt"
fi


# Copy existing CMake package files from project into the package
if [[ -d "${ROOT_DIR}/share/ArrayFire/cmake" ]]; then
  cp -a "${ROOT_DIR}/share/ArrayFire/cmake/." "${USR_SHARE_CMAKE}/"
  echo "Copied CMake package files from ${ROOT_DIR}/share/ArrayFire/cmake into package"
  # Replace relative PACKAGE_PREFIX_DIR computation with a fixed system path so
  # the installed CMake config resolves to /usr regardless of packaging layout.
  CFG_FILE="${USR_SHARE_CMAKE}/ArrayFireConfig.cmake"
  if [[ -f "${CFG_FILE}" ]]; then
    # Replace the exact PACKAGE_PREFIX_DIR computation line with a fixed /usr
    sed -i.bak 's|get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)|set(PACKAGE_PREFIX_DIR "/usr")|' "${CFG_FILE}" || true
    # Fallback: also replace any other lines that set PACKAGE_PREFIX_DIR using get_filename_component
    sed -i.bak 's|get_filename_component(PACKAGE_PREFIX_DIR .* ABSOLUTE)|set(PACKAGE_PREFIX_DIR "/usr")|' "${CFG_FILE}" || true
    echo "Patched ${CFG_FILE} to use fixed PACKAGE_PREFIX_DIR /usr (backup at ${CFG_FILE}.bak)"
  fi
else
  echo "Error: project CMake package files not found at ${ROOT_DIR}/share/ArrayFire/cmake" >&2
  echo "Refusing to generate minimal CMake files; please add the project's share/ArrayFire/cmake to include proper targets." >&2
  exit 1
fi

# Compute package dependencies using dpkg-shlibdeps if available
DEPS=""
TEMP_SUBSTVARS="$(mktemp)"
LIB_PATHS=()
for f in "${USR_LIB_DIR}"/*; do
  if [[ -f "$f" || -L "$f" ]]; then
    LIB_PATHS+=("$f")
  fi
done

if command -v dpkg-shlibdeps >/dev/null 2>&1; then
  echo "Computing runtime dependencies with dpkg-shlibdeps..."
  # Run dpkg-shlibdeps against each library we added
  dpkg-shlibdeps -O -T"${TEMP_SUBSTVARS}" "${LIB_PATHS[@]}" >/dev/null 2>&1 || true
  # read shlibs:Depends from the substvars file
  if [[ -f "${TEMP_SUBSTVARS}" ]]; then
    DEPS_LINE=$(grep -E '^shlibs:Depends=' "${TEMP_SUBSTVARS}" || true)
    if [[ -n "${DEPS_LINE}" ]]; then
      DEPS=${DEPS_LINE#shlibs:Depends=}
    fi
  fi
fi

# Fallback basic deps
if [[ -z "${DEPS}" ]]; then
  # conservative base deps: libc6 and libstdc++6
  DEPS="libc6 (>= 2.17), libstdc++6"
fi

# Create control file
cat > "${PKG_DIR}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION_ARG}
Section: libs
Priority: optional
Architecture: ${ARCH}
Essential: no
Depends: ${DEPS}
Maintainer: ArrayFire packager <packager@example.com>
Description: ArrayFire runtime (${TYPE})
 ArrayFire is a high performance library for parallel computing with an easy-to-use API.
 This package contains the runtime libraries and headers for the ${TYPE} flavor.
EOF

# Recommended file permissions
chmod 0755 "${PKG_DIR}/DEBIAN"
if [[ -d "${PKG_DIR}/usr" ]]; then
  find "${PKG_DIR}/usr" -type d -exec chmod 0755 {} +
  find "${PKG_DIR}/usr" -type f -exec chmod 0644 {} +
  # make sure shared libs are executable by linking bits
  find "${PKG_DIR}/usr/lib" -type f -name "*.so*" -exec chmod 0755 {} + || true
fi

OUT_DEB="${SCRIPT_DIR}/${PACKAGE_NAME}_${VERSION_ARG}_${ARCH}.deb"
echo "Building ${OUT_DEB} ..."
# Use --root-owner-group so archive members are recorded as owned by root:root
# This avoids a warning when building as an unprivileged user (rootless build)
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${OUT_DEB}"

echo "Package built: ${OUT_DEB}"

# cleanup
rm -f "${TEMP_SUBSTVARS}"

exit 0
