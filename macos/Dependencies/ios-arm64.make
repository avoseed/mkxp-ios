# iOS arm64 (device) dependency build for mkxp-z.
#
# Base: arm64.make, retargeted from the macOS SDK to the iphoneos SDK.
# All the heavy lifting (build rules) lives in common.make; this file just sets
# the platform knobs it consumes (PLATFORM/SYSROOT/VERSION_MIN_FLAG/...).
#
# Targets that build & verify as iOS arm64: `make everything` (deps-core + ruby).
# `make fluidsynth` (glib via meson + fluidsynth) is codified but must run in an
# environment that can execute freshly-built native binaries (meson/fluidsynth run
# build-time helper binaries) — i.e. a normal shell, not a locked-down agent sandbox.
#
# Requires full Xcode (not just Command Line Tools) so the iphoneos SDK exists:
#   sudo xcode-select -s /Applications/Xcode.app
#   xcrun --sdk iphoneos --show-sdk-path   # must print a path
# Plus: brew install meson ninja  (for the fluidsynth/glib chain).

ARCH := arm64
PLATFORM := iphoneos
HOST := aarch64-apple-darwin
MINIMUM_REQUIRED := 14.0

SYSROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)
VERSION_MIN_FLAG := -miphoneos-version-min=$(MINIMUM_REQUIRED)
DEPLOYMENT_TARGET_ENV := IPHONEOS_DEPLOYMENT_TARGET=$(MINIMUM_REQUIRED)

# OpenSSL 3.0.12 ships a self-contained iOS arm64 target that resolves the SDK
# and compiler through xcrun. If it fights common.make's CC, fall back to
# `ios64-cross` and export CROSS_COMPILE/CROSS_TOP instead.
OPENSSL_FLAGS := ios64-xcrun

# Vendored libjxl can't cross-build for iOS (builds host CLI tools); game uses PNG/JPG.
IMG_JXL := no

# cmake cross-compile to iOS: CMAKE_SYSTEM_NAME=iOS flips cmake into cross mode
# (skips run-time probes, picks the iphoneos toolchain). Pin the sysroot explicitly.
# In cross mode find_package() only searches the sysroot by default, so point
# CMAKE_FIND_ROOT_PATH at our prefix and allow searching it (BOTH) for the libs
# we build (libogg, freetype, ...) instead of only the SDK.
# Recursive (=) so $(BUILD_PREFIX), defined later in common.make, expands at use time.
CMAKE_PLATFORM_ARGS = \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_SYSTEM_PROCESSOR=arm64 \
	-DCMAKE_OSX_SYSROOT=$(SYSROOT) \
	-DCMAKE_FIND_ROOT_PATH=$(BUILD_PREFIX) \
	-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
	-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=BOTH

# meson cross-file for the glib build (fluidsynth chain). Generated at build time
# because SYSROOT is machine-specific. needs_exe_wrapper=true is critical: build and
# host triples are both aarch64/darwin, so without it meson tries to RUN iOS test
# binaries on the host and hangs (same class as Ruby's build==host issue).
# Recursive (=) so $(BUILD_PREFIX) (defined later in common.make) expands at use time.
MESON_CROSS_FILE = $(BUILD_PREFIX)/ios-arm64.cross

# ---------------------------------------------------------------------------
# Ruby (the hard part). Build a shared libruby.3.1.dylib, matching mkxp-z's proven
# macOS configuration (the engine links @rpath/libruby.3.1.dylib). A static-only
# build hits broken static-ext / LTO final-link paths under iOS cross-compile;
# the dylib is embedded + code-signed into the app bundle's Frameworks at phase 2.
# iOS can't fork/exec, has no tty, and forbids JIT (W^X), so drop those ext + JIT.
# RUBY_SHARED_FLAG / RUBY_LIB / RUBY_POSTINSTALL keep their common.make defaults
# (--enable-shared, libruby.3.1.dylib, install_name_tool -id @rpath/...).
RUBY_OUT_EXT := fiddle,gdbm,win32ole,win32,pty,syslog,readline,dbm

# Make --build differ from --host (both would be aarch64-apple-darwin otherwise) so
# autoconf detects a cross-compile and skips AC_RUN probes that would try to execute
# iOS binaries on the host. The compiler stays `clang -arch arm64 -isysroot <iOS>`,
# so the build triple is only a cross-detection hint, not a real target.
RBUILD := x86_64-apple-darwin
RUBY_CONFIGURE_ENV_EXTRA := cross_compiling=yes
EXTRA_RUBY_CONFIG_ARGS := \
	--with-baseruby=$(shell which ruby) \
	--disable-jit-support

# Source fixups live in ios-patches/*.sh (recursive '=' so $(DOWNLOADS), set in
# common.make, expands at use time): make treats every unescaped '#' in a
# variable as a comment, which silently truncated the inline perl one-liners.
#  - ruby: iOS lacks <sys/vnode.h>/<sys/random.h>; drop bundled gems (their C
#    extensions can't cross-link and the game doesn't use them).
#  - glib: gspawn.c's libproc.h use (no public header on iOS, no exec anyway).
#  - fluidsynth: FindGLib2.cmake hardcodes AppKit/Carbon for all Apple targets.
RUBY_PATCH = sh ${PWD}/ios-patches/ruby.sh $(DOWNLOADS)/ruby

# NOTE (expected iteration): with cross_compiling=yes, Ruby's configure will ask
# for AC_TRY_RUN results it can't run on the host. Feed the failing ones back as
# `ac_cv_*=...` cache vars here until configure completes.

GLIB_PATCH = sh ${PWD}/ios-patches/glib.sh $(DOWNLOADS)/glib

FLUIDSYNTH_PATCH = sh ${PWD}/ios-patches/fluidsynth.sh $(DOWNLOADS)/fluidsynth

include common.make

# Defined after the include so $(BUILD_PREFIX) (from common.make) is resolved in the
# target. Generates the meson cross-file consumed by the glib build (see common.make).
$(MESON_CROSS_FILE): | init_dirs
	@printf '%s\n' \
		'[binaries]' \
		"c = ['clang', '-arch', '$(ARCH)', '-isysroot', '$(SYSROOT)']" \
		"cpp = ['clang++', '-arch', '$(ARCH)', '-isysroot', '$(SYSROOT)']" \
		"objc = ['clang', '-arch', '$(ARCH)', '-isysroot', '$(SYSROOT)']" \
		"ar = 'ar'" "strip = 'strip'" "pkg-config = 'pkg-config'" \
		'' '[properties]' 'needs_exe_wrapper = true' \
		'' '[host_machine]' \
		"system = 'darwin'" "subsystem = 'ios'" "kernel = 'xnu'" \
		"cpu_family = 'aarch64'" "cpu = 'aarch64'" "endian = 'little'" \
		'' '[built-in options]' \
		"c_args = ['$(VERSION_MIN_FLAG)']" \
		"cpp_args = ['$(VERSION_MIN_FLAG)']" \
		"objc_args = ['$(VERSION_MIN_FLAG)']" \
		"c_link_args = ['$(VERSION_MIN_FLAG)']" \
		"cpp_link_args = ['$(VERSION_MIN_FLAG)']" \
		> $@
	@echo "Generated meson cross-file: $@"
