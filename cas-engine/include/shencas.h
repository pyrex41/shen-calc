/* shencas.h — C ABI for the embedded shen-cas computer-algebra engine. */
#ifndef SHENCAS_H
#define SHENCAS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a booted CAS engine. */
typedef struct ShenCtx ShenCtx;

/* Boot the embedded shen-cas slice. Returns NULL on failure; free with
 * shen_free(). The reducer is deeply recursive and tree-walked, so call this
 * (and shen_cas_reduce) from a thread with a large stack (>= ~16 MB). */
ShenCtx *shen_cas_boot(void);

/* Parse + reduce + pretty-print a CAS expression, e.g.
 * "D[Sin[x],x]" -> "[Cos x]". Returns a heap string ("error: …" on failure);
 * release it with shen_string_free(). */
char *shen_cas_reduce(ShenCtx *ctx, const char *src);

/* Free a string returned by shen_cas_reduce(). */
void shen_string_free(char *s);

/* Free a handle returned by shen_cas_boot(). */
void shen_free(ShenCtx *ctx);

#ifdef __cplusplus
}
#endif

#endif /* SHENCAS_H */
