local M = {}

M.level = "debug"

local levels = { debug = 1, info = 2, warn = 3, error = 4 }

local log_file = nil

function M.open(path)
    path = path or os.getenv("HOME") .. "/.cache/luiewm.log"
    os.execute("mkdir -p " .. path:match("(.+)/"))
    log_file = io.open(path, "a")
    if log_file then
        log_file:setvbuf("line")
        M.log_path = path
    end
    return log_file ~= nil
end

local function emit(lvl, fmt, ...)
    if levels[lvl] >= levels[M.level] then
        local msg = string.format("[luiewm:%s] %s\n", lvl, string.format(fmt, ...))
        io.stderr:write(msg)
        if log_file then
            log_file:write(msg)
        end
    end
end

function M.debug(fmt, ...) emit("debug", fmt, ...) end
function M.info(fmt, ...)  emit("info", fmt, ...) end
function M.warn(fmt, ...)  emit("warn", fmt, ...) end
function M.error(fmt, ...) emit("error", fmt, ...) end

return M
