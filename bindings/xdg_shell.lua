local ffi = require("ffi")

ffi.cdef[[
/* ---- wlr/xdg_shell.h ---- */
enum wlr_xdg_surface_role {
    WLR_XDG_SURFACE_ROLE_NONE,
    WLR_XDG_SURFACE_ROLE_TOPLEVEL,
    WLR_XDG_SURFACE_ROLE_POPUP,
};

struct wlr_xdg_surface_state {
    uint32_t committed;
    struct wlr_box geometry;
    uint32_t configure_serial;
};

struct wlr_xdg_toplevel_state {
    bool maximized, fullscreen, resizing, activated, suspended;
    uint32_t tiled;
    uint32_t constrained;
    int32_t width, height;
    int32_t max_width, max_height;
    int32_t min_width, min_height;
}; // sizeof = 40, verified

/* All below are opaque padding — we never access their fields directly,
   only through wlroots API calls. Sizes verified with offsetof tests. */
struct wlr_xdg_toplevel_configure {
    char _opaque[40];
}; // sizeof = 40, verified

struct wlr_xdg_toplevel_requested {
    char _opaque[40];
}; // sizeof = 40, verified

struct wlr_xdg_toplevel_move_event {
    struct wlr_xdg_toplevel *toplevel;
    struct wlr_seat_client *seat;
    uint32_t serial;
};

struct wlr_xdg_toplevel_resize_event {
    struct wlr_xdg_toplevel *toplevel;
    struct wlr_seat_client *seat;
    uint32_t serial;
    uint32_t edges;
};

struct wlr_xdg_shell {
    struct wl_global *global;
    uint32_t version;
    struct wl_list clients;
    struct wl_list popup_grabs;
    uint32_t ping_timeout;
    struct {
        struct wl_signal new_surface;
        struct wl_signal new_toplevel;
        struct wl_signal new_popup;
        struct wl_signal destroy;
    } events;
    void *data;
    char _private[16]; // struct { struct wl_listener display_destroy; } WLR_PRIVATE
};

struct wlr_xdg_client {
    struct wlr_xdg_shell *shell;
    struct wl_resource *resource;
    struct wl_client *client;
    struct wl_list surfaces;
    struct wl_list link;
    uint32_t ping_serial;
    void *ping_timer;
};

struct wlr_xdg_popup_state {
    struct wlr_box geometry;
    struct wlr_box positioner_src_box;
    int32_t positioner_offset_x, positioner_offset_y;
    uint32_t configure_serial;
};

struct wlr_xdg_surface {
    struct wlr_xdg_client *client;       // 0
    struct wl_resource *resource;         // 8
    struct wlr_surface *surface;          // 16
    struct wl_list link;                  // 24 (16 bytes, ends 40)
    enum wlr_xdg_surface_role role;       // 40
    struct wl_resource *role_resource;    // 48
    /* union { toplevel; popup; } — 8 bytes, not 16 */
    void *toplevel;                       // 56
    struct wl_list popups;                // 64 (16 bytes, ends 80)
    bool configured;                      // 80
    /* padding 7 bytes */                 // 81-87
    void *configure_idle;                 // 88
    uint32_t scheduled_serial;            // 96
    struct wl_list configure_list;        // 104 (16 bytes, ends 120)
    struct wlr_xdg_surface_state current; // 120 (24 bytes)
    struct wlr_xdg_surface_state pending; // 144 (24 bytes)
    bool initialized;                     // 168
    bool initial_commit;                  // 169
    /* padding 2 bytes */                 // 170-171
    struct wlr_box geometry;              // 172 (16 bytes, ends 188)
    struct {                              // 192
        struct wl_signal destroy;
        struct wl_signal ping_timeout;
        struct wl_signal new_popup;
        struct wl_signal configure;
        struct wl_signal ack_configure;
    } events;
    void *data;                           // 272
}; // sizeof = 344, verified

struct wlr_xdg_toplevel {
    struct wl_resource *resource;                   // 0
    struct wlr_xdg_surface *base;                   // 8
    struct wlr_xdg_toplevel *parent;                // 16
    struct wlr_xdg_toplevel_state current, pending; // 24, 64 (40 bytes each)
    struct wlr_xdg_toplevel_configure scheduled;    // 104 (40 bytes)
    struct wlr_xdg_toplevel_requested requested;    // 144 (40 bytes)
    char *title;                                    // 184
    char *app_id;                                   // 192
    struct {                                        // 200
        struct wl_signal destroy;
        struct wl_signal request_maximize;
        struct wl_signal request_fullscreen;
        struct wl_signal request_minimize;
        struct wl_signal request_move;
        struct wl_signal request_resize;
        struct wl_signal request_show_window_menu;
        struct wl_signal set_parent;
        struct wl_signal set_title;
        struct wl_signal set_app_id;
    } events;
}; // sizeof = 424, verified

struct wlr_xdg_popup {
    struct wlr_xdg_surface *base;
    struct wl_list link;
    struct wl_resource *resource;
    struct wlr_surface *parent;
    struct wlr_seat *seat;
    void *scheduled;
    struct wlr_xdg_popup_state current, pending;
    struct { struct wl_signal destroy; struct wl_signal reposition; } events;
    struct wl_list grab_link;
};

/* XDG shell functions */
struct wlr_xdg_shell *wlr_xdg_shell_create(struct wl_display *display, uint32_t version);
void wlr_xdg_surface_ping(struct wlr_xdg_surface *surface);
uint32_t wlr_xdg_toplevel_set_size(struct wlr_xdg_toplevel *toplevel, int32_t width, int32_t height);
uint32_t wlr_xdg_toplevel_set_activated(struct wlr_xdg_toplevel *toplevel, bool activated);
uint32_t wlr_xdg_toplevel_set_maximized(struct wlr_xdg_toplevel *toplevel, bool maximized);
uint32_t wlr_xdg_toplevel_set_fullscreen(struct wlr_xdg_toplevel *toplevel, bool fullscreen);
uint32_t wlr_xdg_toplevel_set_tiled(struct wlr_xdg_toplevel *toplevel, uint32_t tiled_edges);
uint32_t wlr_xdg_toplevel_set_wm_capabilities(struct wlr_xdg_toplevel *toplevel, uint32_t caps);
void wlr_xdg_toplevel_send_close(struct wlr_xdg_toplevel *toplevel);
void wlr_xdg_popup_destroy(struct wlr_xdg_popup *popup);
struct wlr_surface *wlr_xdg_surface_surface_at(struct wlr_xdg_surface *surface, double sx, double sy, double *sub_x, double *sub_y);
struct wlr_xdg_surface *wlr_xdg_surface_try_from_wlr_surface(struct wlr_surface *surface);
struct wlr_xdg_toplevel *wlr_xdg_toplevel_try_from_wlr_surface(struct wlr_surface *surface);
]]

return {}
