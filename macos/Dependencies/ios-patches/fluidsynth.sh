#!/bin/sh
# fluidsynth's FindGLib2.cmake appends AppKit + Carbon on every Apple target, but
# iOS has neither, so the dylib link fails. Keep Foundation/CoreFoundation and
# gate the other two behind a non-iOS check. Usage: fluidsynth.sh <source dir>
set -e
cd "$1"
perl -0pi -e 's|    list\(APPEND _glib2_link_libraries "-Wl,-framework,Foundation"\n         "-Wl,-framework,CoreFoundation" "-Wl,-framework,AppKit"\n         "-Wl,-framework,Carbon"\)|    list(APPEND _glib2_link_libraries "-Wl,-framework,Foundation"\n         "-Wl,-framework,CoreFoundation")\n    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")\n      list(APPEND _glib2_link_libraries "-Wl,-framework,AppKit"\n           "-Wl,-framework,Carbon")\n    endif()|' cmake_admin/FindGLib2.cmake
