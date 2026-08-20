local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local View = {}
View.__index = View

function View.new(xdg_toplevel, scene_tree)
    local self = setmetatable({}, View)

    self.xdg_toplevel = xdg_toplevel
    self.xdg_surface = xdg_toplevel.base
    self.wlr_surface = self.xdg_surface.surface
    self.scene_tree = scene_tree

    self.border_rect = nil
    self.xdg_scene_tree = nil

    self.mapped = false
    self.configured = false
    self.initial_configure_acked = false
    self.border_shown = false
    self.floating = false
    self.fullscreen = false
    self.pending_serial = 0
    self.configure_pending = false
    self.configure_queue = {}
    self.initial_configure_sent = false

    self.x = 0
    self.y = 0
    self.width = 0
    self.height = 0

    self.tags = { [1] = true }
    self.focused = false

    self.destroy_listener = nil
    self.map_listener = nil
    self.unmap_listener = nil
    self.request_move_listener = nil
    self.request_resize_listener = nil
    self.request_fullscreen_listener = nil
    self.set_title_listener = nil
    self.set_app_id_listener = nil

    return self
end

function View:get_title()
    if self.xdg_toplevel.title ~= nil then
        return ffi.string(self.xdg_toplevel.title)
    end
    return "unnamed"
end

function View:get_app_id()
    if self.xdg_toplevel.app_id ~= nil then
        return ffi.string(self.xdg_toplevel.app_id)
    end
    return "unknown"
end

function View:set_position(x, y, w, h)
    self.x = x
    self.y = y
    log.debug("set_position: %s -> %d,%d %dx%d", self:get_title(), x, y, w, h)
    self.width = w
    self.height = h

    -- position parent tree
    C.wlr_scene_node_set_position(self.scene_tree.node, x, y)

    -- update border
    local bw = self._server and self._server.config and self._server.config.border_width or 2
    if self.border_rect then
        C.wlr_scene_rect_set_size(self.border_rect, w, h)
        if self.fullscreen or not self.mapped or not self.configured or not self.border_shown then
            -- keep transparent (alpha=0)
            C.wlr_scene_rect_set_color(self.border_rect, ffi.new("float[4]", 0, 0, 0, 0))
        else
            -- show with proper focus/unfocus colour
            local c = self.focused
                and (self._server and self._server.config and self._server.config.focus_color or { 0.0, 0.478, 0.8, 1.0 })
                or (self._server and self._server.config and self._server.config.unfocus_color or { 0.078, 0.078, 0.078, 1.0 })
            C.wlr_scene_rect_set_color(self.border_rect, ffi.new("float[4]", c[1], c[2], c[3], c[4]))
        end
    end
    if self.xdg_scene_tree then
        C.wlr_scene_node_set_position(self.xdg_scene_tree.node, bw, bw)
    end

    if self.mapped then
        self:queue_configure(w - 2 * bw, h - 2 * bw)
    end
end

function View:queue_configure(w, h)
    if not self.configure_pending then
        local serial = C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, w, h)
        self.pending_serial = serial
        self.configure_pending = true
        log.debug("configure: sent %dx%d serial=%u for %s", w, h, serial, self:get_title())
    else
        self.configure_queue = { { w = w, h = h } }
        log.debug("configure: queued %dx%d for %s (queue=%d)", w, h, self:get_title(), #self.configure_queue)
    end
end

function View:on_ack_configure()
    log.debug("ack_configure: received for %s, queue=%d", self:get_title(), self.configure_queue and #self.configure_queue or 0)
    self.configure_pending = false
    if self.configure_queue and #self.configure_queue > 0 then
        local next = table.remove(self.configure_queue, 1)
        local serial = C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, next.w, next.h)
        self.pending_serial = serial
        self.configure_pending = true
        log.debug("ack_configure: sent queued %dx%d serial=%u for %s", next.w, next.h, serial, self:get_title())
    end
end

function View:configure()
    if self.floating then
        local bw = self._server and self._server.config and self._server.config.border_width or 2
        C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, self.width - 2 * bw, self.height - 2 * bw)
    end
end

function View:map()
    self.mapped = true
    log.info("view mapped: %s (%s)", self:get_title(), self:get_app_id())
end

function View:unmap()
    self.mapped = false
    if self.border_rect then
        C.wlr_scene_node_set_enabled(self.border_rect.node, false)
    end
    log.info("view unmapped: %s", self:get_title())
end

function View:destroy()
    log.info("view destroyed: %s", self:get_title())
    self.mapped = false
    -- wlroots destroys the xdg scene tree automatically when the xdg_surface
    -- is destroyed. the parent tree is left as an orphan — small leak but
    -- safe. freeing it first would double-free the xdg scene tree child.
    self.scene_tree = nil
    self.border_rect = nil
    self.xdg_scene_tree = nil
    self.wlr_surface = nil
end

function View:cleanup_listeners()
	if self._destroy_funcs then
		for _, destroy in ipairs(self._destroy_funcs) do
			destroy()
		end
		self._destroy_funcs = nil
	end
	self.commit_listener = nil
	self.map_listener = nil
	self.unmap_listener = nil
	self.destroy_listener = nil
	self.request_move_listener = nil
	self.request_resize_listener = nil
	self.request_fullscreen_listener = nil
	self.ack_configure_listener = nil
	self.new_popup_listener = nil
end

function View:focus()
    if not self.mapped then return end

    self.focused = true
    log.debug("focus: %s", self:get_title())
    C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, true)

    -- border colour
    if self.border_rect and self.mapped and self.configured and not self.fullscreen then
        local c = self._server and self._server.config and self._server.config.focus_color
            or { 0.0, 0.478, 0.8, 1.0 }
        C.wlr_scene_rect_set_color(self.border_rect, ffi.new("float[4]", c[1], c[2], c[3], c[4]))
    end

    local focused_surface = self.xdg_surface.surface
    local seat = self._server.seat

    -- keyboard focus
    local keyboard = C.wlr_seat_get_keyboard(seat)
    if keyboard ~= nil then
        log.debug("focus: keyboard enter for %s", self:get_title())
        C.wlr_seat_keyboard_notify_enter(seat, focused_surface,
            keyboard.keycodes, keyboard.num_keycodes, keyboard.modifiers)
    else
        log.debug("focus: no keyboard for %s", self:get_title())
    end

    -- pointer focus
    local node = self.scene_tree.node
    local lx = ffi.new("int[1]")
    local ly = ffi.new("int[1]")
    if C.wlr_scene_node_coords(node, lx, ly) then
        log.debug("focus: pointer enter for %s at %d,%d", self:get_title(), lx[0] - self.x, ly[0] - self.y)
        local bw = self._server and self._server.config and self._server.config.border_width or 2
        C.wlr_seat_pointer_notify_enter(seat, focused_surface,
            lx[0] - self.x - bw, ly[0] - self.y - bw)
    end
end

function View:unfocus()
    self.focused = false
    if self.mapped then
        C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, false)
    end

    -- border colour
    if self.border_rect and self.mapped and self.configured and not self.fullscreen then
        local c = self._server and self._server.config and self._server.config.unfocus_color
            or { 0.078, 0.078, 0.078, 1.0 }
        C.wlr_scene_rect_set_color(self.border_rect, ffi.new("float[4]", c[1], c[2], c[3], c[4]))
    end
end

function View:update_border()
    if self.border_rect and self.mapped and self.configured and not self.fullscreen then
        local c = self.focused
            and (self._server and self._server.config and self._server.config.focus_color or { 0.0, 0.478, 0.8, 1.0 })
            or (self._server and self._server.config and self._server.config.unfocus_color or { 0.078, 0.078, 0.078, 1.0 })
        C.wlr_scene_rect_set_color(self.border_rect, ffi.new("float[4]", c[1], c[2], c[3], c[4]))
    end
end

function View:close()
    C.wlr_xdg_toplevel_send_close(self.xdg_toplevel)
end

return View
