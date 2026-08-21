local log = require("util.log")

local Dwindle = {}
Dwindle.__index = Dwindle

local Node = {}
Node.__index = Node

local function new_node()
    return setmetatable({
        split_h = true,
        ratio = 0.5,
        children = nil,
        view = nil,
        x = 0, y = 0, w = 0, h = 0,
    }, Node)
end

function Dwindle.new(config)
    local self = setmetatable({}, Dwindle)
    config = config or {}
    self.gap = config.gap or 8
    self.ratio = config.ratio or 0.5
    self.roots = {} -- per-tag tree roots
    self.focused = {} -- per-tag focused nodes
    self.current_tag = 1
    self.views = {} -- flat list of { view, node, tag }
    self.pending_layout = false
    self.layout_params = nil
    return self
end

function Dwindle:get_root(tag)
    return self.roots[tag or self.current_tag]
end

-- attach a detached node to a tag's tree, splitting against the focused leaf
function Dwindle:_insert_node(tag, node)
    local root = self.roots[tag]
    if not root or (not root.view and not root.children) then
        self.roots[tag] = node
        self.focused[tag] = node
        return
    end

    local target = self.focused[tag] or self:find_leaf(root)
    if not target or target.children then
        target = self:find_leaf(root)
    end
    if not target then
        self.roots[tag] = node
        self.focused[tag] = node
        return
    end

    local parent = new_node()
    parent.split_h = target.w >= target.h
    parent.ratio = self.ratio
    parent.children = { target, node }

    if root == target then
        self.roots[tag] = parent
    else
        self:replace_child(root, target, parent)
    end

    self.focused[tag] = node
end

function Dwindle:add_view(view, tag_id)
    local tag = tag_id or self.current_tag or 1
    local node = new_node()
    node.view = view
    view._dwindle_node = node
    table.insert(self.views, { view = view, node = node, tag = tag })
    self:_insert_node(tag, node)
end

-- move an existing view's node to another tag's tree
function Dwindle:set_view_tag(view, new_tag)
    for _, entry in ipairs(self.views) do
        if entry.view == view then
            local old = entry.tag
            if old == new_tag then return end
            if view._dwindle_node then
                self:remove_node(old, view._dwindle_node)
                self:_insert_node(new_tag, view._dwindle_node)
            end
            entry.tag = new_tag
            return
        end
    end
end

function Dwindle:remove_view(view)
    local tag
    for i, entry in ipairs(self.views) do
        if entry.view == view then
            tag = entry.tag
            table.remove(self.views, i)
            break
        end
    end

    if view._dwindle_node and tag then
        self:remove_node(tag, view._dwindle_node)
        view._dwindle_node = nil
    end

    local f = tag and self.focused[tag]
    if f and f.view == view then
        self.focused[tag] = self.roots[tag]
    end
end

function Dwindle:remove_node(tag, node)
    local root = self.roots[tag]
    if not root then return end

    local parent = self:find_parent(root, node)
    if not parent or not parent.children then
        if root == node then
            self.roots[tag] = new_node()
        end
        return
    end

    local sibling
    for _, child in ipairs(parent.children) do
        if child ~= node then
            sibling = child
            break
        end
    end

    if not sibling then return end

    if root == parent then
        self.roots[tag] = sibling
    else
        local grandparent = self:find_parent(root, parent)
        if grandparent and grandparent.children then
            for i, child in ipairs(grandparent.children) do
                if child == parent then
                    grandparent.children[i] = sibling
                    break
                end
            end
        end
    end
end

function Dwindle:find_parent(root, target)
    if not root.children then return nil end
    for _, child in ipairs(root.children) do
        if child == target then return root end
        local found = self:find_parent(child, target)
        if found then return found end
    end
    return nil
end

function Dwindle:replace_child(root, old, new)
    if not root.children then return end
    for i, child in ipairs(root.children) do
        if child == old then
            root.children[i] = new
            return
        end
        self:replace_child(child, old, new)
    end
end

function Dwindle:find_leaf(node)
    if not node.children then
        if not node.view or node.view.mapped then
            return node
        end
        return nil
    end
    for _, child in ipairs(node.children) do
        local leaf = self:find_leaf(child)
        if leaf then return leaf end
    end
    return nil
end

function Dwindle:focus_next(tag)
    local views = {}
    for _, entry in ipairs(self.views) do
        if entry.view.mapped then
            if tag then
                local on_tag = false
                for t, _ in pairs(entry.view.tags) do
                    if t == tag then on_tag = true; break end
                end
                if on_tag then table.insert(views, entry) end
            else
                table.insert(views, entry)
            end
        end
    end
    if #views == 0 then return nil end

    local current_idx = nil
    for i, entry in ipairs(views) do
        if entry.view.focused then
            current_idx = i
            break
        end
    end

    local next_idx
    if current_idx then
        next_idx = (current_idx % #views) + 1
    else
        next_idx = 1
    end

    local next_view = views[next_idx].view
    self.focused[tag or self.current_tag] = views[next_idx].node
    return next_view
end

function Dwindle:focus_prev(tag)
    local views = {}
    for _, entry in ipairs(self.views) do
        if entry.view.mapped then
            if tag then
                local on_tag = false
                for t, _ in pairs(entry.view.tags) do
                    if t == tag then on_tag = true; break end
                end
                if on_tag then table.insert(views, entry) end
            else
                table.insert(views, entry)
            end
        end
    end
    if #views == 0 then return nil end

    local current_idx = nil
    for i, entry in ipairs(views) do
        if entry.view.focused then
            current_idx = i
            break
        end
    end

    local prev_idx
    if current_idx then
        prev_idx = current_idx - 1
        if prev_idx < 1 then prev_idx = #views end
    else
        prev_idx = #views
    end

    local prev_view = views[prev_idx].view
    self.focused[tag or self.current_tag] = views[prev_idx].node
    return prev_view
end

function Dwindle:get_focused_view()
    local f = self.focused[self.current_tag]
    if f and f.view then
        return f.view
    end
    return nil
end

function Dwindle:layout(x, y, w, h, tag)
    self.current_tag = tag or self.current_tag
    self.layout_params = {x, y, w, h, tag}
    self.pending_layout = true
    log.debug("dwindle: layout scheduled %dx%d tag=%d", w, h, tag)
end

function Dwindle:apply_pending_layout()
    if self.pending_layout and self.layout_params then
        local x, y, w, h, tag = unpack(self.layout_params)
        local root = self.roots[tag]
        if root then
            self:layout_node(root, x, y, w, h, tag)
        end
        self.pending_layout = false
        self.layout_params = nil
    end
end

function Dwindle:layout_node(node, x, y, w, h, tag)
    node.x = x
    node.y = y
    node.w = w
    node.h = h

    if not node.children then
        if node.view then
            local visible = false
            if tag then
                for t, _ in pairs(node.view.tags) do
                    if t == tag then visible = true; break end
                end
            else
                visible = true
            end
            if visible and node.view.mapped and not node.view.floating then
                local g = self.gap
                local gx = x + g
                local gy = y + g
                local gw = math.max(1, w - 2 * g)
                local gh = math.max(1, h - 2 * g)
                node.view:set_position(gx, gy, gw, gh)
            end
        end
        return
    end

    if #node.children ~= 2 then return end

    local first = node.children[1]
    local second = node.children[2]

    if node.split_h then
        local split_w = math.floor(w * node.ratio)
        self:layout_node(first, x, y, split_w, h, tag)
        self:layout_node(second, x + split_w, y, w - split_w, h, tag)
    else
        local split_h = math.floor(h * node.ratio)
        self:layout_node(first, x, y, w, split_h, tag)
        self:layout_node(second, x, y + split_h, w, h - split_h, tag)
    end
end

function Dwindle:swap_focused_with_next()
    local tag = self.current_tag
    local focused = self.focused[tag]
    local root = self.roots[tag]
    if not focused or not root then return false end

    if not focused.children then
        local parent = self:find_parent(root, focused)
        if parent and parent.children then
            for i, child in ipairs(parent.children) do
                if child == focused then
                    local other_idx = i % 2 + 1
                    parent.children[i], parent.children[other_idx] =
                        parent.children[other_idx], parent.children[i]
                    return true
                end
            end
        end
    end
    return false
end

function Dwindle:count_mapped(tag)
    local count = 0
    for _, entry in ipairs(self.views) do
        if entry.view.mapped then
            if not tag or entry.tag == tag then
                count = count + 1
            end
        end
    end
    return count
end

function Dwindle:toggle_float(view)
    view.floating = not view.floating
end

function Dwindle:get_all_views()
    local result = {}
    for _, entry in ipairs(self.views) do
        table.insert(result, entry.view)
    end
    return result
end

return Dwindle
