local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C

local XW = {}

-- DRM_FORMAT_ARGB8888 is fourcc 'AR24'; spelling out "ARGB" yields an
-- invalid format that every allocator silently refuses
local DRM_FORMAT_ARGB8888 = 0x34325241
local DRM_MOD_INVALID = 0x00FFFFFFFFFFFFFFFF
local WLR_BUFFER_DATA_PTR_ACCESS_WRITE = 2

local function allocate_cursor_buffer(server, img)
	-- the shm allocator is cpu-backed and immune to gbm/driver quirks, so
	-- it is tried first; the gbm fallback rarely matters but costs nothing
	if server.shm_allocator == nil then
		C.wlr_renderer_init_wl_shm(server.renderer, server.wl_display)
		server.shm_allocator = C.wlr_shm_allocator_create(server.renderer)
		log.debug("xw cursor: shm_allocator=%s", tostring(server.shm_allocator ~= nil))
	end
	if server.shm_allocator ~= nil then
		-- shm has no modifiers concept, but be explicit about what we accept
		local attempts = {
			{ DRM_MOD_INVALID },
			{ 0 },
			{},
		}
		for _, mods in ipairs(attempts) do
			local format = ffi.new("struct wlr_drm_format")
			local arr = ffi.new("uint64_t[?]", math.max(1, #mods), mods)
			format.format = DRM_FORMAT_ARGB8888
			format.modifiers = arr
			format.len = #mods
			format.capacity = #mods
			local buf =
				C.wlr_allocator_create_buffer(server.shm_allocator, tonumber(img.width), tonumber(img.height), format)
			if buf ~= nil then
				log.debug("xw cursor: shm buffer OK %dx%d", tonumber(img.width), tonumber(img.height))
				return buf
			end
		end
		log.warn("shm allocator refused the cursor buffer, falling back to gbm")
	end

	-- allocator pickiness varies by driver (hybrid intel/nvidia here); try
	-- modifier sets from most to least standard
	local attempts = {
		{ 0, DRM_MOD_INVALID },
		{ DRM_MOD_INVALID },
		{ 0 },
	}
	for _, mods in ipairs(attempts) do
		local format = ffi.new("struct wlr_drm_format")
		local arr = ffi.new("uint64_t[?]", #mods, mods)
		format.format = DRM_FORMAT_ARGB8888
		format.modifiers = arr
		format.len = #mods
		format.capacity = #mods
		local buf = C.wlr_allocator_create_buffer(server.allocator, tonumber(img.width), tonumber(img.height), format)
		if buf ~= nil then
			return buf
		end
	end
	return nil
end

local function apply_cursor(server)
	local xc = C.wlr_xcursor_manager_get_xcursor(server.cursor_mgr, "left_ptr", 1)
	if xc == nil or xc.image_count == 0 then
		log.warn("no left_ptr image for the xwayland cursor")
		return
	end
	local img = xc.images[0]

	local buf = allocate_cursor_buffer(server, img)
	if buf == nil then
		log.warn("failed to allocate the xwayland cursor buffer")
		return
	end

	local out_data = ffi.new("void *[1]")
	local out_format = ffi.new("uint32_t[1]")
	local out_stride = ffi.new("size_t[1]")
	if
		not C.wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_WRITE, out_data, out_format, out_stride)
	then
		log.warn("failed to map the xwayland cursor buffer")
		return
	end
	local src = ffi.cast("const uint8_t *", img.buffer)
	local dst = ffi.cast("uint8_t *", out_data[0])
	local row_bytes = img.width * 4
	for row = 0, img.height - 1 do
		ffi.copy(dst + row * tonumber(out_stride[0]), src + row * row_bytes, row_bytes)
	end
	C.wlr_buffer_end_data_ptr_access(buf)

	-- keep alive for the lifetime of the xwm connection
	server.xw_cursor_buffer = buf
	C.wlr_xwayland_set_cursor(server.xwayland, buf, img.hotspot_x, img.hotspot_y)
end

function XW.setup(server)
	-- eager start: lazy mode would leave DISPLAY unset until the first X
	-- client connects, which deadlocks spawned clients
	server.xwayland = C.wlr_xwayland_create(server.wl_display, server.compositor, false)
	if server.xwayland == nil then
		log.warn("xwayland unavailable")
		return false
	end

	ffi_help.signal_add(
		server.xwayland.events.ready,
		ffi_help.make_listener(function()
			-- compositor should export DISPLAY for clients (lazy mode spawns
			-- Xwayland only once something connects)
			C.setenv("DISPLAY", ffi.string(server.xwayland.display_name), 1)
			log.info("xwayland ready on %s", ffi.string(server.xwayland.display_name))
			C.wlr_xwayland_set_seat(server.xwayland, server.seat)
			apply_cursor(server)
		end)
	)

	ffi_help.signal_add(
		server.xwayland.events.new_surface,
		ffi_help.make_listener(function(data)
			local xsurface = ffi.cast("struct wlr_xwayland_surface *", data)
			require("wm.xw.view").create(server, xsurface)
		end)
	)

	return true
end

return XW
