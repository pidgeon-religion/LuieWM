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

    self.mapped = false
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
    local node_ptr = self.scene_tree.node
    C.wlr_scene_node_set_position(node_ptr, x, y)
    self.width = w
    self.height = h
    if self.mapped then
        self:queue_configure(w, h)
    end
end

function View:queue_configure(w, h)
    if not self.configure_pending then
        self.width = w
        self.height = h
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
        self.width = next.w
        self.height = next.h
        local serial = C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, next.w, next.h)
        self.pending_serial = serial
        self.configure_pending = true
        log.debug("ack_configure: sent queued %dx%d serial=%u for %s", next.w, next.h, serial, self:get_title())
    end
end

function View:configure()
    if self.floating then
        C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, self.width, self.height)
    end
end

function View:map()
    self.mapped = true
    log.info("view mapped: %s (%s)", self:get_title(), self:get_app_id())
end

function View:unmap()
    self.mapped = false
    log.info("view unmapped: %s", self:get_title())
end

function View:destroy()
    log.info("view destroyed: %s", self:get_title())
    self.mapped = false
    -- wlroots destroys the scene tree automatically when the xdg_surface
    -- is destroyed (it attaches its own listener). do not manually destroy
    -- it here - that would be a double-free.
    self.scene_tree = nil
    self.wlr_surface = nil
end

function View:cleanup_listeners()
    local C = ffi.C
    if self.commit_listener then
        ffi.C.wl_list_remove(self.commit_listener.link)
        self.commit_listener = nil
    end
    if self.map_listener then
        ffi.C.wl_list_remove(self.map_listener.link)
        self.map_listener = nil
    end
    if self.unmap_listener then
        ffi.C.wl_list_remove(self.unmap_listener.link)
        self.unmap_listener = nil
    end
    if self.destroy_listener then
        ffi.C.wl_list_remove(self.destroy_listener.link)
        self.destroy_listener = nil
    end
    if self.request_move_listener then
        ffi.C.wl_list_remove(self.request_move_listener.link)
        self.request_move_listener = nil
    end
    if self.request_resize_listener then
        ffi.C.wl_list_remove(self.request_resize_listener.link)
        self.request_resize_listener = nil
    end
    if self.request_fullscreen_listener then
        ffi.C.wl_list_remove(self.request_fullscreen_listener.link)
        self.request_fullscreen_listener = nil
    end
    if self.ack_configure_listener then
        ffi.C.wl_list_remove(self.ack_configure_listener.link)
        self.ack_configure_listener = nil
    end
    if self.new_popup_listener then
        ffi.C.wl_list_remove(self.new_popup_listener.link)
        self.new_popup_listener = nil
    end
end

function View:focus()
    if not self.mapped then return end

    self.focused = true
    log.debug("focus: %s", self:get_title())
    C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, true)

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
    local success = ffi.new("int[1]")
    local lx = ffi.new("int[1]")
    local ly = ffi.new("int[1]")
    if C.wlr_scene_node_coords(node, lx, ly) then
        log.debug("focus: pointer enter for %s at %d,%d", self:get_title(), lx[0] - self.x, ly[0] - self.y)
        C.wlr_seat_pointer_notify_enter(seat, focused_surface,
            lx[0] - self.x, ly[0] - self.y)
    end
end

function View:unfocus()
    self.focused = false
    if self.mapped then
        C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, false)
    end
end

function View:close()
    C.wlr_xdg_toplevel_send_close(self.xdg_toplevel)
end

return View
