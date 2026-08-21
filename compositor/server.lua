local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local wayland = require("bindings.wayland")
local wlroots = require("bindings.wlroots")
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
	self.custom_renderer = nil
	self.output_layout = nil
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

	-- check renderer type
	local is_gles2 = C.wlr_renderer_is_gles2(self.renderer)
	log.debug("renderer is_gles2: %s", is_gles2 and "true" or "false")

	log.debug("init_wl_display...")
	-- shm only for now: dma-buf textures render empty through our draw path,
	-- revisit when wiring explicit sync / proper dmabuf handling
	if not C.wlr_renderer_init_wl_shm(self.renderer, self.wl_display) then
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
	-- resolve theme/size: config > env > fallback
	local theme = self.config.cursor_theme
	if theme == nil or theme == "" then
		theme = C.getenv("XCURSOR_THEME")
	end
	if theme == nil or theme == "" then
		theme = "default"
	end

	local size = self.config.cursor_size
	if size == nil then
		local env_size = C.getenv("XCURSOR_SIZE")
		size = env_size ~= nil and tonumber(ffi.string(env_size)) or nil
	end
	if size == nil then
		size = 24
	end

	self.cursor_mgr = C.wlr_xcursor_manager_create(theme, size)
	log.debug("xcursor_manager OK (theme=%s size=%d)", theme, size)

	log.debug("wlr_xcursor_manager_load...")
	if not C.wlr_xcursor_manager_load(self.cursor_mgr, 1) then
		log.error("failed to load xcursor theme %s - falling back visuals may look default", theme)
	end
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
		local event = ffi.cast("struct wlr_seat_pointer_request_set_cursor_event *", data)
		-- only honour requests from the client that owns pointer focus
		if event.seat_client ~= self.seat.pointer_state.focused_client then
			return
		end
		if event.surface then
			C.wlr_cursor_set_surface(self.cursor, event.surface, event.hotspot_x, event.hotspot_y)
		else
			C.wlr_cursor_set_xcursor(self.cursor, self.cursor_mgr, "left_ptr")
		end
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
	C.wlr_xdg_output_manager_v1_create(self.wl_display, self.output_layout)
	log.debug("xdg_output_manager OK")
	C.wlr_gamma_control_manager_v1_create(self.wl_display)
	log.debug("gamma_control OK")
	C.wlr_idle_notifier_v1_create(self.wl_display)
	log.debug("idle_notifier OK")
	C.wlr_content_type_manager_v1_create(self.wl_display, 1)
	log.debug("content_type OK")
	C.wlr_viewporter_create(self.wl_display)
	log.debug("viewporter OK")

	C.wlr_xdg_decoration_manager_v1_create(self.wl_display)
	log.debug("xdg_decoration OK")
	C.wlr_xdg_activation_v1_create(self.wl_display)
	log.debug("xdg_activation OK")
	C.wlr_text_input_manager_v3_create(self.wl_display)
	log.debug("text_input_v3 OK")
	C.wlr_data_control_manager_v1_create(self.wl_display)
	log.debug("data_control OK")
	self.layer_shell = C.wlr_layer_shell_v1_create(self.wl_display, 4)
	log.debug("layer_shell OK")
	C.wlr_foreign_toplevel_manager_v1_create(self.wl_display)
	log.debug("foreign_toplevel OK")
	C.wlr_server_decoration_manager_create(self.wl_display)
	log.debug("server_decoration OK")

	-- initialise custom renderer
	log.debug("initializing custom renderer...")
	local Renderer = require("compositor.renderer.renderer")
	self.custom_renderer = Renderer.new(self.renderer)
	if not self.custom_renderer:init() then
		log.error("failed to initialize custom renderer")
		return false
	end
	log.debug("custom renderer OK")

	-- setup layer shell
	local layer_surface = require("compositor.layer_surface")
	layer_surface.setup(self, self.layer_shell)

	self:_setup_backend_listeners()

	log.info("LuieWM initialized successfully")
	return true
end

function Server:_setup_backend_listeners()
	-- listen for new outputs
	local new_output_cb = function(data)
		self:_on_new_output(ffi.cast("struct wlr_output *", data))
	end
	local new_output_listener = ffi_help.listen_signal(self.backend.events.new_output, new_output_cb)

	-- listen for new input devices
	local new_input_cb = function(data)
		self:_on_new_input(ffi.cast("struct wlr_input_device *", data))
	end
	local new_input_listener = ffi_help.listen_signal(self.backend.events.new_input, new_input_cb)
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

	-- start backend
	if not C.wlr_backend_start(self.backend) then
		log.error("failed to start backend")
		C.wlr_backend_destroy(self.backend)
		C.wl_display_destroy(self.wl_display)
		return false
	end

	-- spawn startup command after wayland_display is set and backend is started
	if self._startup_cmd then
		log.info("spawning startup command: %s", self._startup_cmd)
		local pid = C.fork()
		if pid == 0 then
			-- child process - explicitly set wayland_display in child environment
			C.setenv("WAYLAND_DISPLAY", socket_str, 1)
			C.execl("/bin/sh", "/bin/sh", "-c", self._startup_cmd, nil)
			C._exit(1)
		end
	end

	log.info("running compositor on WAYLAND_DISPLAY=%s", socket_str)

	-- run event loop
	C.wl_display_run(self.wl_display)

	-- cleanup
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
	-- unfocus all
	for _, v in ipairs(self.views) do
		v:unfocus()
	end

	if view then
		log.debug("server: focus_view %s", view:get_title())
		view:focus()
		C.wlr_seat_set_keyboard(self.seat, nil)
		local keyboard = self.keyboards[1]
		if keyboard then
			C.wlr_seat_set_keyboard(self.seat, keyboard)
		end
	else
		log.debug("server: focus_view nil")
	end
end

function Server:_schedule_layout()
	if self._layout_scheduled then
		return
	end
	self._layout_scheduled = true
	log.debug("server: layout scheduled")

	local event_loop = C.wl_display_get_event_loop(self.wl_display)
	local idle = C.wl_event_loop_add_idle(event_loop, function()
		self._layout_scheduled = false
		log.debug("server: running scheduled layout")
		local surface = require("compositor.surface")
		surface._apply_layout(self)
		return 0
	end, nil)
	self._layout_idle = idle
end

return Server
