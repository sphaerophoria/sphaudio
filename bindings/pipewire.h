// Aro seems to fail to fold some constant expressions
// https://codeberg.org/ziglang/translate-c/issues/322
//
// Aro seems to be using C11 to do our translation. Just disable static
// assertions to dodge the bug :)
//
// We're hoping that since we are ONLY doing bindings generation, the result of
// the static assert shouldn't be a big deal. If they passed when compiling,
// they should pass when generating :)
#define _Static_assert(expr, msg)

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
