/*
 * k.h — ink extension API
 *
 * Compile your shared library against this header, then load it in K:
 *
 *   f: "./mylib.so" 2: (`myfunc; 1)   / 1-argument function
 *   f @ "hello"                        / call it
 *
 * Your C function receives and returns opaque K handles.
 * Use the k*() accessors below to inspect and construct values.
 * Never cast K pointers or access struct fields directly.
 *
 * Ownership rules:
 *   - Arguments are BORROWED — do not call ku() on them.
 *   - The return value is OWNED by the caller — K will free it.
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

/* ── Type tags (kt() return values) ────────────────────────────────────────── */
#define KT_BLANK   0
#define KT_ERR     1
#define KT_BOOL    2   /* b  */
#define KT_INT     3   /* i  */
#define KT_FLOAT   4   /* f  */
#define KT_SYM     5   /* s  */
#define KT_CHAR    6   /* c  */
#define KT_LIST    9   /* L  — heterogeneous list        */
#define KT_IVEC   14   /* I  — int32 vector              */
#define KT_FVEC   15   /* F  — float32 vector            */
#define KT_SVEC   16   /* S  — symbol (uint32) vector    */
#define KT_CVEC   17   /* C  — char / byte vector        */

/* ── Atom constructors ──────────────────────────────────────────────────────── */
K  ki(int32_t n);           /* integer atom                     */
K  kf(float f);             /* float atom                       */
K  kc(uint8_t c);           /* char atom                        */
K  kb(int b);               /* bool atom (0=false, 1=true)      */
K  ks(const char* name);    /* interned symbol atom             */
K  kerr(void);              /* error value                      */

/* ── Vector constructors (uninitialized data — fill via k*p() pointers) ────── */
K  KC(int32_t n);           /* char/byte array of length n      */
K  KI(int32_t n);           /* int32 array of length n          */
K  KF(int32_t n);           /* float32 array of length n        */
K  KL(int32_t n);           /* mixed list of n blank elements   */

/* ── Inspection ─────────────────────────────────────────────────────────────── */
int8_t   kt(K x);           /* type tag (KT_* above)            */
int32_t  kn(K x);           /* length for arrays, -1 for atoms  */

int32_t  ki_val(K x);       /* extract int  (coerces i/b/c)     */
float    kf_val(K x);       /* extract float                    */
uint8_t  kc_val(K x);       /* extract char                     */
int      kb_val(K x);       /* extract bool (0 or 1)            */

/* Mutable data pointers — valid until the K handle is released. */
int32_t* kip(K x);          /* int32 data (KT_IVEC)             */
float*   kfp(K x);          /* float data  (KT_FVEC)            */
uint8_t* kcp(K x);          /* byte data   (KT_CVEC)            */

/* ── Memory ──────────────────────────────────────────────────────────────────── */
void ku(K x);               /* release reference — do NOT call on borrowed args */

#ifdef __cplusplus
}
#endif
#endif /* INK_K_H */
