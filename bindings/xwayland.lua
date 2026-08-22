local ffi = require("ffi")

ffi.cdef[[
// wlr/xwayland/server.h
struct wlr_xwayland_server_options {
    bool lazy;
    bool enable_wm;
    bool no_touch_pointer_emulation;
    bool force_xrandr_emulation;
    int terminate_delay;
};

// wlr/xwayland/xwayland.h
enum wlr_xwayland_surface_decorations {
    WLR_XWAYLAND_SURFACE_DECORATIONS_ALL = 0,
    WLR_XWAYLAND_SURFACE_DECORATIONS_NO_BORDER = 1,
    WLR_XWAYLAND_SURFACE_DECORATIONS_NO_TITLE = 2,
};

enum wlr_xwayland_net_wm_window_type {
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DESKTOP = 0,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DOCK,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLBAR,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_MENU,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_UTILITY,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DIALOG,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_POPUP_MENU,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLTIP,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_NOTIFICATION,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_COMBO,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DND,
    WLR_XWAYLAND_NET_WM_WINDOW_TYPE_NORMAL,
};

struct wlr_addon {
    const void *impl;
    const void *owner;
    struct wl_list link;
};

struct wlr_xwayland_surface_configure_event {
    struct wlr_xwayland_surface *surface;
    int16_t x, y;
    uint16_t width, height;
    uint16_t mask;
};

struct wlr_xwayland_resize_event {
    struct wlr_xwayland_surface *surface;
    uint32_t edges;
};

struct wlr_xwayland {
    struct wlr_xwayland_server *server;
    bool own_server;
    void *xwm;
    void *shell_v1;
    const char *display_name;
    struct wl_display *wl_display;
    struct wlr_compositor *compositor;
    struct wlr_seat *seat;
    struct {
        struct wl_signal destroy;
        struct wl_signal ready;
        struct wl_signal new_surface;
        struct wl_signal remove_startup_info;
    } events;
    void *data;
};

struct wlr_xwayland_surface {
    uint32_t window_id;
    void *xwm;
    uint32_t surface_id;
    uint64_t serial;

    struct wl_list link;
    struct wl_list stack_link;
    struct wl_list unpaired_link;

    struct wlr_surface *surface;
    struct wlr_addon surface_addon;

    int16_t x, y;
    uint16_t width, height;
    bool override_redirect;
    float opacity;

    char *title;
    char *class;
    char *instance;
    char *role;
    char *startup_id;
    int32_t pid;

    struct wl_list children;
    struct wlr_xwayland_surface *parent;
    struct wl_list parent_link;

    uint32_t *window_type;
    size_t window_type_len;

    uint32_t *protocols;
    size_t protocols_len;

    uint32_t decorations;
    void *hints;
    void *size_hints;
    void *strut_partial;

    bool pinging;
    void *ping_timer;

    bool modal;
    bool fullscreen;
    bool maximized_vert, maximized_horz;
    bool minimized;
    bool withdrawn;
    bool sticky;
    bool shaded;
    bool skip_taskbar;
    bool skip_pager;
    bool above;
    bool below;
    bool demands_attention;

    bool has_alpha;

    struct {
        struct wl_signal destroy;
        struct wl_signal request_configure;
        struct wl_signal request_move;
        struct wl_signal request_resize;
        struct wl_signal request_minimize;
        struct wl_signal request_maximize;
        struct wl_signal request_fullscreen;
        struct wl_signal request_activate;
        struct wl_signal request_close;
        struct wl_signal request_sticky;
        struct wl_signal request_shaded;
        struct wl_signal request_skip_taskbar;
        struct wl_signal request_skip_pager;
        struct wl_signal request_above;
        struct wl_signal request_below;
        struct wl_signal request_demands_attention;

        struct wl_signal associate;
        struct wl_signal dissociate;

        struct wl_signal set_title;
        struct wl_signal set_class;
        struct wl_signal set_role;
        struct wl_signal set_parent;
        struct wl_signal set_startup_id;
        struct wl_signal set_window_type;
        struct wl_signal set_hints;
        struct wl_signal set_size_hints;
        struct wl_signal set_decorations;
        struct wl_signal set_strut_partial;
        struct wl_signal set_override_redirect;
        struct wl_signal set_geometry;
        struct wl_signal set_opacity;
        struct wl_signal set_icon;
        struct wl_signal focus_in;
        struct wl_signal grab_focus;
        struct wl_signal map_request;
        struct wl_signal ping_timeout;
    } events;

    void *data;

    struct {
        char *wm_name, *net_wm_name;
        struct wl_listener surface_commit;
        struct wl_listener surface_map;
        struct wl_listener surface_unmap;
    } WLR_PRIVATE;
};

struct wlr_xwayland *wlr_xwayland_create(struct wl_display *wl_display,
    struct wlr_compositor *compositor, bool lazy);
void wlr_xwayland_destroy(struct wlr_xwayland *wlr_xwayland);
void wlr_xwayland_set_cursor(struct wlr_xwayland *wlr_xwayland,
    struct wlr_buffer *buffer, int32_t hotspot_x, int32_t hotspot_y);
void wlr_xwayland_set_seat(struct wlr_xwayland *xwayland, struct wlr_seat *seat);
void wlr_xwayland_surface_activate(struct wlr_xwayland_surface *surface, bool activated);
void wlr_xwayland_surface_configure(struct wlr_xwayland_surface *surface,
    int16_t x, int16_t y, uint16_t width, uint16_t height);
void wlr_xwayland_surface_close(struct wlr_xwayland_surface *surface);
void wlr_xwayland_surface_set_fullscreen(struct wlr_xwayland_surface *surface, bool fullscreen);
bool wlr_xwayland_surface_has_window_type(const struct wlr_xwayland_surface *xsurface,
    uint32_t window_type);
]]

return {}
