local Config = {}

Config.defaults = {
    gap = 8,
    border_width = 2,
    focus_color = { 0.3, 0.5, 0.8, 1.0 },
    unfocus_color = { 0.2, 0.2, 0.2, 1.0 },
    background_color = { 0.1, 0.1, 0.12, 1.0 },
    terminal = "kitty",
    launcher = "wofi --show drun",
    browser = "firefox",
    startup_command = nil,
}

function Config.load(path)
    if path then
        local ok, user_config = pcall(dofile, path)
        if ok and type(user_config) == "table" then
            for k, v in pairs(user_config) do
                Config.defaults[k] = v
            end
        end
    end
    return Config.defaults
end

return Config
