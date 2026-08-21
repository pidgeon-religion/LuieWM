local ffi = require("ffi")

ffi.cdef([[
// wlr/compositor.h
struct wlr_compositor {
    struct wl_global *global;
    struct wlr_renderer *renderer;
    struct {
        struct wl_signal new_surface;
        struct wl_signal destroy;
    } events;
};

struct wlr_subcompositor {
    struct wl_global *global;
    struct {
        struct wl_signal new_surface;
    } events;
};

// pixman_region32_t comes from wlroots.lua (loads first)

struct wlr_subsurface_parent_state {
    int32_t x, y;
    struct wl_list link;
    void *_private_synced;
};

struct wlr_subsurface {
    struct wl_resource *resource;
    struct wlr_surface *surface;
    struct wlr_surface *parent;
    struct wlr_subsurface_parent_state current, pending;
    uint32_t cached_seq;
    bool has_cache;
    bool synchronized;
    bool added;
    struct {
        struct wl_signal destroy;
    } events;
    void *data;
    char _private[88]; // WLR_PRIVATE: synced + listeners
};

struct wlr_surface_state {
    uint32_t committed;
    uint32_t seq;
    void *buffer;
    int32_t dx, dy;
    pixman_region32_t surface_damage, buffer_damage;
    pixman_region32_t opaque, input;
    uint32_t transform;
    int32_t scale;
    struct wl_list frame_callback_list;
    int width, height;
    int buffer_width, buffer_height;
    struct wl_list subsurfaces_below;
    struct wl_list subsurfaces_above;
    struct {
        bool has_src, has_dst;
        struct wlr_fbox src;
        int dst_width, dst_height;
    } viewport;
    size_t cached_state_locks;
    struct wl_list cached_state_link;
    char _synced[24]; // wl_array
};

struct wlr_surface {
    char _opaque[96]; // private prefix
    struct wlr_surface_state current, pending;
    struct wl_list cached;
    bool mapped;
    char _pad[23]; // role + role_resource pointers
    struct {
        struct wl_signal client_commit;
        struct wl_signal commit;
        struct wl_signal map;
        struct wl_signal unmap;
        struct wl_signal new_subsurface;
        struct wl_signal destroy;
    } events;
};

struct wlr_compositor *wlr_compositor_create(struct wl_display *display, uint32_t version, struct wlr_renderer *renderer);
struct wlr_subcompositor *wlr_subcompositor_create(struct wl_display *display);
struct wlr_surface *wlr_surface_from_resource(struct wl_resource *resource);
void wlr_surface_send_frame_done(struct wlr_surface *surface, const struct timespec *when);
void wlr_surface_send_enter(struct wlr_surface *surface, struct wlr_output *output);
void wlr_surface_send_leave(struct wlr_surface *surface, struct wlr_output *output);

// wlr/data_device.h
struct wlr_data_device_manager {
    struct wl_global *global;
    struct wl_list data_sources;
    struct { struct wl_signal destroy; } events;
    void *data;
};

struct wlr_data_device_manager *wlr_data_device_manager_create(struct wl_display *display);

// wlr/layer_shell_v1.h
struct wlr_layer_shell_v1 {
    struct wl_global *global;
    struct {
        struct wl_signal new_surface;
        struct wl_signal destroy;
    } events;
    void *data;
};

struct wlr_layer_shell_v1 *wlr_layer_shell_v1_create(struct wl_display *display, uint32_t version);

// wlr/output_management_v1.h
struct wlr_output_manager_v1 *wlr_output_manager_v1_create(struct wl_display *display);

// wlr/gamma_control_v1.h
struct wlr_gamma_control_manager_v1 *wlr_gamma_control_manager_v1_create(struct wl_display *display);

// wlr/idle_notify_v1.h
struct wlr_idle_notifier_v1 *wlr_idle_notifier_v1_create(struct wl_display *display);

// wlr/ext_data_control_v1.h
struct wlr_ext_data_control_manager_v1 *wlr_ext_data_control_manager_v1_create(struct wl_display *display, uint32_t version);

// wlr/content_type_v1.h
struct wlr_content_type_manager_v1 *wlr_content_type_manager_v1_create(struct wl_display *display, uint32_t version);

// wlr/viewporter.h
struct wlr_viewporter *wlr_viewporter_create(struct wl_display *display);

// wlr/primary_selection_v1.h
struct wlr_primary_selection_v1_device_manager *wlr_primary_selection_v1_device_manager_create(struct wl_display *display);

// wlr/foreign_toplevel_management_v1.h
struct wlr_foreign_toplevel_manager_v1 *wlr_foreign_toplevel_manager_v1_create(struct wl_display *display);

// wlr/single_pixel_buffer_v1.h
struct wlr_single_pixel_buffer_manager_v1 *wlr_single_pixel_buffer_manager_v1_create(struct wl_display *display);

// wlr/xdg_decoration_v1.h
struct wlr_xdg_decoration_manager_v1 *wlr_xdg_decoration_manager_v1_create(struct wl_display *display);

// wlr/xdg_activation_v1.h
struct wlr_xdg_activation_v1 *wlr_xdg_activation_v1_create(struct wl_display *display);

// wlr/text_input_v3.h
struct wlr_text_input_manager_v3 *wlr_text_input_manager_v3_create(struct wl_display *display);

// wlr/data_control_v1.h
struct wlr_data_control_manager_v1 *wlr_data_control_manager_v1_create(struct wl_display *display);

// wlr/layer_shell_v1.h
struct wlr_layer_surface_v1_state {
    uint32_t committed;
    uint32_t anchor;
    int32_t exclusive_zone;
    struct { int32_t top, right, bottom, left; } margin;
    uint32_t keyboard_interactive;
    uint32_t desired_width, desired_height;
    uint32_t layer;
    uint32_t exclusive_edge;
    uint32_t configure_serial;
    uint32_t actual_width, actual_height;
};

struct wlr_layer_surface_v1 {
    struct wlr_surface *surface;
    struct wlr_output *output;
    struct wl_resource *resource;
    void *shell;
    struct wl_list popups;
    char *namespace;
    bool configured;
    struct wl_list configure_list;
    struct wlr_layer_surface_v1_state current, pending;
    bool initialized;
    bool initial_commit;
    struct { struct wl_signal destroy; struct wl_signal new_popup; } events;
    void *data;
};

struct wlr_layer_shell_v1 *wlr_layer_shell_v1_create(struct wl_display *display, uint32_t version);
uint32_t wlr_layer_surface_v1_configure(struct wlr_layer_surface_v1 *surface, uint32_t width, uint32_t height);
void wlr_layer_surface_v1_destroy(struct wlr_layer_surface_v1 *surface);
struct wlr_layer_surface_v1 *wlr_layer_surface_v1_try_from_wlr_surface(struct wlr_surface *surface);

// wlr/server_decoration.h
struct wlr_server_decoration_manager *wlr_server_decoration_manager_create(struct wl_display *display);
]])

return {}
