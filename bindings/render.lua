local ffi = require("ffi")

ffi.cdef[[
// wlr/render/wlr_renderer.h
struct wlr_renderer {
    uint32_t render_buffer_caps;
    uint32_t color_encodings;
    struct {
        struct wl_signal destroy;
        struct wl_signal lost;
    } events;
    struct {
        bool input_color_transform;
        bool output_color_transform;
        bool timeline;
    } features;
};

struct wlr_renderer *wlr_renderer_autocreate(struct wlr_backend *backend);
bool wlr_renderer_init_wl_display(struct wlr_renderer *renderer, struct wl_display *display);
bool wlr_renderer_init_wl_shm(struct wlr_renderer *renderer, struct wl_display *display);
int wlr_renderer_get_drm_fd(struct wlr_renderer *renderer);
void wlr_renderer_destroy(struct wlr_renderer *renderer);

// wlr/render/wlr_texture.h
struct wlr_texture {
    const void *impl;
    uint32_t width, height;
    struct wlr_renderer *renderer;
};

void wlr_texture_destroy(struct wlr_texture *texture);
struct wlr_texture *wlr_texture_from_buffer(struct wlr_renderer *renderer, void *buffer);

// wlr/render/gles2.h
struct wlr_gles2_texture_attribs {
    uint32_t target;
    uint32_t tex;
    bool has_alpha;
};

bool wlr_renderer_is_gles2(struct wlr_renderer *renderer);
bool wlr_gles2_renderer_check_ext(struct wlr_renderer *renderer, const char *ext);
void wlr_gles2_texture_get_attribs(struct wlr_texture *texture, struct wlr_gles2_texture_attribs *attribs);

// wlr/render/pass.h (render pass API, wlroots 0.18+)
struct wlr_render_pass;

struct wlr_buffer_pass_options {
    struct wlr_render_timer *timer;
    struct wlr_color_transform *color_transform;
    struct wlr_drm_syncobj_timeline *signal_timeline;
    uint64_t signal_point;
};

struct wlr_render_pass *wlr_renderer_begin_buffer_pass(struct wlr_renderer *renderer, struct wlr_buffer *buffer, const struct wlr_buffer_pass_options *options);
struct wlr_render_pass *wlr_output_begin_render_pass(struct wlr_output *output, const struct wlr_output_state *state, const struct wlr_buffer_pass_options *render_options);
bool wlr_render_pass_submit(struct wlr_render_pass *pass);

// color value, rgb premultiplied by alpha
struct wlr_render_color {
    float r, g, b, a;
};

enum wlr_render_blend_mode {
    WLR_RENDER_BLEND_MODE_PREMULTIPLIED = 0,
    WLR_RENDER_BLEND_MODE_NONE = 1,
};

enum wlr_scale_filter_mode {
    WLR_SCALE_FILTER_BILINEAR = 0,
    WLR_SCALE_FILTER_NEAREST = 1,
};

struct wlr_render_rect_options {
    struct wlr_box box;
    struct wlr_render_color color;
    const pixman_region32_t *clip;
    uint32_t blend_mode;
};

struct wlr_render_texture_options {
    struct wlr_texture *texture;
    struct wlr_fbox src_box;
    struct wlr_box dst_box;
    const float *alpha;
    const pixman_region32_t *clip;
    uint32_t transform;
    uint32_t filter_mode;
    uint32_t blend_mode;
    uint32_t transfer_function;
    void *primaries;
    uint32_t color_encoding;
    uint32_t color_range;
    const float *luminance_multiplier;
    void *wait_timeline;
    uint64_t wait_point;
};

void wlr_render_pass_add_rect(struct wlr_render_pass *pass, const struct wlr_render_rect_options *options);
void wlr_render_pass_add_texture(struct wlr_render_pass *pass, const struct wlr_render_texture_options *options);

// wlr/output.h - modern API
struct wlr_output_event_request_state {
    struct wlr_output *output;
    const struct wlr_output_state *state;
};

bool wlr_output_commit_state(struct wlr_output *output, void *state);
bool wlr_output_test_state(struct wlr_output *output, void *state);
void wlr_output_state_init(void *state);
void wlr_output_state_finish(void *state);
void wlr_output_state_set_enabled(void *state, bool enabled);
void wlr_output_state_set_mode(void *state, struct wlr_output_mode *mode);
void wlr_output_state_set_custom_mode(void *state, int32_t width, int32_t height, int32_t refresh);
void wlr_output_state_set_scale(void *state, float scale);
void wlr_output_state_set_transform(void *state, uint32_t transform);
void wlr_output_state_set_adaptive_sync_enabled(void *state, bool enabled);

// wlr/types/wlr_buffer.h
struct wlr_buffer {
    struct wlr_renderer *renderer;
    uint32_t width, height;
    void *data;
    struct {
        struct wl_signal destroy;
    } events;
    void *impl;
};

struct wlr_buffer *wlr_buffer_lock(struct wlr_buffer *buffer);
void wlr_buffer_unlock(struct wlr_buffer *buffer);

// wlr_surface is defined in protocols.lua - we just need the texture functions
struct wlr_texture *wlr_surface_get_texture(struct wlr_surface *surface);
bool wlr_surface_has_buffer(struct wlr_surface *surface);

// wlr/types/wlr_seat.h
struct wlr_seat_client;

struct wlr_seat_pointer_request_set_cursor_event {
    struct wlr_seat_client *seat_client;
    struct wlr_surface *surface;
    uint32_t serial;
    int32_t hotspot_x, hotspot_y;
};

void wlr_cursor_set_surface(struct wlr_cursor *cursor, struct wlr_surface *surface, int32_t hotspot_x, int32_t hotspot_y);
]]

return {}