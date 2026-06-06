/*
 * add.c — minimal ink FFI example
 *
 * Build (macOS):
 *   cc -shared -fPIC -o add.dylib add.c -I../include
 *
 * Build (Linux):
 *   cc -shared -fPIC -o add.so add.c -I../include
 *
 * Use in K:
 *   add: "./add.dylib" 2: (`add; 2)
 *   add[3; 4]            / → 7
 *   add[1.5; 2.5]        / → 4.0 (floats coerced)
 */

#include "k.h"

K add(K x, K y) {
    /* Both int atoms: return int */
    if (kt(x) == KT_INT && kt(y) == KT_INT)
        return ki(ki_val(x) + ki_val(y));
    /* Otherwise: return float */
    return kf(kf_val(x) + kf_val(y));
}
