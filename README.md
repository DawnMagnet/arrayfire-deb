# ArrayFire .deb packaging helper

This folder contains a small helper script to build .deb packages for different
ArrayFire runtime flavors (cpu, cuda, opencl, oneapi, full).

Files

- make_deb.sh: main script to create the .deb. Usage:

  ./make_deb.sh <cpu|cuda|opencl|oneapi|full> [version] [arch]

  - If version is omitted the script will read `etc/arrayfire_version.txt`.
  - arch defaults to `amd64`.

What the script does

- Copies only the runtime libraries required for the chosen flavor from
  `lib64/` into the package (preserving symlinks when possible).
- Copies top-level headers (`include/arrayfire.h` and `include/af/`).
- Adds a small CMake config to `/usr/share/ArrayFire/cmake/ArrayFireConfig.cmake`
  that points to installed libraries and the include directory.
- Attempts to compute accurate runtime `Depends:` using `dpkg-shlibdeps`.
  If that tool is not available it falls back to a conservative minimal set
  (`libc6`, `libstdc++6`).

Requirements

- Debian packaging tools on the machine to build and calculate dependencies:
  - dpkg-deb (for building the final .deb)
  - dpkg-shlibdeps (optional, for correct runtime dependencies)

Notes and caveats

- The script is conservative: it includes ArrayFire runtime libs and headers
  only. It does not bundle GPU drivers or system libraries (e.g. CUDA, cuBLAS,
  OpenCL drivers, oneAPI runtimes). Those should be installed separately and
  will typically be listed in the package `Depends` computed by
  `dpkg-shlibdeps`.
- The generated CMake config is intentionally small and only intended to
  provide findable variables to downstream builds. You can replace
  `/usr/share/ArrayFire/cmake/ArrayFireConfig.cmake` with your own full
  packaging CMake files if you have more advanced requirements.

Example

cd packaging
./make_deb.sh cpu

This produces `arrayfire-cpu_<version>_amd64.deb` in the `packaging/` folder.

If you want me to attempt a package build on this machine now, tell me which
flavor to build and I'll try (I will run `dpkg-deb` and `dpkg-shlibdeps` if
available; I won't install the package on the host unless you ask).
