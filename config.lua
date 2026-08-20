local Config = {}

local function hex_to_rgba(hex)
	hex = hex:gsub("#", "")
	return {
		tonumber(hex:sub(1, 2), 16) / 255,
		tonumber(hex:sub(3, 4), 16) / 255,
		tonumber(hex:sub(5, 6), 16) / 255,
		1.0,
	}
end

Config.defaults = {
	gap = 8,
	border_width = 4,
	focus_color = hex_to_rgba("#007acc"),
	unfocus_color = hex_to_rgba("#141414"),
	background_color = { 0.1, 0.1, 0.12, 1.0 },
	terminal = "kitty",
	launcher = "wofi --show drun",
	browser = "firefox",
	startup_command = nil,
}

Config.hex_to_rgba = hex_to_rgba

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
