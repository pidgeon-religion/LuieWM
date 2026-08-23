local ffi = require("ffi")

ffi.cdef[[
// wlr/input_device.h
enum wlr_input_device_type {
    WLR_INPUT_DEVICE_KEYBOARD,
    WLR_INPUT_DEVICE_POINTER,
    WLR_INPUT_DEVICE_TOUCH,
    WLR_INPUT_DEVICE_TABLET,
    WLR_INPUT_DEVICE_TABLET_PAD,
    WLR_INPUT_DEVICE_SWITCH,
};

struct wlr_input_device {
    enum wlr_input_device_type type;
    char *name;
    struct { struct wl_signal destroy; } events;
    void *data;
};

// wlr/keyboard.h
enum wlr_keyboard_led {
    WLR_LED_NUM_LOCK = 1 << 0,
    WLR_LED_CAPS_LOCK = 1 << 1,
    WLR_LED_SCROLL_LOCK = 1 << 2,
    WLR_LED_COMPOSE = 1 << 3,
    WLR_LED_KANA = 1 << 4,
};

enum wlr_keyboard_modifier {
    WLR_MODIFIER_SHIFT = 1 << 0,
    WLR_MODIFIER_CAPS = 1 << 1,
    WLR_MODIFIER_CTRL = 1 << 2,
    WLR_MODIFIER_ALT = 1 << 3,
    WLR_MODIFIER_MOD2 = 1 << 4,
    WLR_MODIFIER_MOD3 = 1 << 5,
    WLR_MODIFIER_LOGO = 1 << 6,
    WLR_MODIFIER_MOD5 = 1 << 7,
};

struct wlr_keyboard_modifiers {
    uint32_t depressed;
    uint32_t latched;
    uint32_t locked;
    uint32_t group;
};

struct wlr_keyboard {
    struct wlr_input_device base;
    const void *impl;
    void *group;
    char *keymap_string;
    size_t keymap_size;
    int keymap_fd;
    struct xkb_keymap *keymap;
    struct xkb_state *xkb_state;
    uint32_t led_indexes[5];
    uint32_t mod_indexes[8];
    uint32_t leds;
    uint32_t keycodes[32];
    size_t num_keycodes;
    struct wlr_keyboard_modifiers modifiers;
    struct { int32_t rate; int32_t delay; } repeat_info;
    struct {
        struct wl_signal key;
        struct wl_signal modifiers;
        struct wl_signal keymap;
        struct wl_signal repeat_info;
    } events;
    void *data;
};

struct wlr_keyboard_key_event {
    uint32_t time_msec;
    uint32_t keycode;
    bool update_state;
    uint32_t state; // wl_keyboard_key_state
};

// wlr/pointer.h
struct wlr_pointer {
    struct wlr_input_device base;
    const void *impl;
    char *output_name;
    uint32_t buttons[16];
    size_t button_count;
    struct {
        struct wl_signal motion;
        struct wl_signal motion_absolute;
        struct wl_signal button;
        struct wl_signal axis;
        struct wl_signal frame;
    } events;
    void *data;
};

struct wlr_pointer_button_event {
    struct wlr_pointer *pointer;
    uint32_t time_msec;
    uint32_t button;
    uint32_t state; // wl_pointer_button_state
};

struct wlr_pointer_axis_event {
    struct wlr_pointer *pointer;
    uint32_t time_msec;
    uint32_t source;
    uint32_t orientation;
    uint32_t relative_direction;
    double delta;
    int32_t delta_discrete;
};

// wlr/seat.h
struct wlr_seat_pointer_state {
    struct wlr_seat *seat;
    struct wlr_surface *focused_surface;
    double sx, sy;
    double grab_x, grab_y;
    struct wlr_seat_pointer_grab *grab;
    struct wlr_seat_pointer_grab *default_grab;
    uint32_t buttons;
    struct wl_list links;
    uint32_t size;
};

struct wlr_seat_keyboard_state {
    struct wlr_seat *seat;
    struct wlr_keyboard *keyboard;
    struct wlr_surface *focused_surface;
    struct wlr_seat_keyboard_grab *grab;
    struct wlr_seat_keyboard_grab *default_grab;
    struct wl_list links;
    uint32_t size;
};

struct wlr_seat_touch_state {
    struct wlr_seat *seat;
    struct wlr_seat_touch_grab *grab;
    struct wlr_seat_touch_grab *default_grab;
    struct wl_list points;
    struct wl_list links;
    uint32_t size;
};

struct wlr_seat_client {
    struct wl_client *client;
    struct wlr_seat *seat;
    struct wl_list link;
    struct wl_list resources;
    struct wl_list pointers;
    struct wl_list keyboards;
    struct wl_list touches;
    struct wl_list data_devices;
    struct { struct wl_signal destroy; } events;
    void *serials;
    bool needs_touch_frame;
    void *value120;
};

struct wlr_seat {
    struct wl_global *global;
    struct wl_display *display;
    struct wl_list clients;
    char *name;
    uint32_t capabilities;
    uint32_t accumulated_capabilities;
    void *selection_source;
    uint32_t selection_serial;
    struct wl_list selection_offers;
    void *primary_selection_source;
    uint32_t primary_selection_serial;
    void *drag;
    void *drag_source;
    uint32_t drag_serial;
    struct wl_list drag_offers;
    // pointer_state: seat ptr + focused client/surface (rest opaque, 384 bytes total)
    struct {
        void *seat;
        void *focused_client;
        void *focused_surface;
        char _rest[360];
    } pointer_state;
    char _keyboard_state[160];
    char _touch_state[48];
    struct {
        struct wl_signal pointer_grab_begin;
        struct wl_signal pointer_grab_end;
        struct wl_signal keyboard_grab_begin;
        struct wl_signal keyboard_grab_end;
        struct wl_signal touch_grab_begin;
        struct wl_signal touch_grab_end;
        struct wl_signal request_set_cursor;
        struct wl_signal request_set_selection;
        struct wl_signal set_selection;
        struct wl_signal request_set_primary_selection;
        struct wl_signal set_primary_selection;
        struct wl_signal request_start_drag;
        struct wl_signal start_drag;
        struct wl_signal destroy;
    } events;
    void *data;
};

struct wlr_seat *wlr_seat_create(struct wl_display *display, const char *name);
void wlr_seat_destroy(struct wlr_seat *seat);
void wlr_seat_set_capabilities(struct wlr_seat *seat, uint32_t capabilities);
void wlr_seat_set_name(struct wlr_seat *seat, const char *name);
void wlr_seat_set_keyboard(struct wlr_seat *keyboard, struct wlr_keyboard *device);
struct wlr_keyboard *wlr_seat_get_keyboard(struct wlr_seat *seat);

// wlr/types/wlr_data_device.h + wlr/primary_selection.h (selection plumbing)
struct wlr_data_source;
struct wlr_primary_selection_source;
struct wlr_drag;

struct wlr_seat_request_set_selection_event {
    struct wlr_data_source *source;
    uint32_t serial;
};

struct wlr_seat_request_set_primary_selection_event {
    struct wlr_primary_selection_source *source;
    uint32_t serial;
};

struct wlr_seat_request_start_drag_event {
    struct wlr_drag *drag;
    uint32_t serial;
};

void wlr_seat_set_selection(struct wlr_seat *seat, struct wlr_data_source *source, uint32_t serial);
void wlr_seat_set_primary_selection(struct wlr_seat *seat, struct wlr_primary_selection_source *source, uint32_t serial);
bool wlr_seat_start_drag(struct wlr_seat *seat, struct wlr_drag *drag, uint32_t serial);
void wlr_seat_pointer_notify_enter(struct wlr_seat *seat, struct wlr_surface *surface, double sx, double sy);
void wlr_seat_pointer_notify_clear_focus(struct wlr_seat *seat);
void wlr_seat_pointer_notify_motion(struct wlr_seat *seat, uint32_t time_msec, double sx, double sy);
uint32_t wlr_seat_pointer_notify_button(struct wlr_seat *seat, uint32_t time_msec, uint32_t button, uint32_t state);
void wlr_seat_pointer_notify_axis(struct wlr_seat *seat, uint32_t time_msec, uint32_t orientation, double value, int32_t value_discrete, uint32_t source, uint32_t relative_direction);
void wlr_seat_pointer_notify_frame(struct wlr_seat *seat);
void wlr_seat_keyboard_notify_key(struct wlr_seat *seat, uint32_t time_msec, uint32_t key, uint32_t state);
void wlr_seat_keyboard_notify_modifiers(struct wlr_seat *seat, const struct wlr_keyboard_modifiers *modifiers);
void wlr_seat_keyboard_notify_enter(struct wlr_seat *seat, struct wlr_surface *surface, uint32_t *keycodes, size_t num_keycodes, struct wlr_keyboard_modifiers *modifiers);

// wlr/cursor.h
struct wlr_cursor {
    void *state;
    double x, y;
    struct {
        struct wl_signal motion;
        struct wl_signal motion_absolute;
        struct wl_signal button;
        struct wl_signal axis;
        struct wl_signal frame;
        struct wl_signal swipe_begin;
        struct wl_signal swipe_update;
        struct wl_signal swipe_end;
        struct wl_signal pinch_begin;
        struct wl_signal pinch_update;
        struct wl_signal pinch_end;
        struct wl_signal hold_begin;
        struct wl_signal hold_end;
        struct wl_signal touch_up;
        struct wl_signal touch_down;
        struct wl_signal touch_motion;
        struct wl_signal touch_cancel;
        struct wl_signal touch_frame;
        struct wl_signal tablet_tool_axis;
        struct wl_signal tablet_tool_proximity;
        struct wl_signal tablet_tool_tip;
        struct wl_signal tablet_tool_button;
    } events;
    void *data;
};

struct wlr_cursor *wlr_cursor_create(void);
void wlr_cursor_destroy(struct wlr_cursor *cursor);
void wlr_cursor_attach_output_layout(struct wlr_cursor *cursor, struct wlr_output_layout *layout);
void wlr_cursor_attach_input_device(struct wlr_cursor *cursor, struct wlr_input_device *device);
void wlr_cursor_detach_input_device(struct wlr_cursor *cursor, struct wlr_input_device *device);
void wlr_cursor_move(struct wlr_cursor *cursor, struct wlr_input_device *device, double delta_x, double delta_y);
void wlr_cursor_warp_absolute(struct wlr_cursor *cursor, struct wlr_input_device *device, double x, double y);
void wlr_cursor_set_xcursor(struct wlr_cursor *cursor, struct wlr_xcursor_manager *manager, const char *name);
void wlr_cursor_set_surface(struct wlr_cursor *cursor, struct wlr_surface *surface, int32_t hotspot_x, int32_t hotspot_y);

// Cursor motion event structs (emitted by wlr_cursor signals)
struct wlr_cursor_motion_event {
    struct wlr_pointer *pointer;
    uint32_t time_msec;
    double delta_x, delta_y;
    double delta_unaccel_x, delta_unaccel_y;
};

struct wlr_cursor_motion_absolute_event {
    struct wlr_pointer *pointer;
    uint32_t time_msec;
    double x, y;
};

// wlr/xcursor_manager.h
struct wlr_xcursor_manager {
    char *name;
    uint32_t size;
    struct wl_list scaled_themes;
};

struct wlr_xcursor_manager *wlr_xcursor_manager_create(const char *name, uint32_t size);
void wlr_xcursor_manager_destroy(struct wlr_xcursor_manager *manager);
bool wlr_xcursor_manager_load(struct wlr_xcursor_manager *manager, float scale);
struct wlr_xcursor *wlr_xcursor_manager_get_xcursor(struct wlr_xcursor_manager *manager,
    const char *name, float scale);

struct wlr_xcursor_image {
    uint32_t width;
    uint32_t height;
    uint32_t hotspot_x;
    uint32_t hotspot_y;
    uint32_t delay;
    uint8_t *buffer;
};

struct wlr_xcursor {
    unsigned int image_count;
    struct wlr_xcursor_image **images;
    char *name;
    uint32_t total_delay;
};

// wlr/cursor_shape_v1.h
struct wlr_cursor_shape_manager_v1 {
    struct wl_global *global;
    struct {
        struct wl_signal request_set_shape;
        struct wl_signal destroy;
    } events;
    void *data;
};

enum wlr_cursor_shape_manager_v1_device_type {
    WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER = 0,
    WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_TABLET_TOOL = 1,
};

struct wlr_cursor_shape_manager_v1_request_set_shape_event {
    struct wlr_seat_client *seat_client;
    uint32_t device_type;
    void *tablet_tool; // NULL unless device_type is TABLET_TOOL
    uint32_t serial;
    uint32_t shape; // enum wp_cursor_shape_device_v1_shape
};

struct wlr_cursor_shape_manager_v1 *wlr_cursor_shape_manager_v1_create(struct wl_display *display, uint32_t version);
const char *wlr_cursor_shape_v1_name(uint32_t shape);

// wlr/keyboard_group.h
struct wlr_keyboard_group {
    struct wlr_keyboard keyboard;
    struct wl_list devices;
    struct wl_list keys;
    struct { struct wl_signal enter; struct wl_signal leave; } events;
    void *data;
};

struct wlr_keyboard_group *wlr_keyboard_group_create(void);
void wlr_keyboard_group_destroy(struct wlr_keyboard_group *group);

// wlr_keyboard helpers
struct wlr_keyboard *wlr_keyboard_from_input_device(struct wlr_input_device *device);
bool wlr_keyboard_set_keymap(struct wlr_keyboard *kb, struct xkb_keymap *keymap);
]]

return {}
