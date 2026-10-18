// SPDX-License-Identifier: MIT
/*
 * Проверка обходов из pkgs/onec/x11-fixes.c без 1С и без WM (Xvfb).
 *
 *   1cv8c <parent|normal> <map|raised>
 *     Обход 3: создаёт окно-диалог с заданными подсказками размера,
 *     показывает его и печатает, выставлен ли override-redirect.
 *     parent — невидимый родитель модального диалога 1С: min = max = 1×1;
 *     normal — обычный диалог 400×300.
 *
 *   1cv8c configure <late|early|premap>
 *     Обход 1: другое соединение двигает и растягивает окно; печатает
 *     полученные ConfigureNotify («x,y wxh»). late — один раз после
 *     разбора MapNotify; early — дважды, пока MapNotify в очереди;
 *     premap — дважды до показа, события ещё не разобраны.
 *
 *   1cv8c close <basic|dialog|self|self-late|remap|short>
 *     Обход 2: окну приходит WM_DELETE_WINDOW, главный поток ждёт семафор
 *     (300 мс, short — 20 мс), затем окну приходит нажатие клавиши.
 *     Печатает, показано ли окно после ожидания и после клавиши и
 *     сохранился ли _NET_WM_STATE. dialog — перед ожиданием показывается
 *     второе окно (вопрос «Сохранить изменения?»); self — окно прячет само
 *     приложение до ожидания, self-late — после; remap — приложение само
 *     показывает спрятанное окно. Снятие с учёта WM (удаление
 *     _NET_WM_STATE) изображает сам тест.
 *
 * Обходы работают только в процессах 1С, поэтому программа запускается
 * под именем клиента (симлинк 1cv8c). С -DPROBE_LIBRARY собирается
 * библиотека с функцией probe() для x11-fixes-dlopen.c.
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <poll.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

int probe(const char *kind, const char *call) {
  int parent = strcmp(kind, "parent") == 0;
  int raised = strcmp(call, "raised") == 0;

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

#ifndef PROBE_LIBRARY
/* Следующее событие, если оно придёт за ms миллисекунд. */
static int next_event(Display *dpy, XEvent *ev, int ms) {
  struct pollfd p = {.fd = ConnectionNumber(dpy), .events = POLLIN};
  while (!XPending(dpy))
    if (poll(&p, 1, ms) <= 0)
      return 0;
  XNextEvent(dpy, ev);
  return 1;
}

static int wait_for(Display *dpy, int type) {
  XEvent ev;
  while (next_event(dpy, &ev, 2000))
    if (ev.type == type)
      return 1;
  return 0;
}

static void drain(Display *dpy, int ms) {
  XEvent ev;
  while (next_event(dpy, &ev, ms))
    ;
}

/* Как WM: передвинуть и растянуть окно дважды. */
static void move_twice(Display *other, Window w) {
  XMoveResizeWindow(other, w, 50, 60, 200, 150);
  XMoveResizeWindow(other, w, 70, 80, 300, 200);
  XSync(other, False);
}

static int test_configure(const char *variant) {
  Display *dpy = XOpenDisplay(NULL), *other = XOpenDisplay(NULL);
  if (!dpy || !other)
    return 3;
  Window w = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), 10, 10, 100,
                                 100, 0, 0, 0);
  XSelectInput(dpy, w, StructureNotifyMask);
  XSync(dpy, False);
  if (strcmp(variant, "premap") == 0) {
    /* События изменений ещё не разобраны, когда окно показывают. */
    move_twice(other, w);
    XMapWindow(dpy, w);
  } else if (strcmp(variant, "early") == 0) {
    /* WM успевает дважды, пока MapNotify ещё в очереди. */
    XMapWindow(dpy, w);
    XSync(dpy, False);
    move_twice(other, w);
  } else {
    XMapWindow(dpy, w);
    if (!wait_for(dpy, MapNotify))
      return 4;
    XMoveResizeWindow(other, w, 50, 60, 200, 150);
    XSync(other, False);
  }
  XEvent ev;
  const char *sep = "";
  while (next_event(dpy, &ev, 500))
    if (ev.type == ConfigureNotify) {
      printf("%s%d,%d %dx%d", sep, ev.xconfigure.x, ev.xconfigure.y,
             ev.xconfigure.width, ev.xconfigure.height);
      sep = " ";
    }
  printf("\n");
  return 0;
}

struct delayed_post {
  sem_t sem;
  int ms;
};

static void *post_later(void *arg) {
  struct delayed_post *p = arg;
  struct timespec ts = {p->ms / 1000, p->ms % 1000 * 1000000L};
  nanosleep(&ts, NULL);
  sem_post(&p->sem);
  return NULL;
}

static const char *map_state(Display *dpy, Window w) {
  XWindowAttributes a;
  XSync(dpy, False);
  if (!XGetWindowAttributes(dpy, w, &a))
    return "gone";
  return a.map_state == IsViewable ? "shown" : "hidden";
}

static int test_close(const char *variant) {
  Display *dpy = XOpenDisplay(NULL);
  if (!dpy)
    return 3;
  Window root = DefaultRootWindow(dpy);
  Window w = XCreateSimpleWindow(dpy, root, 0, 0, 100, 100, 0, 0, 0);
  Atom protocols = XInternAtom(dpy, "WM_PROTOCOLS", False);
  Atom del = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
  Atom state = XInternAtom(dpy, "_NET_WM_STATE", False);
  Atom fullscreen = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
  XSetWMProtocols(dpy, w, &del, 1);
  XChangeProperty(dpy, w, state, XA_ATOM, 32, PropModeReplace,
                  (unsigned char *)&fullscreen, 1);
  XSelectInput(dpy, w, StructureNotifyMask | KeyPressMask);
  XMapWindow(dpy, w);
  if (!wait_for(dpy, MapNotify))
    return 4;

  /* Запрос на закрытие — как от WM. */
  XEvent m = {.xclient = {.type = ClientMessage,
                          .window = w,
                          .message_type = protocols,
                          .format = 32}};
  m.xclient.data.l[0] = (long)del;
  XSendEvent(dpy, w, False, NoEventMask, &m);
  drain(dpy, 100);

  if (strcmp(variant, "dialog") == 0) {
    Window d = XCreateSimpleWindow(dpy, root, 0, 0, 50, 50, 0, 0, 0);
    XSelectInput(dpy, d, StructureNotifyMask);
    XMapWindow(dpy, d);
    if (!wait_for(dpy, MapNotify))
      return 4;
  } else if (strcmp(variant, "self") == 0) {
    XWithdrawWindow(dpy, w, DefaultScreen(dpy));
    drain(dpy, 100);
  }

  /* Главный поток ждёт семафор, как 1С при завершении. */
  struct delayed_post wait = {.ms = strcmp(variant, "short") == 0 ? 20 : 300};
  sem_init(&wait.sem, 0, 0);
  pthread_t t;
  pthread_create(&t, NULL, post_later, &wait);
  sem_wait(&wait.sem);
  pthread_join(t, NULL);
  const char *after_wait = map_state(dpy, w);
  /* Снятое окно WM снимает и с учёта: удаляет _NET_WM_STATE. */
  if (strcmp(after_wait, "hidden") == 0)
    XDeleteProperty(dpy, w, state);

  /* Приложение само прячет или показывает уже спрятанное нами окно. */
  if (strcmp(variant, "self-late") == 0)
    XWithdrawWindow(dpy, w, DefaultScreen(dpy));
  else if (strcmp(variant, "remap") == 0)
    XMapWindow(dpy, w);
  drain(dpy, 100);

  XEvent k = {.xkey = {.type = KeyPress, .window = w, .root = root}};
  XSendEvent(dpy, w, False, KeyPressMask, &k);
  drain(dpy, 200);
  const char *after_key = map_state(dpy, w);

  Atom type;
  int format;
  unsigned long n, after;
  unsigned char *data = NULL;
  int kept = XGetWindowProperty(dpy, w, state, 0, 8, False, XA_ATOM, &type,
                                &format, &n, &after, &data) == Success &&
             data && n == 1 && ((Atom *)data)[0] == fullscreen;
  if (data)
    XFree(data);
  printf("wait=%s key=%s state=%s\n", after_wait, after_key,
         kept ? "kept" : "lost");
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "configure") == 0)
    return test_configure(argv[2]);
  if (argc == 3 && strcmp(argv[1], "close") == 0)
    return test_close(argv[2]);
  return argc == 3 ? probe(argv[1], argv[2]) : 2;
}
#endif
