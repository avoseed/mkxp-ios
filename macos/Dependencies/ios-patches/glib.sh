#!/bin/sh
# glib's gspawn.c includes <libproc.h>/<sys/proc_info.h> and calls proc_pidinfo()
# under a bare __APPLE__ guard. The iOS SDK has no public libproc.h and iOS can't
# exec children anyway, so gate both on !TARGET_OS_IPHONE; iOS then falls through
# to glib's generic fd-walk loop. Usage: glib.sh <glib source dir>
set -e
cd "$1"
perl -0pi -e 's|#ifdef __APPLE__\n#include <libproc\.h>\n#include <sys/proc_info\.h>|#ifdef __APPLE__\n#include <TargetConditionals.h>\n#if !TARGET_OS_IPHONE\n#include <libproc.h>\n#include <sys/proc_info.h>\n#endif|' glib/gspawn.c
perl -0pi -e 's|#if defined\(__APPLE__\)\n  /\* proc_pidinfo|#if defined(__APPLE__) && !TARGET_OS_IPHONE\n  /* proc_pidinfo|' glib/gspawn.c
