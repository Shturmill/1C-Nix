// SPDX-License-Identifier: MIT
/*
 * Проверка обхода 3 из pkgs/onec/x11-fixes.c без 1С: создаёт окно-диалог
 * с заданными подсказками размера, показывает его и печатает,
 * выставлен ли override-redirect.
 *
 *   x11-fixes-test <parent|normal> <map|raised>
 *
 * parent — невидимый родитель модального диалога 1С: min = max = 1×1;
 * normal — обычный диалог 400×300.
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 3)
    return 2;
  int parent = strcmp(argv[1], "parent") == 0;
  int raised = strcmp(argv[2], "raised") == 0;

  Display *dpy = XOpenDisplay(NULL);
  if (!dpy)
    return 3;
  int size = parent ? 1 : 300;
  Window w = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), 0, 0, size,
                                 size, 0, 0, 0);

  XSizeHints hints = {0};
  if (parent) {
    hints.flags = PMinSize | PMaxSize;
    hints.min_width = hints.min_height = 1;
    hints.max_width = hints.max_height = 1;
  } else {
    hints.flags = PMinSize;
    hints.min_width = 400;
    hints.min_height = 300;
  }
  XSetWMNormalHints(dpy, w, &hints);

  Atom type = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
  Atom dialog = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
  XChangeProperty(dpy, w, type, XA_ATOM, 32, PropModeReplace,
                  (unsigned char *)&dialog, 1);

  if (raised)
    XMapRaised(dpy, w);
  else
    XMapWindow(dpy, w);
  XSync(dpy, False);

  XWindowAttributes attrs;
  if (!XGetWindowAttributes(dpy, w, &attrs))
    return 4;
  printf("override_redirect=%d\n", attrs.override_redirect ? 1 : 0);
  XCloseDisplay(dpy);
  return 0;
}
