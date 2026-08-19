local ffi = require("ffi")

ffi.cdef[[
/* ---- wlr/compositor.h ---- */
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

struct wlr_surface {
    char _opaque[712]; // everything before events
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

/* ---- wlr/data_device.h ---- */
struct wlr_data_device_manager {
    struct wl_global *global;
    struct wl_list data_sources;
    struct { struct wl_signal destroy; } events;
    void *data;
};

struct wlr_data_device_manager *wlr_data_device_manager_create(struct wl_display *display);

/* ---- wlr/layer_shell_v1.h ---- */
struct wlr_layer_shell_v1 {
    struct wl_global *global;
    struct {
        struct wl_signal new_surface;
        struct wl_signal destroy;
    } events;
    void *data;
};

struct wlr_layer_shell_v1 *wlr_layer_shell_v1_create(struct wl_display *display, uint32_t version);

/* ---- wlr/output_management_v1.h ---- */
struct wlr_output_manager_v1 *wlr_output_manager_v1_create(struct wl_display *display);

/* ---- wlr/gamma_control_v1.h ---- */
struct wlr_gamma_control_manager_v1 *wlr_gamma_control_manager_v1_create(struct wl_display *display);

/* ---- wlr/idle_notify_v1.h ---- */
struct wlr_idle_notifier_v1 *wlr_idle_notifier_v1_create(struct wl_display *display);

/* ---- wlr/ext_data_control_v1.h ---- */
struct wlr_ext_data_control_manager_v1 *wlr_ext_data_control_manager_v1_create(struct wl_display *display, uint32_t version);

/* ---- wlr/content_type_v1.h ---- */
struct wlr_content_type_manager_v1 *wlr_content_type_manager_v1_create(struct wl_display *display, uint32_t version);

/* ---- wlr/viewporter.h ---- */
struct wlr_viewporter *wlr_viewporter_create(struct wl_display *display);

/* ---- wlr/primary_selection_v1.h ---- */
struct wlr_primary_selection_v1_device_manager *wlr_primary_selection_v1_device_manager_create(struct wl_display *display);

/* ---- wlr/foreign_toplevel_management_v1.h ---- */
struct wlr_foreign_toplevel_manager_v1 *wlr_foreign_toplevel_manager_v1_create(struct wl_display *display);

/* ---- wlr/single_pixel_buffer_v1.h ---- */
struct wlr_single_pixel_buffer_manager_v1 *wlr_single_pixel_buffer_manager_v1_create(struct wl_display *display);
]]

return {}
