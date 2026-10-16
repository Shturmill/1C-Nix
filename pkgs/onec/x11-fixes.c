// SPDX-License-Identifier: MIT
/*
 * LD_PRELOAD для клиентов 1С под X11 (XWayland, тайловые WM): обходы
 * дефектов окон на wxWidgets — Конфигуратора и толстого клиента. Тонкий
 * клиент ими не страдает, но библиотека ему не мешает.
 *
 * 1. Серые полосы после fullscreen/maximize/тайлинга. Если в одном
 *    ConfigureNotify изменились и позиция, и размер, GTK растягивает окно,
 *    а 1С не перестраивает содержимое: остаток заливается фоном темы.
 *    Hyprland меняет геометрию именно так. Перемещение и изменение размера
 *    по отдельности 1С обрабатывает, поэтому событие делится на два:
 *    сначала перемещение со старым размером, затем настоящее событие.
 *
 * 2. Долгое закрытие. После WM_DELETE_WINDOW 1С до ~1 с ждёт остановки
 *    своих потоков (семафор) и ещё спит 1,5 с, не убирая окно. Если после
 *    запроса на закрытие главный поток надолго заблокировался (sem_wait,
 *    pthread_join дольше 150 мс, сон от секунды), окно снимается с экрана;
 *    процесс завершается как обычно. Короткие ожидания не в счёт: перед
 *    вопросом «Сохранить изменения?» 1С тоже ждёт семафор. Если окно всё
 *    же спрятано, а 1С показала новое окно или получила ввод, спрятанные
 *    окна возвращаются.
 *
 * 3. Пустое окно рядом с диалогом. Модальному диалогу 1С назначает
 *    родителя — невидимый диалог 1×1 (min = max = 1×1, без рамки). Hyprland
 *    подсказки размера такого окна не учитывает и показывает его 800×800.
 *    Перед показом такому окну ставится override-redirect: WM им не
 *    управляет, и оно остаётся пикселем в углу, как задумано.
 *
 * Отключить: ONEC_NO_X11_FIXES=1.
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define GEOMETRY_SLOTS 64
#define CLOSING_SLOTS 8
#define CLOSING_TTL_NS (10LL * 1000000000LL)
#define BLOCKED_NS (150LL * 1000000LL)

static int (*real_next_event)(Display *, XEvent *);
static int (*real_put_back_event)(Display *, XEvent *);
static Atom (*real_intern_atom)(Display *, const char *, Bool);
static int (*real_nanosleep)(const struct timespec *, struct timespec *);
static int (*real_pthread_join)(pthread_t, void **);
static int (*real_timedjoin)(pthread_t, void **, const struct timespec *);
static int (*real_sem_wait)(sem_t *);
static int (*real_sem_timedwait)(sem_t *, const struct timespec *);
static int (*real_map_window)(Display *, Window);
static Status (*real_get_normal_hints)(Display *, Window, XSizeHints *,
                                       long *);
static int (*real_get_property)(Display *, Window, Atom, long, long, Bool,
                                Atom, Atom *, int *, unsigned long *,
                                unsigned long *, unsigned char **);
static int (*real_change_attributes)(Display *, Window, unsigned long,
                                     XSetWindowAttributes *);
static int (*real_free)(void *);

static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int disabled;

static void init(void) {
  real_next_event = dlsym(RTLD_NEXT, "XNextEvent");
  real_put_back_event = dlsym(RTLD_NEXT, "XPutBackEvent");
  real_intern_atom = dlsym(RTLD_NEXT, "XInternAtom");
  real_nanosleep = dlsym(RTLD_NEXT, "nanosleep");
  real_pthread_join = dlsym(RTLD_NEXT, "pthread_join");
  real_timedjoin = dlsym(RTLD_NEXT, "pthread_timedjoin_np");
  real_sem_wait = dlsym(RTLD_NEXT, "sem_wait");
  real_sem_timedwait = dlsym(RTLD_NEXT, "sem_timedwait");
  real_map_window = dlsym(RTLD_NEXT, "XMapWindow");
  real_get_normal_hints = dlsym(RTLD_NEXT, "XGetWMNormalHints");
  real_get_property = dlsym(RTLD_NEXT, "XGetWindowProperty");
  real_change_attributes = dlsym(RTLD_NEXT, "XChangeWindowAttributes");
  real_free = dlsym(RTLD_NEXT, "XFree");
  disabled = getenv("ONEC_NO_X11_FIXES") != NULL;
}

static long long now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* --- 1. Деление ConfigureNotify ---------------------------------------- */

struct geometry {
  Window window;
  int x, y, width, height;
};

static struct geometry geometries[GEOMETRY_SLOTS];
static unsigned next_geometry;

static struct geometry *find_geometry(Window w) {
  for (unsigned i = 0; i < GEOMETRY_SLOTS; i++)
    if (geometries[i].window == w)
      return &geometries[i];
  return NULL;
}

static void split_configure(Display *dpy, XEvent *ev) {
  XConfigureEvent *c = &ev->xconfigure;
  struct geometry *g = find_geometry(c->window);
  if (!g) {
    g = &geometries[next_geometry++ % GEOMETRY_SLOTS];
    g->window = c->window;
  } else if ((c->x != g->x || c->y != g->y) &&
             (c->width != g->width || c->height != g->height) &&
             real_put_back_event) {
    /* Не наоборот (размер, потом позиция): позицию настоящего события
     * GDK не берёт из него, а спрашивает у сервера — она уже новая. */
    XEvent resized = *ev;
    real_put_back_event(dpy, &resized);
    c->width = g->width;
    c->height = g->height;
  }
  g->x = c->x;
  g->y = c->y;
  g->width = c->width;
  g->height = c->height;
}

/* --- 2. Быстрое скрытие закрываемых окон -------------------------------- */

struct closing {
  Window window;
  long long since;
};

static struct closing closing[CLOSING_SLOTS];
static int closing_pending;
static Window hidden[CLOSING_SLOTS];
static unsigned hidden_count;
static char display_name[256];
static Atom wm_protocols, wm_delete_window;

static void note_close_request(Display *dpy, XEvent *ev) {
  if (!wm_protocols && real_intern_atom) {
    wm_protocols = real_intern_atom(dpy, "WM_PROTOCOLS", True);
    wm_delete_window = real_intern_atom(dpy, "WM_DELETE_WINDOW", True);
    const char *name = DisplayString(dpy);
    if (name)
      strncpy(display_name, name, sizeof display_name - 1);
  }
  XClientMessageEvent *m = &ev->xclient;
  if (!wm_protocols || m->message_type != wm_protocols || m->format != 32 ||
      (Atom)m->data.l[0] != wm_delete_window)
    return;
  unsigned slot = 0;
  for (unsigned i = 0; i < CLOSING_SLOTS; i++) {
    if (closing[i].window == m->window) {
      slot = i;
      break;
    }
    if (closing[i].since < closing[slot].since)
      slot = i;
  }
  closing[slot].window = m->window;
  closing[slot].since = now_ns();
  __atomic_store_n(&closing_pending, 1, __ATOMIC_RELEASE);
}

/* Свои запросы — через отдельное соединение: ошибки на нём GDK
 * игнорирует, а на своём (BadWindow, если окно уже уничтожено) завершил
 * бы процесс. */
static void set_mapped(const Window *windows, unsigned n, int map) {
  Display *(*open)(const char *) = dlsym(RTLD_DEFAULT, "XOpenDisplay");
  int (*change)(Display *, Window) =
      dlsym(RTLD_DEFAULT, map ? "XMapWindow" : "XUnmapWindow");
  int (*sync)(Display *, Bool) = dlsym(RTLD_DEFAULT, "XSync");
  int (*close_display)(Display *) = dlsym(RTLD_DEFAULT, "XCloseDisplay");
  if (!n || !display_name[0] || !open || !change || !sync || !close_display)
    return;
  Display *own = open(display_name);
  if (!own)
    return;
  for (unsigned i = 0; i < n; i++)
    change(own, windows[i]);
  sync(own, False);
  close_display(own);
}

/* Вызывается в XNextEvent, под lock: 1С жива и показывает новое окно
 * (вопрос перед закрытием) или пользователь что-то нажал — значит,
 * закрытие отменено или ждёт ответа. */
static void note_activity(XEvent *ev) {
  for (unsigned i = 0; i < CLOSING_SLOTS; i++)
    if (ev->type != MapNotify && closing[i].window == ev->xany.window)
      closing[i].window = 0;
  if (!hidden_count)
    return;
  if (ev->type == MapNotify)
    for (unsigned i = 0; i < hidden_count; i++)
      if (hidden[i] == ev->xmap.window)
        return;
  set_mapped(hidden, hidden_count, 1);
  hidden_count = 0;
}

static int on_main_thread(void) {
  return __atomic_load_n(&closing_pending, __ATOMIC_ACQUIRE) && !disabled &&
         syscall(SYS_gettid) == getpid();
}

/* Главный поток заблокировался надолго: убрать закрываемые окна. */
static void hide_closing_windows(void) {
  long long now = now_ns();
  pthread_mutex_lock(&lock);
  closing_pending = 0;
  for (unsigned i = 0; i < CLOSING_SLOTS; i++) {
    if (closing[i].window && now - closing[i].since < CLOSING_TTL_NS &&
        hidden_count < CLOSING_SLOTS)
      hidden[hidden_count++] = closing[i].window;
    closing[i].window = 0;
  }
  set_mapped(hidden, hidden_count, 0);
  pthread_mutex_unlock(&lock);
}

static struct timespec deadline(int clock) {
  struct timespec ts;
  clock_gettime(clock, &ts);
  ts.tv_nsec += BLOCKED_NS;
  if (ts.tv_nsec >= 1000000000L) {
    ts.tv_sec++;
    ts.tv_nsec -= 1000000000L;
  }
  return ts;
}

/* --- 3. Невидимый родитель модальных диалогов -------------------------- */

static int is_dialog(Display *dpy, Window w) {
  Atom type = real_intern_atom(dpy, "_NET_WM_WINDOW_TYPE", True);
  Atom dialog = real_intern_atom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", True);
  if (!type || !dialog)
    return 0;
  Atom actual;
  int format;
  unsigned long n, after;
  unsigned char *data = NULL;
  int found = 0;
  if (real_get_property(dpy, w, type, 0, 8, False, XA_ATOM, &actual, &format,
                        &n, &after, &data) == Success &&
      data && format == 32)
    for (unsigned long i = 0; i < n; i++)
      if (((Atom *)data)[i] == dialog)
        found = 1;
  if (data)
    real_free(data);
  return found;
}

static int is_modal_parent(Display *dpy, Window w) {
  if (!real_get_normal_hints || !real_get_property || !real_intern_atom ||
      !real_change_attributes || !real_free)
    return 0;
  XSizeHints hints;
  long supplied;
  if (!real_get_normal_hints(dpy, w, &hints, &supplied) ||
      !(hints.flags & PMaxSize) || hints.max_width > 1 ||
      hints.max_height > 1)
    return 0;
  return is_dialog(dpy, w);
}

/* --- Перехваты ----------------------------------------------------------- */

int XNextEvent(Display *dpy, XEvent *ev) {
  pthread_once(&once, init);
  int r = real_next_event(dpy, ev);
  if (disabled)
    return r;

  pthread_mutex_lock(&lock);
  switch (ev->type) {
  case ConfigureNotify:
    if (!ev->xconfigure.send_event)
      split_configure(dpy, ev);
    break;
  case ClientMessage:
    note_close_request(dpy, ev);
    break;
  case MapNotify:
  case KeyPress:
  case ButtonPress:
    note_activity(ev);
    break;
  }
  pthread_mutex_unlock(&lock);
  return r;
}

int XMapWindow(Display *dpy, Window w) {
  pthread_once(&once, init);
  if (!disabled && is_modal_parent(dpy, w)) {
    XSetWindowAttributes attrs = {.override_redirect = True};
    real_change_attributes(dpy, w, CWOverrideRedirect, &attrs);
  }
  return real_map_window(dpy, w);
}

int nanosleep(const struct timespec *req, struct timespec *rem) {
  pthread_once(&once, init);
  if (req && req->tv_sec >= 1 && on_main_thread())
    hide_closing_windows();
  return real_nanosleep(req, rem);
}

int pthread_join(pthread_t thread, void **retval) {
  pthread_once(&once, init);
  if (on_main_thread() && real_timedjoin) {
    struct timespec until = deadline(CLOCK_REALTIME);
    int r = real_timedjoin(thread, retval, &until);
    if (r != ETIMEDOUT)
      return r;
    hide_closing_windows();
  }
  return real_pthread_join(thread, retval);
}

int sem_wait(sem_t *sem) {
  pthread_once(&once, init);
  if (on_main_thread() && real_sem_timedwait) {
    struct timespec until = deadline(CLOCK_REALTIME);
    int r = real_sem_timedwait(sem, &until);
    if (r == 0 || errno != ETIMEDOUT)
      return r;
    hide_closing_windows();
  }
  return real_sem_wait(sem);
}
