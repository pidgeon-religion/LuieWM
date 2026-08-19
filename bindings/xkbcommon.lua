local ffi = require("ffi")

ffi.cdef[[
/* ---- xkbcommon/xkbcommon.h ---- */
struct xkb_context;
struct xkb_keymap;
struct xkb_state;

struct xkb_rule_names {
    const char *rules;
    const char *model;
    const char *layout;
    const char *variant;
    const char *options;
};

enum xkb_context_flags {
    XKB_CONTEXT_NO_FLAGS = 0,
    XKB_CONTEXT_NO_DEFAULT_INCLUDES = (1 << 0),
    XKB_CONTEXT_NO_ENVIRONMENT_NAMES = (1 << 1),
};

enum xkb_keymap_compile_flags {
    XKB_KEYMAP_COMPILE_NO_FLAGS = 0,
};

enum xkb_keymap_format {
    XKB_KEYMAP_FORMAT_TEXT_V1,
};

enum xkb_state_component {
    XKB_STATE_MODS_DEPRESSED = (1 << 0),
    XKB_STATE_MODS_LATCHED = (1 << 1),
    XKB_STATE_MODS_LOCKED = (1 << 2),
    XKB_STATE_MODS_EFFECTIVE = (1 << 3),
    XKB_STATE_LEDS = (1 << 4),
};

enum xkb_state_key_direction {
    XKB_KEY_DOWN,
    XKB_KEY_UP,
};

enum xkb_compose_status {
    XKB_COMPOSE_NOTHING,
    XKB_COMPOSE_COMPOSING,
    XKB_COMPOSE_COMPOSED,
    XKB_COMPOSE_CANCELLED,
};

enum xkb_compose_feed_result {
    XKB_COMPOSE_FEED_IGNORED,
    XKB_COMPOSE_FEED_FEEDBACK,
};

enum xkb_context_flags xkb_context_flags;
enum xkb_keymap_compile_flags xkb_keymap_compile_flags;

typedef uint32_t xkb_keycode_t;
typedef uint32_t xkb_keysym_t;
typedef uint32_t xkb_layout_index_t;
typedef uint32_t xkb_layout_mask_t;
typedef uint32_t xkb_level_index_t;
typedef uint32_t xkb_mod_index_t;
typedef uint32_t xkb_mod_mask_t;
typedef uint32_t xkb_led_index_t;
typedef uint32_t xkb_led_mask_t;

struct xkb_context *xkb_context_new(enum xkb_context_flags flags);
void xkb_context_unref(struct xkb_context *context);

struct xkb_keymap *xkb_keymap_new_from_names(struct xkb_context *context,
    const struct xkb_rule_names *names, enum xkb_keymap_compile_flags flags);
struct xkb_keymap *xkb_keymap_new_from_string(struct xkb_context *context,
    const char *string, enum xkb_keymap_format format,
    enum xkb_keymap_compile_flags flags);
char *xkb_keymap_get_as_string(struct xkb_keymap *keymap, enum xkb_keymap_format format);
void xkb_keymap_unref(struct xkb_keymap *keymap);

struct xkb_state *xkb_state_new(struct xkb_keymap *keymap);
void xkb_state_unref(struct xkb_state *state);
xkb_keysym_t xkb_state_key_get_one_sym(struct xkb_state *state, xkb_keycode_t key);
int xkb_state_mod_name_is_active(struct xkb_state *state, const char *name, enum xkb_state_component type);
enum xkb_state_component xkb_state_update_key(struct xkb_state *state, xkb_keycode_t key, enum xkb_state_direction direction);
xkb_mod_mask_t xkb_state_serialize_mods(struct xkb_state *state, enum xkb_state_component components);
xkb_led_mask_t xkb_state_serialize_leds(struct xkb_state *state, enum xkb_state_component components);

/* xkbcommon-compose.h */
struct xkb_compose_table;
struct xkb_compose_state;

enum xkb_compose_compile_flags {
    XKB_COMPOSE_COMPILE_NO_FLAGS = 0,
};

enum xkb_compose_state_flags {
    XKB_COMPOSE_STATE_NO_FLAGS = 0,
};

struct xkb_compose_table *xkb_compose_table_new_from_locale(struct xkb_context *context,
    const char *locale, enum xkb_compose_compile_flags flags);
void xkb_compose_table_unref(struct xkb_compose_table *table);
struct xkb_compose_state *xkb_compose_state_new(struct xkb_compose_table *table,
    enum xkb_compose_state_flags flags);
void xkb_compose_state_unref(struct xkb_compose_state *state);
enum xkb_compose_status xkb_compose_state_get_status(struct xkb_compose_state *state);
xkb_keysym_t xkb_compose_state_get_one_sym(struct xkb_compose_state *state);
enum xkb_compose_feed_result xkb_compose_state_feed(struct xkb_compose_state *state, xkb_keysym_t keysym);
void xkb_compose_state_reset(struct xkb_compose_state *state);
]]

return {}
