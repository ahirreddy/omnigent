/* Preloaded into the x264 encoder process (LD_PRELOAD / DYLD_INSERT_LIBRARIES) so its stdio
 * stdout is unbuffered: x264 writes each frame with fwrite and never flushes, so over a pipe a
 * small frame would otherwise sit in the stdio buffer until later frames fill it. */
#include <stdio.h>

__attribute__((constructor)) static void omnigent_unbuffer_stdout(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
}
