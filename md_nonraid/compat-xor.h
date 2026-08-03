/*
 * Kernel 7.1+ compatibility shim
 */

#ifndef NONRAID_COMPAT_XOR_H
#define NONRAID_COMPAT_XOR_H

#include <linux/version.h>

/*
 * Kernel 7.1 moved the xor code to lib/raid/xor/ and replaced xor_blocks() with
 * xor_gen(), which takes an arbitrary source count instead of being capped at
 * MAX_XOR_BLOCKS. Semantics are otherwise identical: the sources are xor'ed
 * into @dest, which is also an operand. Keep the driver on the old interface so
 * the call sites stay in sync with upstream.
 *
 * Keeping MAX_XOR_BLOCKS at 4 is not merely conservative: xor_impl.h chunks
 * min(src_cnt, 4) into the same primitives the old do_2..do_5 used, so at a cap
 * of 4 the driver never exceeds one chunk and the emitted work is identical.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,1,0)

/* Declares xor_gen(); must precede the inline below. */
#include <linux/raid/xor.h>

#ifndef MAX_XOR_BLOCKS
#define MAX_XOR_BLOCKS 4
#endif

static inline void xor_blocks(unsigned int count, unsigned int bytes,
			      void *dest, void **srcs)
{
	xor_gen(dest, srcs, count, bytes);
}

#endif /* LINUX_VERSION_CODE >= 7.1.0 */

#endif /* NONRAID_COMPAT_XOR_H */
