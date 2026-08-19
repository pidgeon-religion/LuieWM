local ffi = require("ffi")

ffi.cdef[[
/* ---- wayland-util.h ---- */
struct wl_list {
    struct wl_list *prev;
    struct wl_list *next;
};

/* ---- wayland-server-core.h ---- */
struct wl_client;
struct wl_display;
struct wl_global;
struct wl_protocol_log;
struct wl_resource;
struct wl_event_loop;
struct wl_event_source;
struct wl_shm_buffer;
struct wl_shm;

typedef void (*wl_notify_func_t)(struct wl_listener *listener, void *data);

struct wl_listener {
    struct wl_list link;
    wl_notify_func_t notify;
};

struct wl_signal {
    struct wl_list listener_list;
};

/* wl_list functions */
void wl_list_init(struct wl_list *list);
/* wl_list functions - these are real symbols in libwayland-server */
void wl_list_init(struct wl_list *list);
void wl_list_insert(struct wl_list *list, struct wl_list *elm);
void wl_list_remove(struct wl_list *elm);
int wl_list_empty(const struct wl_list *list);

/* wl_signal_init and wl_signal_add are static inline in the header,
   so we implement them in util/ffi_helpers.lua instead */

/* wl_display functions */
struct wl_display *wl_display_create(void);
void wl_display_destroy(struct wl_display *display);
void wl_display_run(struct wl_display *display);
void wl_display_terminate(struct wl_display *display);
const char *wl_display_add_socket_auto(struct wl_display *display);
void wl_display_destroy_clients(struct wl_display *display);
uint32_t wl_display_next_serial(struct wl_display *display);
void wl_display_flush_clients(struct wl_display *display);
struct wl_event_loop *wl_display_get_event_loop(struct wl_display *display);

/* wl_event_loop functions */
struct wl_event_loop *wl_event_loop_create(void);
void wl_event_loop_destroy(struct wl_event_loop *loop);
int wl_event_loop_dispatch(struct wl_event_loop *loop, int timeout);
struct wl_event_source *wl_event_loop_add_fd(struct wl_event_loop *loop,
    int fd, uint32_t mask, wl_notify_func_t func, void *data);

/* wl_global functions */
void wl_global_destroy(struct wl_global *global);

/* wl_fixed_t */
typedef int32_t wl_fixed_t;
]]

local C = ffi.C

local M = {}

M.C = C

function M.display_create()
    return C.wl_display_create()
end

function M.display_destroy(display)
    C.wl_display_destroy(display)
end

function M.display_run(display)
    C.wl_display_run(display)
end

function M.display_add_socket_auto(display)
    return C.wl_display_add_socket_auto(display)
end

function M.display_destroy_clients(display)
    C.wl_display_destroy_clients(display)
end

function M.display_next_serial(display)
    return C.wl_display_next_serial(display)
end

function M.display_flush_clients(display)
    C.wl_display_flush_clients(display)
end

function M.display_get_event_loop(display)
    return C.wl_display_get_event_loop(display)
end

function M.list_init(list)
    C.wl_list_init(list)
end

function M.list_empty(list)
    return C.wl_list_empty(list) ~= 0
end

return M
