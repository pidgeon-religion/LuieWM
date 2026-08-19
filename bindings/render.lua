local ffi = require("ffi")

ffi.cdef[[
/* ---- wlr/render/wlr_renderer.h ---- */
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
int wlr_renderer_get_drm_fd(struct wlr_renderer *renderer);
void wlr_renderer_destroy(struct wlr_renderer *renderer);

/* ---- wlr/render/wlr_texture.h ---- */
struct wlr_texture {
    const void *impl;
    uint32_t width, height;
    struct wlr_renderer *renderer;
};

void wlr_texture_destroy(struct wlr_texture *texture);
struct wlr_texture *wlr_texture_from_buffer(struct wlr_renderer *renderer, void *buffer);

/* ---- wlr/render/gles2.h ---- */
struct wlr_gles2_texture_attribs {
    uint32_t target;
    uint32_t tex;
    bool has_alpha;
};

bool wlr_renderer_is_gles2(struct wlr_renderer *renderer);
bool wlr_gles2_renderer_check_ext(struct wlr_renderer *renderer, const char *ext);
]]

return {}
