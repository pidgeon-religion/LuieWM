local ffi = require("ffi")

ffi.cdef[[
    void *dlopen(const char *filename, int flag);
]]
local RTLD_LAZY = 1
local RTLD_NOW = 2
local RTLD_GLOBAL = 256
local function preload_lib(name)
    local handle = ffi.C.dlopen(name, bit.bor(RTLD_NOW, RTLD_GLOBAL))
    if handle == nil then
        io.stderr:write(string.format("[luiewm] warning: could not preload %s\n", name))
    end
    return handle
end
preload_lib("libwayland-server.so")
preload_lib("libwlroots-0.20.so")
preload_lib("libxkbcommon.so")

pcall(ffi.cdef, [[
    /* Basic types */
    typedef int pid_t;
    typedef unsigned int useconds_t;

    /* Time */
    struct timespec {
        long tv_sec;
        long tv_nsec;
    };
    int clock_gettime(int clockid, struct timespec *tp);

    /* Process */
    int setenv(const char *name, const char *value, int overwrite);
    char *getenv(const char *name);
    pid_t fork(void);
    int execl(const char *path, const char *arg, ...);
    int execvp(const char *file, char *const argv[]);
    void _exit(int status);
]])

-- wayland proto enums (not defined in other binding file)
pcall(ffi.cdef, [[
    enum wl_seat_capability {
        WL_SEAT_CAPABILITY_POINTER = 2,
        WL_SEAT_CAPABILITY_KEYBOARD = 4,
        WL_SEAT_CAPABILITY_TOUCH = 8,
    };

    enum wl_keyboard_key_state {
        WL_KEYBOARD_KEY_STATE_RELEASED = 0,
        WL_KEYBOARD_KEY_STATE_PRESSED = 1,
    };

    enum wl_pointer_button_state {
        WL_POINTER_BUTTON_STATE_RELEASED = 0,
        WL_POINTER_BUTTON_STATE_PRESSED = 1,
    };

    enum wl_pointer_axis {
        WL_POINTER_AXIS_VERTICAL_SCROLL = 0,
        WL_POINTER_AXIS_HORIZONTAL_SCROLL = 1,
    };

    enum wl_pointer_axis_source {
        WL_POINTER_AXIS_SOURCE_NONE = 0,
        WL_POINTER_AXIS_SOURCE_FINGER = 1,
        WL_POINTER_AXIS_SOURCE_CONTINUOUS = 2,
        WL_POINTER_AXIS_SOURCE_WHEEL = 3,
    };

    enum wl_pointer_axis_relative_direction {
        WL_POINTER_AXIS_RELATIVE_DIRECTION_NORMAL = 0,
        WL_POINTER_AXIS_RELATIVE_DIRECTION_INVERTED = 1,
    };

    enum wl_output_transform {
        WL_OUTPUT_TRANSFORM_NORMAL = 0,
        WL_OUTPUT_TRANSFORM_90 = 1,
        WL_OUTPUT_TRANSFORM_180 = 2,
        WL_OUTPUT_TRANSFORM_270 = 3,
        WL_OUTPUT_TRANSFORM_FLIPPED = 4,
        WL_OUTPUT_TRANSFORM_FLIPPED_90 = 5,
        WL_OUTPUT_TRANSFORM_FLIPPED_180 = 6,
        WL_OUTPUT_TRANSFORM_FLIPPED_270 = 7,
    };

    enum wl_output_subpixel {
        WL_OUTPUT_SUBPIXEL_UNKNOWN = 0,
        WL_OUTPUT_SUBPIXEL_NONE = 1,
        WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB = 2,
        WL_OUTPUT_SUBPIXEL_HORIZONTAL_BGR = 3,
        WL_OUTPUT_SUBPIXEL_VERTICAL_RGB = 4,
        WL_OUTPUT_SUBPIXEL_VERTICAL_BGR = 5,
    };
]])

return {}
