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
 *    Прежняя геометрия запоминается перед первым показом окна и по каждому
 *    ConfigureNotify, в том числе забранному через XIfEvent и подобные.
 *
 * 2. Долгое закрытие (только с ONEC_X11_FAST_CLOSE=1: обход держится на
 *    эвристике по времени). После WM_DELETE_WINDOW 1С до ~1 с ждёт
 *    остановки своих потоков (семафор) и ещё спит 1,5 с, не убирая окно.
 *    Если после запроса на закрытие главный поток надолго заблокировался
 *    (sem_wait/sem_timedwait/sem_clockwait и pthread_join дольше 150 мс,
 *    nanosleep/clock_nanosleep от секунды), окно снимается с экрана (по
 *    ICCCM, как XWithdrawWindow); процесс завершается как обычно. Короткие
 *    ожидания не в счёт: перед вопросом «Сохранить изменения?» 1С тоже
 *    ждёт семафор. Показ любого окна, фокус или ввод после запроса
 *    отменяют ожидание закрытия: лучше не ускорить закрытие с вопросом,
 *    чем спрятать живое окно. Окно, которое 1С спрятала или уничтожила
 *    сама, из ожидания убирается. Если окно всё же спрятано, а 1С
 *    показала новое окно или получила ввод, спрятанные окна возвращаются
 *    с прежним _NET_WM_STATE (fullscreen, развёрнуто); место в раскладке
 *    тайлового WM может смениться.
 *    Не перехватываются: sleep/usleep (glibc зовёт clock_nanosleep в
 *    обход PLT) и условные переменные (версионные символы, ими ждут все
 *    пулы потоков). Если 1С начнёт ждать так, обход молча перестанет
 *    срабатывать — окно закроется с обычной задержкой.
 *
 * 3. Пустое окно рядом с диалогом. Модальному диалогу 1С назначает
 *    родителя — невидимый диалог 1×1 (min = max = 1×1, без рамки). Hyprland
 *    подсказки размера такого окна не учитывает и показывает его 800×800.
 *    Перед показом такому окну ставится override-redirect: WM им не
 *    управляет, и оно остаётся пикселем в углу, как задумано.
 *
 * Обход 2 снимает и возвращает окна через отдельное соединение libxcb (она
 * уже загружена как зависимость libX11): ошибки по нему (BadWindow, если
 * окно уже уничтожено) возвращаются нам и не попадают в обработчик ошибок
 * Xlib, который по умолчанию завершил бы процесс. Соединение открывается
 * только с ONEC_X11_FAST_CLOSE=1, при первом закрытии окна.
 *
 * Работает только в процессах 1С (по имени программы): LD_PRELOAD
 * наследуют и дочерние процессы — браузер, открытый из 1С, и т.п.
 * Отключить: ONEC_NO_X11_FIXES=1.
 */
#define _GNU_SOURCE
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <xcb/xcb.h>

#define EXPORT __attribute__((visibility("default")))

#define GEOMETRY_SLOTS 64
#define CLOSING_SLOTS 8
#define STATE_ATOMS 16
#define NS_PER_S 1000000000LL
#define CLOSING_TTL_NS (10 * NS_PER_S)
#define BLOCKED_NS (150LL * 1000000LL)

/* Типы событий XInput2 (X11/extensions/XI2.h): GTK3 получает ввод и фокус
 * через них, а не через KeyPress/ButtonPress/FocusIn. */
#define XI2_KEY_PRESS 2
#define XI2_BUTTON_PRESS 4
#define XI2_FOCUS_IN 9
#define XI2_TOUCH_BEGIN 18

/* Настоящая функция — с типом из заголовка. */
#define REAL(name) static __typeof__(name) *real_##name
#define RESOLVE(lib, name) real_##name = (__typeof__(real_##name))find(lib, #name)

REAL(XNextEvent);
REAL(XIfEvent);
REAL(XCheckIfEvent);
REAL(XWindowEvent);
REAL(XCheckWindowEvent);
REAL(XMaskEvent);
REAL(XCheckMaskEvent);
REAL(XCheckTypedEvent);
REAL(XCheckTypedWindowEvent);
REAL(XPutBackEvent);
REAL(XInternAtom);
REAL(XQueryExtension);
REAL(XMapWindow);
REAL(XMapRaised);
REAL(XUnmapWindow);
REAL(XWithdrawWindow);
REAL(XGetGeometry);
REAL(XGetWMNormalHints);
REAL(XGetWindowProperty);
REAL(XChangeWindowAttributes);
REAL(XFree);

REAL(xcb_connect);
REAL(xcb_connection_has_error);
REAL(xcb_disconnect);
REAL(xcb_poll_for_event);
REAL(xcb_request_check);
REAL(xcb_get_geometry);
REAL(xcb_get_geometry_reply);
REAL(xcb_intern_atom);
REAL(xcb_intern_atom_reply);
REAL(xcb_get_property);
REAL(xcb_get_property_reply);
REAL(xcb_get_property_value);
REAL(xcb_get_property_value_length);
REAL(xcb_change_property_checked);
REAL(xcb_map_window_checked);
REAL(xcb_unmap_window_checked);
REAL(xcb_send_event_checked);

REAL(nanosleep);
REAL(clock_nanosleep);
REAL(pthread_join);
REAL(pthread_clockjoin_np);
REAL(sem_wait);
REAL(sem_timedwait);
REAL(sem_clockwait);

static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t x11_lock = PTHREAD_MUTEX_INITIALIZER;
static int x11_ready, have_xcb;
static int disabled, fast_close;

/* Те же имена, что в обёртке (pkgs/onec/default.nix). */
static int is_onec_program(void) {
  static const char *const names[] = {"1cv8",  "1cv8c",  "1cestart",
                                      "1cv8t", "1cv8ct", "1cestartt"};
  for (unsigned i = 0; i < sizeof names / sizeof *names; i++)
    if (strcmp(program_invocation_short_name, names[i]) == 0)
      return 1;
  return 0;
}

static int env_is_1(const char *name) {
  const char *v = getenv(name);
  return v && strcmp(v, "1") == 0;
}

/* lib == NULL — только RTLD_NEXT. Иначе библиотека могла появиться в
 * процессе позже нас (dlopen) или без RTLD_GLOBAL — тогда RTLD_NEXT её
 * не видит. */
static void *find(const char *lib, const char *name) {
  void *f = dlsym(RTLD_NEXT, name);
  if (!f && lib) {
    void *h = dlopen(lib, RTLD_LAZY | RTLD_NOLOAD);
    if (h) {
      f = dlsym(h, name);
      dlclose(h);
    }
  }
  return f;
}

static void init(void) {
  RESOLVE(NULL, nanosleep);
  RESOLVE(NULL, clock_nanosleep);
  RESOLVE(NULL, pthread_join);
  RESOLVE(NULL, pthread_clockjoin_np);
  RESOLVE(NULL, sem_wait);
  RESOLVE(NULL, sem_timedwait);
  RESOLVE(NULL, sem_clockwait);
  disabled = env_is_1("ONEC_NO_X11_FIXES") || !is_onec_program();
  fast_close = env_is_1("ONEC_X11_FAST_CLOSE");
}

__attribute__((constructor)) static void setup(void) {
  pthread_once(&once, init);
}

/* Функции Xlib и xcb ищутся при первом перехвате из Xlib: раз он вызван,
 * libX11 (а с ней libxcb) уже загружена. */
static void prepare_x11(void) {
  pthread_once(&once, init);
  if (__atomic_load_n(&x11_ready, __ATOMIC_ACQUIRE))
    return;
  pthread_mutex_lock(&x11_lock);
  if (!x11_ready) {
    const char *x = "libX11.so.6", *xcb = "libxcb.so.1";
    RESOLVE(x, XNextEvent);
    RESOLVE(x, XIfEvent);
    RESOLVE(x, XCheckIfEvent);
    RESOLVE(x, XWindowEvent);
    RESOLVE(x, XCheckWindowEvent);
    RESOLVE(x, XMaskEvent);
    RESOLVE(x, XCheckMaskEvent);
    RESOLVE(x, XCheckTypedEvent);
    RESOLVE(x, XCheckTypedWindowEvent);
    RESOLVE(x, XPutBackEvent);
    RESOLVE(x, XInternAtom);
    RESOLVE(x, XQueryExtension);
    RESOLVE(x, XMapWindow);
    RESOLVE(x, XMapRaised);
    RESOLVE(x, XUnmapWindow);
    RESOLVE(x, XWithdrawWindow);
    RESOLVE(x, XGetGeometry);
    RESOLVE(x, XGetWMNormalHints);
    RESOLVE(x, XGetWindowProperty);
    RESOLVE(x, XChangeWindowAttributes);
    RESOLVE(x, XFree);
    RESOLVE(xcb, xcb_connect);
    RESOLVE(xcb, xcb_connection_has_error);
    RESOLVE(xcb, xcb_disconnect);
    RESOLVE(xcb, xcb_poll_for_event);
    RESOLVE(xcb, xcb_request_check);
    RESOLVE(xcb, xcb_get_geometry);
    RESOLVE(xcb, xcb_get_geometry_reply);
    RESOLVE(xcb, xcb_intern_atom);
    RESOLVE(xcb, xcb_intern_atom_reply);
    RESOLVE(xcb, xcb_get_property);
    RESOLVE(xcb, xcb_get_property_reply);
    RESOLVE(xcb, xcb_get_property_value);
    RESOLVE(xcb, xcb_get_property_value_length);
    RESOLVE(xcb, xcb_change_property_checked);
    RESOLVE(xcb, xcb_map_window_checked);
    RESOLVE(xcb, xcb_unmap_window_checked);
    RESOLVE(xcb, xcb_send_event_checked);
    have_xcb =
        real_xcb_connect && real_xcb_connection_has_error &&
        real_xcb_disconnect && real_xcb_poll_for_event &&
        real_xcb_request_check && real_xcb_get_geometry &&
        real_xcb_get_geometry_reply && real_xcb_intern_atom &&
        real_xcb_intern_atom_reply && real_xcb_get_property &&
        real_xcb_get_property_reply && real_xcb_get_property_value &&
        real_xcb_get_property_value_length && real_xcb_change_property_checked &&
        real_xcb_map_window_checked && real_xcb_unmap_window_checked &&
        real_xcb_send_event_checked;
    if (real_XNextEvent)
      __atomic_store_n(&x11_ready, 1, __ATOMIC_RELEASE);
  }
  pthread_mutex_unlock(&x11_lock);
}

static long long now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * NS_PER_S + ts.tv_nsec;
}

/* a < b. Сроки от приложения не переводятся в наносекунды: «навсегда»
 * ({LONG_MAX, …}) переполнило бы long long. */
static int ts_before(const struct timespec *a, const struct timespec *b) {
  return a->tv_sec != b->tv_sec ? a->tv_sec < b->tv_sec
                                : a->tv_nsec < b->tv_nsec;
}

/* --- Своё соединение с X-сервером ---------------------------------------- */

static pthread_mutex_t own_lock = PTHREAD_MUTEX_INITIALIZER;
static xcb_connection_t *own;
static char display_name[256];
static xcb_atom_t net_wm_state;

static void remember_display(Display *dpy) {
  pthread_mutex_lock(&own_lock);
  if (!display_name[0] && DisplayString(dpy))
    strncpy(display_name, DisplayString(dpy), sizeof display_name - 1);
  pthread_mutex_unlock(&own_lock);
}

/* Под own_lock. Событий соединение не заказывает, но MappingNotify и
 * т.п. сервер шлёт всем — их выбрасываем, чтобы не копились. */
static xcb_connection_t *own_connection(void) {
  if (!have_xcb || !display_name[0])
    return NULL;
  if (own && real_xcb_connection_has_error(own)) {
    real_xcb_disconnect(own);
    own = NULL;
  }
  if (!own) {
    own = real_xcb_connect(display_name, NULL);
    if (real_xcb_connection_has_error(own)) {
      real_xcb_disconnect(own);
      own = NULL;
      return NULL;
    }
    const char *name = "_NET_WM_STATE";
    xcb_intern_atom_reply_t *a = real_xcb_intern_atom_reply(
        own, real_xcb_intern_atom(own, 0, (uint16_t)strlen(name), name), NULL);
    if (a)
      net_wm_state = a->atom;
    free(a);
  }
  for (xcb_generic_event_t *e; (e = real_xcb_poll_for_event(own));)
    free(e);
  return own;
}

/* Запрос без ответа с ожиданием результата: ошибка достаётся нам. */
static void check(xcb_connection_t *c, xcb_void_cookie_t cookie) {
  free(real_xcb_request_check(c, cookie));
}

/* --- 1. Деление ConfigureNotify ---------------------------------------- */

struct geometry {
  Window window;
  int x, y, width, height;
  /* Геометрия запрошена у сервера этим запросом (не 0) и ещё не обновлялась
   * по событиям: события старше него с ней не сравниваются. */
  unsigned long serial;
};

static struct geometry geometries[GEOMETRY_SLOTS];
static unsigned next_geometry;

static struct geometry *find_geometry(Window w) {
  for (unsigned i = 0; i < GEOMETRY_SLOTS; i++)
    if (geometries[i].window == w)
      return &geometries[i];
  return NULL;
}

/* Под lock: место для окна, которого ещё нет в кэше. */
static struct geometry *new_geometry(Window w) {
  struct geometry *g = find_geometry(0);
  if (!g)
    g = &geometries[next_geometry++ % GEOMETRY_SLOTS];
  *g = (struct geometry){.window = w};
  return g;
}

/* Без lock, перед первым показом окна: запомнить геометрию, чтобы первое
 * же изменение (WM расставляет окно) тоже делилось. Запрос — по соединению
 * приложения и до запроса на показ, поэтому ответ старше любой реакции WM
 * на показ. */
static void seed_geometry(Display *dpy, Window w) {
  pthread_mutex_lock(&lock);
  int known = find_geometry(w) != NULL;
  pthread_mutex_unlock(&lock);
  if (known || !real_XGetGeometry)
    return;
  unsigned long serial = NextRequest(dpy);
  Window root;
  int x, y;
  unsigned width, height, border, depth;
  if (!real_XGetGeometry(dpy, w, &root, &x, &y, &width, &height, &border,
                         &depth))
    return;
  pthread_mutex_lock(&lock);
  if (!find_geometry(w)) {
    struct geometry *g = new_geometry(w);
    g->x = x;
    g->y = y;
    g->width = (int)width;
    g->height = (int)height;
    g->serial = serial;
  }
  pthread_mutex_unlock(&lock);
}

/* Под lock. may_split = 0 — событие забрали не через XNextEvent: только
 * запомнить геометрию. */
static void note_configure(Display *dpy, XEvent *ev, int may_split) {
  XConfigureEvent *c = &ev->xconfigure;
  struct geometry *g = find_geometry(c->window);
  if (!g) {
    g = new_geometry(c->window);
  } else if (may_split && c->serial >= g->serial &&
             (c->x != g->x || c->y != g->y) &&
             (c->width != g->width || c->height != g->height) &&
             real_XPutBackEvent) {
    /* Не наоборот (размер, потом позиция): позицию настоящего события
     * GDK не берёт из него, а спрашивает у сервера — она уже новая. */
    XEvent resized = *ev;
    real_XPutBackEvent(dpy, &resized);
    c->width = g->width;
    c->height = g->height;
  }
  g->x = c->x;
  g->y = c->y;
  g->width = c->width;
  g->height = c->height;
  g->serial = 0;
}

/* --- 2. Быстрое скрытие закрываемых окон -------------------------------- */

struct closing_window {
  Window window;
  long long since;
};

struct hidden_window {
  Window window;
  unsigned n_state;
  uint32_t state[STATE_ATOMS]; /* _NET_WM_STATE до скрытия */
};

static struct closing_window closing[CLOSING_SLOTS];
static struct hidden_window hidden[CLOSING_SLOTS];
static unsigned hidden_count;
/* Есть ли что-то в closing и hidden: читаются без lock. */
static int closing_pending, hidden_pending;
static Atom wm_protocols, wm_delete_window;
static int xi_opcode = -1; /* -1 — ещё не спрашивали, 0 — XInput нет */

/* Под lock, после каждого изменения closing и hidden. */
static void sync_pending(void) {
  int any = 0;
  for (unsigned i = 0; i < CLOSING_SLOTS; i++)
    any |= closing[i].window != 0;
  __atomic_store_n(&closing_pending, any, __ATOMIC_RELEASE);
  __atomic_store_n(&hidden_pending, hidden_count != 0, __ATOMIC_RELEASE);
}

static struct closing_window *closing_slot(Window w) {
  struct closing_window *free_slot = NULL, *oldest = &closing[0];
  for (unsigned i = 0; i < CLOSING_SLOTS; i++) {
    if (closing[i].window == w)
      return &closing[i];
    if (!closing[i].window && !free_slot)
      free_slot = &closing[i];
    if (closing[i].since < oldest->since)
      oldest = &closing[i];
  }
  return free_slot ? free_slot : oldest;
}

static void drop_closing(Window w) {
  for (unsigned i = 0; i < CLOSING_SLOTS; i++)
    if (closing[i].window == w)
      closing[i] = (struct closing_window){0};
}

static void drop_hidden(Window w) {
  unsigned kept = 0;
  for (unsigned i = 0; i < hidden_count; i++)
    if (hidden[i].window != w)
      hidden[kept++] = hidden[i];
  hidden_count = kept;
}

/* Под lock. */
static void note_close_request(Display *dpy, XEvent *ev) {
  if (!wm_protocols && real_XInternAtom) {
    wm_protocols = real_XInternAtom(dpy, "WM_PROTOCOLS", True);
    wm_delete_window = real_XInternAtom(dpy, "WM_DELETE_WINDOW", True);
  }
  XClientMessageEvent *m = &ev->xclient;
  if (!wm_protocols || m->message_type != wm_protocols || m->format != 32 ||
      (Atom)m->data.l[0] != wm_delete_window)
    return;
  struct closing_window *slot = closing_slot(m->window);
  slot->window = m->window;
  slot->since = now_ns();
  sync_pending();
}

/* Под lock. */
static int is_xi2_activity(Display *dpy, XEvent *ev) {
  if (xi_opcode < 0) {
    int opcode, event, error;
    xi_opcode = real_XQueryExtension &&
                        real_XQueryExtension(dpy, "XInputExtension", &opcode,
                                             &event, &error)
                    ? opcode
                    : 0;
  }
  XGenericEventCookie *c = &ev->xcookie;
  return xi_opcode && c->extension == xi_opcode &&
         (c->evtype == XI2_KEY_PRESS || c->evtype == XI2_BUTTON_PRESS ||
          c->evtype == XI2_FOCUS_IN || c->evtype == XI2_TOUCH_BEGIN);
}

/* Под lock: 1С жива и показывает новое окно (вопрос перед закрытием),
 * получила фокус или ввод — значит, закрытие отменено или ждёт ответа.
 * Возвращает окна, которые надо показать снова. */
static unsigned note_activity(XEvent *ev, struct hidden_window *show) {
  memset(closing, 0, sizeof closing);
  unsigned n = 0;
  /* Фокус приходит и при завершении — по нему окна не возвращаем. */
  int focus = ev->type == FocusIn ||
              (ev->type == GenericEvent && ev->xcookie.evtype == XI2_FOCUS_IN);
  /* 1С сама показала спрятанное окно: оно больше не наше — не возвращать
   * его (и не переписывать _NET_WM_STATE показанного окна), остальные не
   * трогать. */
  int own_map = 0;
  if (ev->type == MapNotify) {
    unsigned before = hidden_count;
    drop_hidden(ev->xmap.window);
    own_map = hidden_count != before;
  }
  if (!focus && !own_map) {
    n = hidden_count;
    memcpy(show, hidden, n * sizeof *hidden);
    hidden_count = 0;
  }
  sync_pending();
  return n;
}

/* Под lock: окно уничтожено, его идентификатор X-сервер выдаст снова. */
static void forget_window(Window w) {
  struct geometry *g = find_geometry(w);
  if (g)
    g->window = 0;
  drop_closing(w);
  drop_hidden(w);
  sync_pending();
}

/* Под own_lock. Снять окно с экрана по ICCCM 4.1.4 (как XWithdrawWindow),
 * запомнив _NET_WM_STATE: WM удалит его при снятии. */
static int withdraw(xcb_connection_t *c, Window w, struct hidden_window *h) {
  xcb_window_t id = (xcb_window_t)w; /* XID — 29 бит */
  xcb_get_geometry_reply_t *g =
      real_xcb_get_geometry_reply(c, real_xcb_get_geometry(c, id), NULL);
  if (!g)
    return 0; /* окна уже нет */
  xcb_window_t root = g->root;
  free(g);

  h->window = w;
  h->n_state = 0;
  if (net_wm_state) {
    xcb_get_property_reply_t *p = real_xcb_get_property_reply(
        c,
        real_xcb_get_property(c, 0, id, net_wm_state, XCB_ATOM_ATOM, 0,
                              STATE_ATOMS),
        NULL);
    if (p && p->format == 32 && p->type == XCB_ATOM_ATOM) {
      h->n_state = real_xcb_get_property_value_length(p) / 4;
      if (h->n_state > STATE_ATOMS)
        h->n_state = STATE_ATOMS;
      memcpy(h->state, real_xcb_get_property_value(p), h->n_state * 4);
    }
    free(p);
  }

  check(c, real_xcb_unmap_window_checked(c, id));
  xcb_unmap_notify_event_t unmap = {
      .response_type = XCB_UNMAP_NOTIFY, .event = root, .window = id};
  char event[32] = {0};
  memcpy(event, &unmap, sizeof unmap);
  check(c, real_xcb_send_event_checked(
               c, 0, root,
               XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                   XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
               event));
  return 1;
}

/* Без lock. */
static void restore_windows(const struct hidden_window *show, unsigned n) {
  if (!n)
    return;
  pthread_mutex_lock(&own_lock);
  xcb_connection_t *c = own_connection();
  for (unsigned i = 0; c && i < n; i++) {
    xcb_window_t id = (xcb_window_t)show[i].window;
    /* До показа клиент может задать _NET_WM_STATE сам (EWMH). */
    if (show[i].n_state && net_wm_state)
      check(c, real_xcb_change_property_checked(
                   c, XCB_PROP_MODE_REPLACE, id, net_wm_state, XCB_ATOM_ATOM,
                   32, show[i].n_state, show[i].state));
    check(c, real_xcb_map_window_checked(c, id));
  }
  pthread_mutex_unlock(&own_lock);
}

/* Главный поток заблокировался надолго: убрать закрываемые окна. */
static void hide_closing_windows(void) {
  /* trylock: nanosleep могут вызвать из обработчика сигнала, прервавшего
   * этот же поток с захваченной блокировкой. Тогда просто не прячем. */
  if (pthread_mutex_trylock(&own_lock))
    return;
  if (pthread_mutex_trylock(&lock)) {
    pthread_mutex_unlock(&own_lock);
    return;
  }
  long long now = now_ns();
  Window windows[CLOSING_SLOTS];
  unsigned n = 0;
  for (unsigned i = 0; i < CLOSING_SLOTS; i++) {
    if (closing[i].window && now - closing[i].since < CLOSING_TTL_NS)
      windows[n++] = closing[i].window;
    closing[i] = (struct closing_window){0};
  }
  sync_pending();
  pthread_mutex_unlock(&lock);

  struct hidden_window done[CLOSING_SLOTS];
  unsigned m = 0;
  xcb_connection_t *c = n ? own_connection() : NULL;
  for (unsigned i = 0; c && i < n; i++)
    m += withdraw(c, windows[i], &done[m]);
  pthread_mutex_unlock(&own_lock);

  pthread_mutex_lock(&lock);
  for (unsigned i = 0; i < m; i++) {
    drop_hidden(done[i].window);
    if (hidden_count < CLOSING_SLOTS)
      hidden[hidden_count++] = done[i];
  }
  sync_pending();
  pthread_mutex_unlock(&lock);
}

/* Приложение само прячет окно: не ждать его закрытия и не возвращать. */
static void app_hides(Window w) {
  if (disabled || !fast_close ||
      !(__atomic_load_n(&closing_pending, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&hidden_pending, __ATOMIC_ACQUIRE)))
    return;
  pthread_mutex_lock(&lock);
  drop_closing(w);
  drop_hidden(w);
  sync_pending();
  pthread_mutex_unlock(&lock);
}

/* Закрытие ждёт, обход включён, и это главный поток. */
static int should_watch_blocking(void) {
  return __atomic_load_n(&closing_pending, __ATOMIC_ACQUIRE) && fast_close &&
         !disabled && syscall(SYS_gettid) == getpid();
}

static struct timespec after_ns(clockid_t clock, long long ns) {
  struct timespec ts;
  clock_gettime(clock, &ts);
  ns += ts.tv_nsec;
  ts.tv_sec += ns / NS_PER_S;
  ts.tv_nsec = ns % NS_PER_S;
  return ts;
}

static int ts_valid(const struct timespec *ts) {
  return ts->tv_nsec >= 0 && ts->tv_nsec < NS_PER_S;
}

/* Ждать семафор; если ждать приходится дольше BLOCKED_NS — спрятать
 * закрываемые окна. until — абсолютный срок по clock, NULL — без срока. */
static int watched_sem_wait(sem_t *sem, clockid_t clock,
                            const struct timespec *until) {
  struct timespec bound = after_ns(clock, BLOCKED_NS);
  int capped = !until || ts_before(&bound, until);
  int r = real_sem_clockwait(sem, clock, capped ? &bound : until);
  if (r == 0 || errno != ETIMEDOUT || !capped)
    return r;
  hide_closing_windows();
  return until ? real_sem_clockwait(sem, clock, until) : real_sem_wait(sem);
}

/* --- 3. Невидимый родитель модальных диалогов -------------------------- */

static int is_dialog(Display *dpy, Window w) {
  Atom type = real_XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", True);
  Atom dialog = real_XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", True);
  if (!type || !dialog)
    return 0;
  Atom actual;
  int format;
  unsigned long n, after;
  unsigned char *data = NULL;
  int found = 0;
  if (real_XGetWindowProperty(dpy, w, type, 0, 8, False, XA_ATOM, &actual,
                              &format, &n, &after, &data) == Success &&
      data && format == 32)
    for (unsigned long i = 0; i < n; i++)
      if (((Atom *)data)[i] == dialog)
        found = 1;
  if (data)
    real_XFree(data);
  return found;
}

static int is_modal_parent(Display *dpy, Window w) {
  if (!real_XGetWMNormalHints || !real_XGetWindowProperty ||
      !real_XInternAtom || !real_XChangeWindowAttributes || !real_XFree)
    return 0;
  XSizeHints hints;
  long supplied;
  if (!real_XGetWMNormalHints(dpy, w, &hints, &supplied) ||
      (hints.flags & (PMinSize | PMaxSize)) != (PMinSize | PMaxSize) ||
      hints.min_width != 1 || hints.min_height != 1 ||
      hints.max_width != 1 || hints.max_height != 1)
    return 0;
  return is_dialog(dpy, w);
}

static void before_map(Display *dpy, Window w) {
  prepare_x11();
  if (disabled)
    return;
  seed_geometry(dpy, w);
  if (is_modal_parent(dpy, w)) {
    XSetWindowAttributes attrs = {.override_redirect = True};
    real_XChangeWindowAttributes(dpy, w, CWOverrideRedirect, &attrs);
  }
}

/* --- Разбор событий ------------------------------------------------------ */

/* После каждого полученного события; may_split — только из XNextEvent.
 * Неинтересные типы (MotionNotify, Expose…) отсеиваются без lock. */
static void after_event(Display *dpy, XEvent *ev, int may_split) {
  if (disabled)
    return;
  switch (ev->type) {
  case ConfigureNotify:
    /* Копии для подписчиков SubstructureNotify родителя и синтетические
     * события от WM (координаты от корня) GDK не использует. */
    if (ev->xconfigure.event != ev->xconfigure.window ||
        ev->xconfigure.send_event)
      return;
    pthread_mutex_lock(&lock);
    note_configure(dpy, ev, may_split);
    pthread_mutex_unlock(&lock);
    return;
  case DestroyNotify:
    pthread_mutex_lock(&lock);
    forget_window(ev->xdestroywindow.window);
    pthread_mutex_unlock(&lock);
    return;
  case UnmapNotify:
    /* Окно из ожидания закрытия убрала сама 1С (наше снятие окна идёт
     * уже после того, как оно ушло из closing). */
    if (ev->xunmap.event == ev->xunmap.window &&
        __atomic_load_n(&closing_pending, __ATOMIC_ACQUIRE)) {
      pthread_mutex_lock(&lock);
      drop_closing(ev->xunmap.window);
      sync_pending();
      pthread_mutex_unlock(&lock);
    }
    return;
  case ClientMessage:
    if (fast_close) {
      remember_display(dpy);
      pthread_mutex_lock(&lock);
      note_close_request(dpy, ev);
      pthread_mutex_unlock(&lock);
    }
    return;
  case MapNotify:
  case GenericEvent:
  case FocusIn:
  case KeyPress:
  case ButtonPress:
    break;
  default:
    return;
  }

  if (!fast_close || !(__atomic_load_n(&closing_pending, __ATOMIC_ACQUIRE) ||
                       __atomic_load_n(&hidden_pending, __ATOMIC_ACQUIRE)))
    return;
  struct hidden_window show[CLOSING_SLOTS];
  unsigned n = 0;
  pthread_mutex_lock(&lock);
  if (ev->type != GenericEvent || is_xi2_activity(dpy, ev))
    n = note_activity(ev, show);
  pthread_mutex_unlock(&lock);
  restore_windows(show, n);
}

/* --- Перехваты Xlib ------------------------------------------------------ */

EXPORT int XNextEvent(Display *dpy, XEvent *ev) {
  prepare_x11();
  int r = real_XNextEvent(dpy, ev);
  after_event(dpy, ev, 1);
  return r;
}

/* Остальные способы забрать событие: делить такое событие нельзя (его
 * ждут именно таким), но геометрию и прочее учесть надо. */
EXPORT int XIfEvent(Display *dpy, XEvent *ev,
                    Bool (*pred)(Display *, XEvent *, XPointer), XPointer arg) {
  prepare_x11();
  int r = real_XIfEvent(dpy, ev, pred, arg);
  after_event(dpy, ev, 0);
  return r;
}

EXPORT Bool XCheckIfEvent(Display *dpy, XEvent *ev,
                          Bool (*pred)(Display *, XEvent *, XPointer),
                          XPointer arg) {
  prepare_x11();
  Bool r = real_XCheckIfEvent(dpy, ev, pred, arg);
  if (r)
    after_event(dpy, ev, 0);
  return r;
}

EXPORT int XWindowEvent(Display *dpy, Window w, long mask, XEvent *ev) {
  prepare_x11();
  int r = real_XWindowEvent(dpy, w, mask, ev);
  after_event(dpy, ev, 0);
  return r;
}

EXPORT Bool XCheckWindowEvent(Display *dpy, Window w, long mask, XEvent *ev) {
  prepare_x11();
  Bool r = real_XCheckWindowEvent(dpy, w, mask, ev);
  if (r)
    after_event(dpy, ev, 0);
  return r;
}

EXPORT int XMaskEvent(Display *dpy, long mask, XEvent *ev) {
  prepare_x11();
  int r = real_XMaskEvent(dpy, mask, ev);
  after_event(dpy, ev, 0);
  return r;
}

EXPORT Bool XCheckMaskEvent(Display *dpy, long mask, XEvent *ev) {
  prepare_x11();
  Bool r = real_XCheckMaskEvent(dpy, mask, ev);
  if (r)
    after_event(dpy, ev, 0);
  return r;
}

EXPORT Bool XCheckTypedEvent(Display *dpy, int type, XEvent *ev) {
  prepare_x11();
  Bool r = real_XCheckTypedEvent(dpy, type, ev);
  if (r)
    after_event(dpy, ev, 0);
  return r;
}

EXPORT Bool XCheckTypedWindowEvent(Display *dpy, Window w, int type,
                                   XEvent *ev) {
  prepare_x11();
  Bool r = real_XCheckTypedWindowEvent(dpy, w, type, ev);
  if (r)
    after_event(dpy, ev, 0);
  return r;
}

/* GDK показывает окна через XMapWindow; XMapRaised — на случай, если
 * окно показывает сама 1С. */
EXPORT int XMapWindow(Display *dpy, Window w) {
  before_map(dpy, w);
  return real_XMapWindow(dpy, w);
}

EXPORT int XMapRaised(Display *dpy, Window w) {
  before_map(dpy, w);
  return real_XMapRaised(dpy, w);
}

/* GDK прячет окна через XWithdrawWindow. */
EXPORT int XUnmapWindow(Display *dpy, Window w) {
  prepare_x11();
  app_hides(w);
  return real_XUnmapWindow(dpy, w);
}

EXPORT Status XWithdrawWindow(Display *dpy, Window w, int screen) {
  prepare_x11();
  app_hides(w);
  return real_XWithdrawWindow(dpy, w, screen);
}

/* --- Перехваты ожиданий -------------------------------------------------- */

EXPORT int nanosleep(const struct timespec *req, struct timespec *rem) {
  pthread_once(&once, init);
  if (req && ts_valid(req) && req->tv_sec >= 1 && should_watch_blocking())
    hide_closing_windows();
  return real_nanosleep(req, rem);
}

EXPORT int clock_nanosleep(clockid_t clock, int flags,
                           const struct timespec *req, struct timespec *rem) {
  pthread_once(&once, init);
  if (req && ts_valid(req) && should_watch_blocking()) {
    struct timespec soon = {0, 0};
    if ((flags & TIMER_ABSTIME) && clock_gettime(clock, &soon))
      return real_clock_nanosleep(clock, flags, req, rem);
    soon.tv_sec++; /* сон от секунды */
    if (!ts_before(req, &soon))
      hide_closing_windows();
  }
  return real_clock_nanosleep(clock, flags, req, rem);
}

EXPORT int pthread_join(pthread_t thread, void **retval) {
  pthread_once(&once, init);
  if (real_pthread_clockjoin_np && should_watch_blocking()) {
    struct timespec bound = after_ns(CLOCK_MONOTONIC, BLOCKED_NS);
    int r = real_pthread_clockjoin_np(thread, retval, CLOCK_MONOTONIC, &bound);
    if (r != ETIMEDOUT)
      return r;
    hide_closing_windows();
  }
  return real_pthread_join(thread, retval);
}

EXPORT int sem_wait(sem_t *sem) {
  pthread_once(&once, init);
  if (real_sem_clockwait && should_watch_blocking())
    return watched_sem_wait(sem, CLOCK_MONOTONIC, NULL);
  return real_sem_wait(sem);
}

EXPORT int sem_timedwait(sem_t *sem, const struct timespec *until) {
  pthread_once(&once, init);
  if (real_sem_clockwait && ts_valid(until) && should_watch_blocking())
    return watched_sem_wait(sem, CLOCK_REALTIME, until);
  return real_sem_timedwait(sem, until);
}

EXPORT int sem_clockwait(sem_t *sem, clockid_t clock,
                         const struct timespec *until) {
  pthread_once(&once, init);
  if (!real_sem_clockwait) {
    errno = ENOSYS;
    return -1;
  }
  if (ts_valid(until) &&
      (clock == CLOCK_MONOTONIC || clock == CLOCK_REALTIME) &&
      should_watch_blocking())
    return watched_sem_wait(sem, clock, until);
  return real_sem_clockwait(sem, clock, until);
}
