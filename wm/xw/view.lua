local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C
local Texture = require("compositor.renderer.texture")

local XView = {}
XView.__index = XView

-- window types that spawn as floats rather than joining the tile tree
local FLOAT_TYPES = {
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DIALOG,
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_POPUP_MENU,
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_TOOLTIP,
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_UTILITY,
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH,
	C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_NOTIFICATION,
}

local function should_float(server, xsurface)
	if xsurface.parent ~= nil then
		return true
	end
	if xsurface.override_redirect then
		return true
	end
	for _, t in ipairs(FLOAT_TYPES) do
		if C.wlr_xwayland_surface_has_window_type(xsurface, t) then
			return true
		end
	end
	return false
end

-- surface.lua owns layouts; required lazily to dodge the load cycle
local function Surface_apply_layout(server)
	local ok, surface_mod = pcall(require, "compositor.surface")
	if ok and surface_mod._apply_layout ~= nil then
		surface_mod._apply_layout(server)
	end
end

function XView.create(server, xsurface)
	local self = setmetatable({}, XView)

	self.xsurface = xsurface
	self.wlr_surface = nil -- valid between associate/dissociate
	self.texture = nil
	self.subsurfaces = nil
	self.render_geo = nil -- x11 windows have no csd margins

	self.mapped = false
	self.visible_on_tag = false
	self.ever_mapped = false
	self.focused = false
	self.floating = should_float(server, xsurface)
	self.fullscreen = false
	self.opacity = 1.0

	self.border_width = 0
	if xsurface.decorations == C.WLR_XWAYLAND_SURFACE_DECORATIONS_ALL then
		self.border_width = server.config and server.config.border_width or 4
	end

	-- xwayland positions are already absolute layout coords
	self.x = xsurface.x
	self.y = xsurface.y
	self.width = math.max(1, xsurface.width)
	self.height = math.max(1, xsurface.height)
	self.texture_width = 0
	self.texture_height = 0

	self.tags = { [server.current_tag] = true }
	self._server = server

	server:add_view(self)
	-- NOTE: views join the dwindle tree on first map (see map handlers),
	-- not here -- many X11 clients create hidden helper windows that would
	-- otherwise claim tile slots forever without ever rendering

	self:_setup_listeners(server)

	-- synthetic manage configure (ICCCM): some clients - notably Qt splash
	-- windows - refuse to paint until the WM acknowledges their geometry,
	-- and wlroots only reports map after that first buffer commit
	if not xsurface.override_redirect and xsurface.width > 0 then
		self:set_position(self.x, self.y, self.width, self.height)
	end

	log.info("new xwayland surface: %s (class=%s float=%s)", self:get_title(), self:get_app_id(), tostring(self.floating))
	return self
end

function XView:get_title()
	if self.xsurface ~= nil and self.xsurface.title ~= nil then
		return ffi.string(self.xsurface.title)
	end
	return "x11"
end

function XView:get_app_id()
	if self.xsurface ~= nil and self.xsurface.class ~= nil then
		return ffi.string(self.xsurface.class)
	end
	return "x11"
end

-- x11 clients have no ack round-trip; push geometry straight through
function XView:set_position(x, y, w, h)
	self.x = x
	self.y = y
	self.width = math.max(1, w)
	self.height = math.max(1, h)
	if self.xsurface ~= nil then
		C.wlr_xwayland_surface_configure(
			self.xsurface,
			math.floor(x),
			math.floor(y),
			math.floor(self.width),
			math.floor(self.height)
		)
	end
end

function XView:sync_from_surface()
	-- floats/or windows place themselves; tiled views keep our geometry
	if not self.floating and not self.xsurface.override_redirect then
		return
	end
	self.x = self.xsurface.x
	self.y = self.xsurface.y
	self.width = math.max(1, self.xsurface.width)
	self.height = math.max(1, self.xsurface.height)
end

function XView:focus()
	if not self.mapped or self.xsurface == nil then
		return
	end
	self.focused = true
	log.debug("focus: %s", self:get_title())
	C.wlr_xwayland_surface_activate(self.xsurface, true)

	local seat = self._server.seat
	local keyboard = C.wlr_seat_get_keyboard(seat)
	if keyboard ~= nil and self.wlr_surface ~= nil then
		C.wlr_seat_keyboard_notify_enter(seat, self.wlr_surface,
			keyboard.keycodes, keyboard.num_keycodes, keyboard.modifiers)
	end
end

function XView:unfocus()
	if not self.focused then
		return
	end
	self.focused = false
	if self.xsurface ~= nil then
		C.wlr_xwayland_surface_activate(self.xsurface, false)
	end
end

function XView:close()
	if self.xsurface ~= nil then
		C.wlr_xwayland_surface_close(self.xsurface)
	end
end

function XView:update_border()
	-- border is drawn by the renderer each frame
end

function XView:cleanup_listeners()
	if self._destroy_funcs then
		for _, destroy in ipairs(self._destroy_funcs) do
			destroy()
		end
		self._destroy_funcs = nil
	end
end

function XView:_setup_listeners(server)
	local xsurface = self.xsurface
	self._destroy_funcs = {}

	local function on(signal, fn)
		local listener, destroy = ffi_help.make_listener_with_destroy(fn)
		ffi_help.signal_add(signal, listener)
		table.insert(self._destroy_funcs, destroy)
	end

	-- listeners for whatever wlr_surface is currently associated; they must
	-- detach before that surface's resource dies or wlroots asserts
	local surface_cleanup = nil

	local function detach_surface_listeners()
		if surface_cleanup then
			for _, destroy in ipairs(surface_cleanup) do
				destroy()
			end
			surface_cleanup = nil
		end
	end

	on(xsurface.events.dissociate, function()
		detach_surface_listeners()
	end)

	on(xsurface.events.associate, function()
		self.wlr_surface = xsurface.surface
		if self.wlr_surface == nil then
			return
		end

		log.debug(
			"xwayland associate %s: dims=%dx%d pos=%d,%d surface_mapped=%s",
			self:get_title(),
			xsurface.width,
			xsurface.height,
			xsurface.x,
			xsurface.y,
			tostring(xsurface.surface.mapped)
		)

		surface_cleanup = {}
		local function on_surface(signal, fn)
			local listener, destroy = ffi_help.make_listener_with_destroy(fn)
			ffi_help.signal_add(signal, listener)
			table.insert(surface_cleanup, destroy)
		end

		-- wlroots asserts if we outlive the surface resource
		on_surface(self.wlr_surface.events.destroy, detach_surface_listeners)

		on_surface(self.wlr_surface.events.commit, function()
			if C.wlr_surface_has_buffer(self.wlr_surface) then
				local tex = C.wlr_surface_get_texture(self.wlr_surface)
				if tex ~= nil then
					if not self.texture then
						self.texture = Texture.from_wlr_texture(tex)
					else
						self.texture:update_wlr_texture(tex)
					end
				end
				local tw = self.wlr_surface.current.width
				local th = self.wlr_surface.current.height
				if tw ~= self.texture_width or th ~= self.texture_height then
					log.debug(
						"x11 commit %s: tex=%dx%d view=%dx%d@%d,%d",
						self:get_title(),
						tw,
						th,
						self.width,
						self.height,
						self.x,
						self.y
					)
				end
				self.texture_width = tw
				self.texture_height = th
			end
		end)

		-- association can race ahead of our listeners; synthesize whatever we
		-- already missed instead of waiting for events that already fired
		if self.wlr_surface.mapped then
			if not self.floating and should_float(server, xsurface) then
				self.floating = true
				log.info(
					"xwayland late float reclass: %s (%s)",
					self:get_title(),
					self:get_app_id()
				)
				if server.dwindle then
					server.dwindle:remove_view(self)
				end
			end
			if not self.floating and server.dwindle and not self._dwindle_node then
				server.dwindle:add_view(self, server.current_tag)
			end
			self.mapped = true
			self.ever_mapped = true
			self.visible_on_tag = true
			if
				self.floating
				and not xsurface.override_redirect
				and C.wlr_xwayland_surface_has_window_type(
					xsurface,
					C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH
				)
			then
				local out = server.outputs[1] and server.outputs[1].wlr_output or nil
				if out ~= nil then
					local w = math.max(1, xsurface.width)
					local h = math.max(1, xsurface.height)
					self:set_position(
						math.floor((out.width - w) / 2),
						math.floor((out.height - h) / 2),
						w,
						h
					)
				end
			elseif self.floating and not xsurface.override_redirect then
				self:set_position(self.x, self.y, math.max(1, xsurface.width), math.max(1, xsurface.height))
			end
			log.info("xwayland view mapped (late): %s (%s)", self:get_title(), self:get_app_id())
			for t, _ in pairs(self.tags) do
				if t == server.current_tag then
					server:focus_view(self)
					break
				end
			end
			Surface_apply_layout(server)
		end

		on_surface(self.wlr_surface.events.map, function()
			-- _NET_WM_WINDOW_TYPE / parent info often arrives after surface
			-- creation; reclassify before deciding to tile this window
			if not self.floating and should_float(server, xsurface) then
				self.floating = true
				log.info(
					"xwayland late float reclass: %s (%s)",
					self:get_title(),
					self:get_app_id()
				)
				if server.dwindle then
					server.dwindle:remove_view(self)
				end
			end
			-- first map is when a tiled window claims its slot in the tree
			if not self.floating and server.dwindle and not self._dwindle_node then
				server.dwindle:add_view(self, server.current_tag)
			end
			self.mapped = true
			self.ever_mapped = true
			self.visible_on_tag = true
			-- splash windows are centered by the tiler, not self-placed
			if
				self.floating
				and not xsurface.override_redirect
				and C.wlr_xwayland_surface_has_window_type(
					xsurface,
					C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH
				)
			then
				local out = server.outputs[1] and server.outputs[1].wlr_output or nil
				if out ~= nil then
					local w = math.max(1, xsurface.width)
					local h = math.max(1, xsurface.height)
					self:set_position(
						math.floor((out.width - w) / 2),
						math.floor((out.height - h) / 2),
						w,
						h
					)
				end
			elseif self.floating and not xsurface.override_redirect then
				-- redundant safety: the manage configure already went out at
				-- create time, but late-created floats are cheap to re-ack
				self:set_position(self.x, self.y, math.max(1, xsurface.width), math.max(1, xsurface.height))
			end
			log.info("xwayland view mapped: %s (%s)", self:get_title(), self:get_app_id())
			for t, _ in pairs(self.tags) do
				if t == server.current_tag then
					server:focus_view(self)
					break
				end
			end
			Surface_apply_layout(server)
		end)

		on_surface(self.wlr_surface.events.unmap, function()
			self.mapped = false
			self.visible_on_tag = false
			log.info(
				"xwayland view unmapped: %s (surface_mapped=%s)",
				self:get_title(),
				tostring(self.wlr_surface and self.wlr_surface.mapped)
			)
			if self.texture then
				self.texture:destroy()
				self.texture = nil
			end
			if self.focused then
				server:focus_view(nil)
				local next_view = nil
				for _, v in ipairs(server.views) do
					if v.mapped and v ~= self and v.visible_on_tag then
						next_view = v
						break
					end
				end
				if next_view then
					server:focus_view(next_view)
				end
			end
			Surface_apply_layout(server)
		end)
	end)

	on(xsurface.events.dissociate, function()
		detach_surface_listeners()
		if self.texture then
			self.texture:destroy()
			self.texture = nil
		end
		self.wlr_surface = nil
	end)

	-- splash windows are centered by the tiler; window_type loads async so
	-- this may fire before the client's first paint - catch it early to
	-- avoid a visible jump from the app-chosen position
	on(xsurface.events.set_window_type, function()
		if
			self.ever_mapped
			or xsurface.override_redirect
			or not self.floating
		then
			return
		end
		if C.wlr_xwayland_surface_has_window_type(xsurface, C.WLR_XWAYLAND_NET_WM_WINDOW_TYPE_SPLASH) then
			local out = server.outputs[1] and server.outputs[1].wlr_output or nil
			if out ~= nil then
				local w = math.max(1, xsurface.width)
				local h = math.max(1, xsurface.height)
				self:set_position(math.floor((out.width - w) / 2), math.floor((out.height - h) / 2), w, h)
			end
		end
	end)

	on(xsurface.events.request_configure, function(data)
		local ev = ffi.cast("struct wlr_xwayland_surface_configure_event *", data)
		-- tiled views keep the layout's geometry; floats honor requests
		if self.floating or self.xsurface.override_redirect then
			self.x = ev.x
			self.y = ev.y
			self.width = math.max(1, ev.width)
			self.height = math.max(1, ev.height)
			C.wlr_xwayland_surface_configure(xsurface, ev.x, ev.y, ev.width, ev.height)
		end
	end)

	on(xsurface.events.request_fullscreen, function()
		self.fullscreen = not self.fullscreen
		C.wlr_xwayland_surface_set_fullscreen(xsurface, self.fullscreen)
		if self.fullscreen then
			for _, output_data in ipairs(server.outputs) do
				local out = output_data.wlr_output
				self:set_position(0, 0, out.width, out.height)
			end
		elseif not self.floating then
			Surface_apply_layout(server)
		end
	end)

	on(xsurface.events.request_close, function()
		self:close()
	end)

	on(xsurface.events.set_geometry, function()
		self:sync_from_surface()
	end)

	on(xsurface.events.destroy, function()
		log.info("xwayland view destroyed: %s", self:get_title())
		self:cleanup_listeners()
		if self.texture then
			self.texture:destroy()
			self.texture = nil
		end
		server:remove_view(self)
		if server.dwindle then
			server.dwindle:remove_view(self)
		end
		if self.focused then
			server:focus_view(nil)
		end
		self.xsurface = nil
		Surface_apply_layout(server)
	end)
end

return XView
