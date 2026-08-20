local ffi = require("ffi")

local M = {}

local cb_registry = {}
local cb_next_id = 1

local c_callbacks = {}
local c_listeners = {}

local function make_cb(func)
    local id = cb_next_id
    cb_next_id = cb_next_id + 1
    cb_registry[id] = func

    local cb = ffi.cast("wl_notify_func_t", function(_, data)
        local fn = cb_registry[id]
        if fn then fn(data) end
    end)
    table.insert(c_callbacks, cb)
    return cb, id
end

function M.make_listener(func)
    local listener = ffi.new("struct wl_listener")
    local cb, id = make_cb(func)
    listener.notify = cb
    table.insert(c_listeners, listener)

    local destroyed = false
    return listener, function()
        if not destroyed then
            destroyed = true
            ffi.C.wl_list_remove(listener.link)
            cb_registry[id] = nil
            for i = 1, #c_callbacks do
                if c_callbacks[i] == cb then c_callbacks[i] = nil; break end
            end
            for i = 1, #c_listeners do
                if c_listeners[i] == listener then c_listeners[i] = nil; break end
            end
        end
    end
end

function M.make_listener_with_destroy(func)
    local listener = ffi.new("struct wl_listener")
    local cb, id = make_cb(func)
    listener.notify = cb
    table.insert(c_listeners, listener)

    local destroyed = false
    return listener, function()
        if not destroyed then
            destroyed = true
            ffi.C.wl_list_remove(listener.link)
            cb_registry[id] = nil
            for i = 1, #c_callbacks do
                if c_callbacks[i] == cb then c_callbacks[i] = nil; break end
            end
            for i = 1, #c_listeners do
                if c_listeners[i] == listener then c_listeners[i] = nil; break end
            end
        end
    end
end

function M.list_init(list)
    list.prev = list
    list.next = list
end

function M.list_insert(list, elm)
    elm.prev = list
    elm.next = list.next
    list.next.prev = elm
    list.next = elm
end

function M.list_remove(elm)
    elm.prev.next = elm.next
    elm.next.prev = elm.prev
    elm.prev = nil
    elm.next = nil
end

-- wl_list_empty: check if list has no elements
function M.list_empty(list)
    return list.next == list
end

function M.signal_init(signal)
    M.list_init(signal.listener_list)
end

function M.signal_add(signal, func_or_listener)
    if type(func_or_listener) == "function" then
        local listener, destroy = M.make_listener_with_destroy(func_or_listener)
        M.list_insert(signal.listener_list.prev, listener.link)
        return listener, destroy
    else
        M.list_insert(signal.listener_list.prev, func_or_listener.link)
        return func_or_listener
    end
end

function M.signal_emit(signal, data)
    local cur = signal.listener_list.next
    while cur ~= signal.listener_list do
        local next_node = cur.next
        cur.notify(cur, data)
        cur = next_node
    end
end

function M.listen_signal(signal, func_or_listener)
    return M.signal_add(signal, func_or_listener)
end

function M.signal_remove(listener)
    ffi.C.wl_list_remove(listener.link)
end

-- helper to create a float[4] color array
function M.color(r, g, b, a)
    return ffi.new("float[4]", { r, g, b, a or 1.0 })
end

return M
