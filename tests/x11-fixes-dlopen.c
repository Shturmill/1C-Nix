// SPDX-License-Identifier: MIT
/*
 * x11-fixes-test, загруженный через dlopen: процесс сам с libX11 не
 * слинкован, а перехват libc (nanosleep) срабатывает раньше, чем libX11
 * появляется в процессе. Так бывает в дочерних процессах 1С, которые
 * наследуют LD_PRELOAD (браузер и т.п.).
 *
 *   1cv8 <libprobe.so> <global|local> <parent|normal> <map|raised>
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

int main(int argc, char **argv) {
  if (argc != 5)
    return 2;
  struct timespec ts = {0, 1000};
  nanosleep(&ts, NULL);
  int scope = strcmp(argv[2], "global") == 0 ? RTLD_GLOBAL : RTLD_LOCAL;
  void *h = dlopen(argv[1], RTLD_NOW | scope);
  if (!h) {
    fprintf(stderr, "%s\n", dlerror());
    return 3;
  }
  int (*probe)(const char *, const char *) =
      (int (*)(const char *, const char *))dlsym(h, "probe");
  return probe ? probe(argv[3], argv[4]) : 4;
}
