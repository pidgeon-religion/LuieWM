local ffi = require("ffi")

ffi.cdef[[
// wlr/scene.h
typedef bool (*wlr_scene_buffer_point_accepts_input_func_t)(
    struct wlr_scene_buffer *buffer, double *sx, double *sy);
typedef void (*wlr_scene_buffer_iterator_func_t)(
    struct wlr_scene_buffer *buffer, int sx, int sy, void *user_data);

enum wlr_scene_node_type {
    WLR_SCENE_NODE_TREE,
    WLR_SCENE_NODE_RECT,
    WLR_SCENE_NODE_BUFFER,
};

struct wlr_scene_node {
    enum wlr_scene_node_type type;
    struct wlr_scene_tree *parent;
    struct wl_list link;
    bool enabled;
    int x, y;
    struct { struct wl_signal destroy; } events;
    void *data;
    void *addons;
};

struct wlr_scene_tree {
    struct wlr_scene_node node;
    struct wl_list children;
};

struct wlr_scene {
    struct wlr_scene_tree tree;
    struct wl_list outputs;
    void *linux_dmabuf_v1;
    void *gamma_control_manager_v1;
    void *color_manager_v1;
    bool restack_xwayland_surfaces;
};

struct wlr_scene_rect {
    struct wlr_scene_node node;
    int width, height;
    float color[4];
};

struct wlr_scene_buffer {
    struct wlr_scene_node node;
    void *buffer;
    struct {
        struct wl_signal outputs_update;
        struct wl_signal output_enter;
        struct wl_signal output_leave;
        struct wl_signal output_sample;
        struct wl_signal frame_done;
    } events;
    void *point_accepts_input;
    void *primary_output;
    float opacity;
    uint32_t filter_mode;
    struct wlr_fbox src_box;
    int dst_width, dst_height;
    uint32_t transform;
    void *opaque_region;
    uint32_t transfer_function;
    uint32_t primaries;
    uint32_t color_encoding;
    uint32_t color_range;
};

struct wlr_scene_surface {
    struct wlr_scene_buffer *buffer;
    struct wlr_surface *surface;
};

struct wlr_scene_output {
    char _opaque[344]; // fully opaque — use only as pointer to wlroots functions
}; // sizeof = 344, verified

struct wlr_scene_output_layout {
    void *sol;
    struct wlr_output_layout *layout;
    struct wlr_scene *scene;
};

// Scene functions
struct wlr_scene *wlr_scene_create(void);
struct wlr_scene_tree *wlr_scene_tree_create(struct wlr_scene_tree *parent);

// Node functions
void wlr_scene_node_destroy(struct wlr_scene_node *node);
void wlr_scene_node_set_enabled(struct wlr_scene_node *node, bool enabled);
void wlr_scene_node_set_position(struct wlr_scene_node *node, int x, int y);
void wlr_scene_node_raise_to_top(struct wlr_scene_node *node);
void wlr_scene_node_lower_to_bottom(struct wlr_scene_node *node);
void wlr_scene_node_reparent(struct wlr_scene_node *node, struct wlr_scene_tree *new_parent);
bool wlr_scene_node_coords(struct wlr_scene_node *node, int *lx, int *ly);
struct wlr_scene_node *wlr_scene_node_at(struct wlr_scene_node *node, double lx, double ly, double *nx, double *ny);

// Scene rect
struct wlr_scene_rect *wlr_scene_rect_create(struct wlr_scene_tree *parent, int width, int height, const float color[4]);
void wlr_scene_rect_set_size(struct wlr_scene_rect *rect, int width, int height);
void wlr_scene_rect_set_color(struct wlr_scene_rect *rect, const float color[4]);

// Scene surface
struct wlr_scene_surface *wlr_scene_surface_create(struct wlr_scene_tree *parent, struct wlr_surface *surface);
struct wlr_scene_surface *wlr_scene_surface_try_from_buffer(struct wlr_scene_buffer *scene_buffer);

// Scene xdg surface
struct wlr_scene_tree *wlr_scene_xdg_surface_create(struct wlr_scene_tree *parent, struct wlr_xdg_surface *xdg_surface);

// Scene output
struct wlr_scene_output *wlr_scene_output_create(struct wlr_scene *scene, struct wlr_output *output);
void wlr_scene_output_destroy(struct wlr_scene_output *scene_output);
bool wlr_scene_output_commit(struct wlr_scene_output *scene_output, const void *options);
struct wlr_scene_output *wlr_scene_get_scene_output(struct wlr_scene *scene, struct wlr_output *output);

// Scene output layout
struct wlr_scene_output_layout *wlr_scene_attach_output_layout(struct wlr_scene *scene, struct wlr_output_layout *output_layout);

// Scene layer surface
struct wlr_scene_layer_surface_v1 *wlr_scene_layer_surface_v1_create(
    struct wlr_scene_tree *parent, struct wlr_layer_surface_v1 *layer_surface);
void wlr_scene_layer_surface_v1_configure(
    struct wlr_scene_layer_surface_v1 *scene_layer_surface,
    const struct wlr_box *full_area, struct wlr_box *usable_area);

// Scene subsurface tree
struct wlr_scene_tree *wlr_scene_subsurface_tree_create(struct wlr_scene_tree *parent, struct wlr_surface *surface);
]]

return {}
