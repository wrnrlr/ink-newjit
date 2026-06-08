/*
 * k.h — ink extension API
 *
 * Compile your shared library against this header, then load it in K:
 *
 *   f: "./mylib.so" 2: (`myfunc; 1)   / 1-argument function
 *   f @ "hello"                        / call it
 *
 * Ownership rules:
 *   - Arguments are BORROWED — do not call ku() on them.
 *   - Return values are OWNED by the caller — ink will call ku() on them.
 *   - Return NULL to signal an error.
 */

#ifndef INK_K_H
#define INK_K_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque K value handle. */
typedef void* K;

/* ── Type tags (returned by kt()) ──────────────────────────────────────────── */
#define KT_BLANK   0
#define KT_ERR     1
#define KT_BOOL    2   /* b  */
#define KT_INT     3   /* i  */
#define KT_FLOAT   4   /* f  */
#define KT_SYM     5   /* s  */
#define KT_CHAR    6   /* c  */
#define KT_LIST    9   /* L  — heterogeneous list     */
#define KT_IVEC   14   /* I  — int32 vector           */
#define KT_FVEC   15   /* F  — float32 vector         */
#define KT_SVEC   16   /* S  — symbol (uint32) vector */
#define KT_CVEC   17   /* C  — char / byte vector     */

/* ── Atom constructors ──────────────────────────────────────────────────────── */
K  ki(int32_t n);           /* integer atom                          */
K  kf(float f);             /* float atom                            */
K  kc(uint8_t c);           /* char atom                             */
K  kb(int b);               /* bool atom (0=false)                   */
K  ks(const char* name);    /* interned symbol (requires current_vm) */
K  kerr(void);              /* error value                           */

/* ── Vector constructors (zero-initialized) ────────────────────────────────── */
K  KC(int32_t n);           /* char/byte array  */
K  KI(int32_t n);           /* int32 array      */
K  KF(int32_t n);           /* float32 array    */
K  KL(int32_t n);           /* mixed list       */

/* ── Inspection ─────────────────────────────────────────────────────────────── */
int8_t   kt(K x);           /* type tag (KT_* above)           */
int32_t  kn(K x);           /* length for arrays, -1 for atoms */

int32_t  ki_val(K x);       /* extract int  (coerces i/b/c/f)  */
float    kf_val(K x);       /* extract float                   */
uint8_t  kc_val(K x);       /* extract char                    */
int      kb_val(K x);       /* extract bool (0 or 1)           */

/* Mutable data pointers — valid until ku() is called. */
int32_t* kip(K x);          /* int32 data  (KT_IVEC) */
float*   kfp(K x);          /* float data  (KT_FVEC) */
uint8_t* kcp(K x);          /* byte data   (KT_CVEC) */

/* ── Memory ──────────────────────────────────────────────────────────────────── */
void ku(K x);               /* release reference (do NOT call on borrowed args) */

/* Set element at index in a KL list. Consumes val (do not ku() it after).
 * Returns 0 on success, -1 on error. */
int k_list_set(K list, int index, K val);

/* ── Callbacks into the K runtime ───────────────────────────────────────────── */
/* These require current_vm to be set, which is guaranteed during any FFI call. */

/* Call a K function (func) with one argument. */
K k_call(K func, K arg);

/* Call a K function with two arguments. */
K k_call2(K func, K x, K y);

/* Build a symbol-keyed dict from n key/value pairs.
 * keys: null-terminated strings (interned as symbols)
 * vals: borrowed K handles */
K k_make_dict(int n, const char** keys, K* vals);

#ifdef __cplusplus
}
#endif
#endif /* INK_K_H */
