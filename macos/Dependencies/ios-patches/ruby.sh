#!/bin/sh
# iOS SDK fixups for Ruby (see ios-arm64.make). Usage: ruby.sh <ruby source dir>
# Kept out of the make file because make treats every unescaped '#' as a comment.
set -e
cd "$1"

# dir.c includes <sys/vnode.h> under a bare __APPLE__ guard; iOS lacks it and
# only needs the vtype/vtagtype enums (XNU ABI order).
perl -0pi -e 's|# include <sys/vnode\.h>|#include <TargetConditionals.h>\n# if TARGET_OS_IPHONE\nenum vtype { VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD, VSTR, VCPLX };\nenum vtagtype { VT_NON, VT_UFS, VT_NFS, VT_MFS, VT_MSDOSFS, VT_LFS, VT_LOFS, VT_FDESC, VT_PORTAL, VT_NULL, VT_UMAP, VT_KERNFS, VT_PROCFS, VT_AFS, VT_ISOFS, VT_UNION, VT_HFS, VT_ZFS, VT_DEVFS, VT_WEBDAV, VT_UDF, VT_AFP, VT_CDDA, VT_CIFS, VT_OTHER };\n# else\n#  include <sys/vnode.h>\n# endif|' dir.c
grep -q 'TARGET_OS_IPHONE' dir.c

# random.c needs a getentropy prototype (the symbol exists, <sys/random.h> doesn't).
perl -0pi -e 's|# if defined\(HAVE_SYS_RANDOM_H\)\n#  include <sys/random\.h>\n# endif|# if defined(HAVE_SYS_RANDOM_H)\n#  include <sys/random.h>\n# elif defined(__APPLE__)\nextern int getentropy(void *, size_t); /* iOS SDK ships no <sys/random.h> */\n# endif|' random.c
grep -q 'extern int getentropy' random.c

# Bundled gems' .bundle C extensions can't cross-link; the game doesn't use them.
sed -i '' '/^[^#]/d' gems/bundled_gems
