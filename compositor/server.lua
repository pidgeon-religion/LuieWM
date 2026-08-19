local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local wayland = require("bindings.wayland")
local wlroots = require("bindings.wlroots")
local scene_bindings = require("bindings.scene")
local input_bindings = require("bindings.input")
local xdg_bindings = require("bindings.xdg_shell")
local render_bindings = require("bindings.render")
local proto_bindings = require("bindings.protocols")
local xkb = require("bindings.xkbcommon")

local C = ffi.C

local Server = {}
Server.__index = Server

function Server.new()
    local self = setmetatable({}, Server)

    self.wl_display = nil
    self.backend = nil
    self.renderer = nil
    self.output_layout = nil
    self.scene = nil
    self.scene_layout = nil
    self.cursor = nil
    self.cursor_mgr = nil
    self.seat = nil
    self.xdg_shell = nil
    self.compositor = nil
    self.data_device_manager = nil

    self.views = {}
    self.outputs = {}
    self.keyboards = {}
    self.current_tag = 1

    self.listeners = {}
    self._destroy_funcs = {}

    return self
end

function Server:init()
    log.info("initializing LuieWM...")

    log.debug("creating wl_display...")
    self.wl_display = C.wl_display_create()
    if self.wl_display == nil then
        log.error("failed to create wayland display")
        return false
    end

    log.debug("creating backend...")
    local event_loop = C.wl_display_get_event_loop(self.wl_display)
    self.backend = C.wlr_backend_autocreate(event_loop, nil)
    if self.backend == nil then
        log.error("failed to create backend")
        return false
    end

    log.debug("creating renderer...")
    self.renderer = C.wlr_renderer_autocreate(self.backend)
    if self.renderer == nil then
        log.error("failed to get renderer")
        log.error("hint: if on a TTY, make sure WAYLAND_DISPLAY is unset")
        return false
    end

    log.debug("init_wl_display...")
    if not C.wlr_renderer_init_wl_display(self.renderer, self.wl_display) then
        log.error("failed to init renderer wl_display")
        return false
    end

    log.debug("creating allocator...")
    self.allocator = C.wlr_allocator_autocreate(self.backend, self.renderer)
    if self.allocator == nil then
        log.error("failed to create allocator")
        return false
    end

    self.compositor = C.wlr_compositor_create(self.wl_display, 6, self.renderer)
    if self.compositor == nil then
        log.error("failed to create compositor")
        return false
    end

    self.subcompositor = C.wlr_subcompositor_create(self.wl_display)
    log.debug("subcompositor OK")

    log.debug("wlr_data_device_manager_create...")
    self.data_device_manager = C.wlr_data_device_manager_create(self.wl_display)
    log.debug("data_device_manager OK")

    log.debug("wlr_output_layout_create...")
    self.output_layout = C.wlr_output_layout_create(self.wl_display)
    log.debug("output_layout OK")

    log.debug("wlr_scene_create...")
    self.scene = C.wlr_scene_create()
    log.debug("scene OK")

    log.debug("wlr_scene_attach_output_layout...")
    self.scene_layout = C.wlr_scene_attach_output_layout(self.scene, self.output_layout)
    log.debug("scene_layout OK")

    log.debug("wlr_xdg_shell_create...")
    self.xdg_shell = C.wlr_xdg_shell_create(self.wl_display, 3)
    log.debug("xdg_shell OK")

    log.debug("wlr_cursor_create...")
    self.cursor = C.wlr_cursor_create()
    log.debug("cursor OK")

    log.debug("wlr_cursor_attach_output_layout...")
    C.wlr_cursor_attach_output_layout(self.cursor, self.output_layout)
    log.debug("cursor attached OK")

    log.debug("wlr_xcursor_manager_create...")
    self.cursor_mgr = C.wlr_xcursor_manager_create(nil, 24)
    log.debug("xcursor_manager OK")

    log.debug("wlr_xcursor_manager_load...")
    C.wlr_xcursor_manager_load(self.cursor_mgr, 1)
    log.debug("xcursor_manager_load OK")

    log.debug("wlr_cursor_set_xcursor...")
    C.wlr_cursor_set_xcursor(self.cursor, self.cursor_mgr, "left_ptr")
    log.debug("cursor_set_xcursor OK")

    log.debug("wlr_seat_create...")
    self.seat = C.wlr_seat_create(self.wl_display, "seat0")
    log.debug("seat OK")

    C.wlr_seat_set_capabilities(self.seat, 0x07)
    log.debug("seat capabilities OK")

    local request_cursor_listener = ffi_help.make_listener(function(data)
        log.debug("seat request_set_cursor")
    end)
    ffi_help.signal_add(self.seat.events.request_set_cursor, request_cursor_listener)

    local request_selection_listener = ffi_help.make_listener(function(data)
        log.debug("seat request_set_selection")
    end)
    ffi_help.signal_add(self.seat.events.request_set_selection, request_selection_listener)
    log.debug("seat listeners OK")

    log.debug("creating protocol managers...")
    C.wlr_output_manager_v1_create(self.wl_display)
    log.debug("output_manager OK")
    C.wlr_gamma_control_manager_v1_create(self.wl_display)
    log.debug("gamma_control OK")
    C.wlr_idle_notifier_v1_create(self.wl_display)
    log.debug("idle_notifier OK")
    C.wlr_content_type_manager_v1_create(self.wl_display, 1)
    log.debug("content_type OK")
    C.wlr_viewporter_create(self.wl_display)
    log.debug("viewporter OK")

    self:_setup_output_listeners()
    self:_setup_xdg_listeners()
    self:_setup_cursor_listeners()
    self:_setup_seat_listeners()
    self:_setup_backend_listeners()

    log.info("LuieWM initialized successfully")
    return true
end

function Server:_setup_backend_listeners()
    -- Listen for new outputs
    local new_output_cb = function(data)
        self:_on_new_output(ffi.cast("struct wlr_output *", data))
    end
    local new_output_listener = ffi_help.listen_signal(self.backend.events.new_output, new_output_cb)

    -- Listen for new input devices
    local new_input_cb = function(data)
        self:_on_new_input(ffi.cast("struct wlr_input_device *", data))
    end
    local new_input_listener = ffi_help.listen_signal(self.backend.events.new_input, new_input_cb)
end

function Server:_setup_output_listeners()
    -- Output handling is done in output.lua
end

function Server:_setup_xdg_listeners()
    -- XDG surface handling is done in surface.lua
end

function Server:_setup_cursor_listeners()
    -- Cursor handling is done in input_handler.lua
end

function Server:_setup_seat_listeners()
    -- Seat handling is done in input_handler.lua
end

function Server:_on_new_output(wlr_output)
    local output = require("compositor.output")
    output.handle_new(self, wlr_output)
end

function Server:_on_new_input(device)
    local input_handler = require("compositor.input_handler")
    input_handler.handle_new_input(self, device)
end

function Server:run()
    local socket = C.wl_display_add_socket_auto(self.wl_display)
    if socket == nil then
        log.error("failed to add socket")
        return false
    end

    local socket_str = ffi.string(socket)
    log.info("WAYLAND_DISPLAY=%s", socket_str)

    C.setenv("WAYLAND_DISPLAY", socket_str, 1)

    -- Start backend
    if not C.wlr_backend_start(self.backend) then
        log.error("failed to start backend")
        C.wlr_backend_destroy(self.backend)
        C.wl_display_destroy(self.wl_display)
        return false
    end

    -- Spawn startup command after WAYLAND_DISPLAY is set and backend is started
    if self._startup_cmd then
        log.info("spawning startup command: %s", self._startup_cmd)
        local pid = C.fork()
        if pid == 0 then
            -- Child process - explicitly set WAYLAND_DISPLAY in child environment
            C.setenv("WAYLAND_DISPLAY", socket_str, 1)
            C.execl("/bin/sh", "/bin/sh", "-c", self._startup_cmd, nil)
            C._exit(1)
        end
    end

    log.info("running compositor on WAYLAND_DISPLAY=%s", socket_str)

    -- Run event loop
    C.wl_display_run(self.wl_display)

    -- Cleanup
    C.wl_display_destroy_clients(self.wl_display)
    C.wl_display_destroy(self.wl_display)

    return true
end

function Server:add_view(view)
    table.insert(self.views, view)
    view._server = self
end

function Server:remove_view(view)
    for i, v in ipairs(self.views) do
        if v == view then
            table.remove(self.views, i)
            break
        end
    end
end

function Server:get_focused_view()
    for _, view in ipairs(self.views) do
        if view.focused and view.mapped then
            return view
        end
    end
    return nil
end

function Server:focus_view(view)
    -- Unfocus all
    for _, v in ipairs(self.views) do
        v:unfocus()
    end

    if view then
        view:focus()
        C.wlr_seat_set_keyboard(self.seat, nil)
        local keyboard = self.keyboards[1]
        if keyboard then
            C.wlr_seat_set_keyboard(self.seat, keyboard)
        end
    end
end

return Server
