local ffi = require("ffi")

ffi.cdef[[
/* ---- wlr/backend.h ---- */
struct wlr_backend {
    const void *impl;
    uint32_t buffer_caps;
    struct { bool timeline; } features;
    struct {
        struct wl_signal destroy;
        struct wl_signal new_input;
        struct wl_signal new_output;
    } events;
};

struct wlr_backend *wlr_backend_autocreate(struct wl_event_loop *loop, void **session_ptr);
bool wlr_backend_start(struct wlr_backend *backend);
void wlr_backend_destroy(struct wlr_backend *backend);
int wlr_backend_get_drm_fd(struct wlr_backend *backend);

/* ---- wlr/output.h ---- */
enum wlr_output_mode_aspect_ratio {
    WLR_OUTPUT_MODE_ASPECT_RATIO_NONE,
    WLR_OUTPUT_MODE_ASPECT_RATIO_4_3,
    WLR_OUTPUT_MODE_ASPECT_RATIO_16_9,
    WLR_OUTPUT_MODE_ASPECT_RATIO_64_27,
    WLR_OUTPUT_MODE_ASPECT_RATIO_256_135,
};

struct wlr_output_mode {
    int32_t width, height;
    int32_t refresh;
    bool preferred;
    enum wlr_output_mode_aspect_ratio picture_aspect_ratio;
    struct wl_list link;
};

enum wlr_output_adaptive_sync_status {
    WLR_OUTPUT_ADAPTIVE_SYNC_DISABLED,
    WLR_OUTPUT_ADAPTIVE_SYNC_ENABLED,
};

struct wlr_output_state {
    uint32_t committed;
    bool allow_reconfiguration;
    char _pad_damage[3]; // align damage to 4 bytes
    char damage[24]; // pixman_region32_t
    bool enabled;
    char _pad_scale[3]; // align scale to 4 bytes
    float scale;
    uint32_t transform;
    bool adaptive_sync_enabled;
    char _pad_render_format[3]; // align render_format
    uint32_t render_format;
    uint32_t subpixel;
    void *buffer;
    double buffer_src_x, buffer_src_y, buffer_src_width, buffer_src_height;
    int32_t buffer_dst_x, buffer_dst_y, buffer_dst_width, buffer_dst_height;
    bool tearing_page_flip;
    char _pad_mode_type[3]; // align mode_type
    uint32_t mode_type;
    struct wlr_output_mode *mode;
    struct { int32_t width, height; int32_t refresh; } custom_mode;
    void *layers;
    size_t layers_len;
    void *wait_timeline;
    uint64_t wait_point;
    void *signal_timeline;
    uint64_t signal_point;
    void *color_transform;
    void *image_description;
};

struct wlr_output {
    const void *impl;
    struct wlr_backend *backend;
    void *event_loop;
    struct wl_global *global;
    struct wl_list resources;
    char *name;
    char *description;
    char *make;
    char *model;
    char *serial;
    int32_t phys_width, phys_height;
    void *default_primaries;
    struct wl_list modes;
    struct wlr_output_mode *current_mode;
    int32_t width, height;
    int32_t refresh;
    uint32_t supported_primaries;
    uint32_t supported_transfer_functions;
    bool enabled;
    float scale;
    uint32_t subpixel;
    uint32_t transform;
    uint32_t adaptive_sync_status;
    uint32_t render_format;
    void *image_description;
    bool adaptive_sync_supported;
    bool needs_frame;
    bool frame_pending;
    bool non_desktop;
    uint32_t commit_seq;
    struct {
        struct wl_signal frame;
        struct wl_signal damage;
        struct wl_signal needs_frame;
        struct wl_signal precommit;
        struct wl_signal commit;
        struct wl_signal present;
        struct wl_signal bind;
        struct wl_signal description;
        struct wl_signal request_state;
        struct wl_signal destroy;
    } events;
    void *idle_frame;
    void *idle_done;
    int attach_render_locks;
    struct wl_list cursors;
    void *hardware_cursor;
    void *cursor_swapchain;
    void *cursor_front_buffer;
    int software_cursor_locks;
    struct wl_list layers;
    void *allocator;
    void *renderer;
    void *swapchain;
    char _addons[16]; // struct wlr_addon_set
    void *data;
};

void wlr_output_destroy(struct wlr_output *output);
void wlr_output_effective_resolution(struct wlr_output *output, int *width, int *height);
bool wlr_output_test_state(struct wlr_output *output, const struct wlr_output_state *state);
bool wlr_output_commit_state(struct wlr_output *output, const struct wlr_output_state *state);
void wlr_output_schedule_frame(struct wlr_output *output);
bool wlr_output_init_render(struct wlr_output *output, void *allocator, struct wlr_renderer *renderer);

/* ---- wlr/render/allocator.h ---- */
void *wlr_allocator_autocreate(struct wlr_backend *backend, struct wlr_renderer *renderer);

void wlr_output_state_init(struct wlr_output_state *state);
void wlr_output_state_finish(struct wlr_output_state *state);
void wlr_output_state_set_enabled(struct wlr_output_state *state, bool enabled);
void wlr_output_state_set_mode(struct wlr_output_state *state, struct wlr_output_mode *mode);
void wlr_output_state_set_custom_mode(struct wlr_output_state *state, int32_t width, int32_t height, int32_t refresh);
void wlr_output_state_set_scale(struct wlr_output_state *state, float scale);
void wlr_output_state_set_transform(struct wlr_output_state *state, uint32_t transform);
void wlr_output_state_set_adaptive_sync_enabled(struct wlr_output_state *state, bool enabled);

/* ---- wlr/output_layout.h ---- */
struct wlr_output_layout {
    struct wl_list outputs;
    struct wl_display *display;
    struct {
        struct wl_signal add;
        struct wl_signal change;
        struct wl_signal destroy;
    } events;
    void *data;
};

struct wlr_output_layout_output {
    struct wlr_output_layout *layout;
    struct wlr_output *output;
    int x, y;
    struct wl_list link;
    bool auto_configured;
    struct { struct wl_signal destroy; } events;
};

struct wlr_output_layout *wlr_output_layout_create(struct wl_display *display);
void wlr_output_layout_destroy(struct wlr_output_layout *layout);
struct wlr_output_layout_output *wlr_output_layout_add_auto(struct wlr_output_layout *layout, struct wlr_output *output);
void wlr_output_layout_remove(struct wlr_output_layout *layout, struct wlr_output *output);
void wlr_output_layout_get_box(struct wlr_output_layout *layout, struct wlr_output *reference, struct wlr_box *dest_box);
struct wlr_output *wlr_output_layout_output_at(struct wlr_output_layout *layout, double lx, double ly);

/* ---- wlr/util/box.h ---- */
struct wlr_box {
    int x, y;
    int width, height;
};

struct wlr_fbox {
    double x, y;
    double width, height;
};
]]

return {}
