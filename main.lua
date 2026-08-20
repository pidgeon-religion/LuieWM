#!/usr/bin/env luajit

-- LuieWM: wayland compositor in luajit

local ffi = require("ffi")

require("bindings.ctypes")

local log = require("util.log")

if log.open() then
	log.info("log file: %s", log.log_path)
end

local cli_args = { ... }

local function main()
	local Server = require("compositor.server")
	local Surface = require("compositor.surface")
	local Input = require("compositor.input_handler")
	local Dwindle = require("wm.dwindle")
	local Config = require("config")

	local startup_cmd = nil
	local config_path = nil
	local debug_mode = false

	local args = cli_args
	local i = 1
	while i <= #args do
		if args[i] == "-s" and i < #args then
			startup_cmd = args[i + 1]
			i = i + 2
		elseif args[i] == "-c" and i < #args then
			config_path = args[i + 1]
			i = i + 2
		elseif args[i] == "-d" then
			log.level = "debug"
			i = i + 1
		elseif args[i] == "-h" or args[i] == "--help" then
			print("Usage: luajit main.lua [options]")
			print("  -s <cmd>  Startup command")
			print("  -c <path> Config file path")
			print("  -d        Debug mode")
			print("  -h        Show this help")
			os.exit(0)
		else
			i = i + 1
		end
	end

	local config = Config.load(config_path)

	if debug_mode then
		log.level = "debug"
	end

	log.info("=== LuieWM starting ===")

	local server = Server.new()

	server.dwindle = Dwindle.new({
		gap = config.gap,
		ratio = 0.5,
	})

	server.config = config

	-- initialize server
	if not server:init() then
		log.error("failed to initialize server")
		os.exit(1)
	end

	-- setup surface handling
	Surface.setup(server)

	-- setup input handling
	Input.setup(server)

	-- store startup command for server:run() to spawn after wayland_display is set
	server._startup_cmd = startup_cmd

	-- run the compositor
	local ok = server:run()

	if not ok then
		log.error("compositor exited with error")
		os.exit(1)
	end

	log.info("=== LuieWM exited ===")
end

-- wrap in pcall so any lua err gets logged before dying
local ok, err = pcall(main)
if not ok then
	log.error("fatal: %s", tostring(err))
	io.stderr:write(string.format("\nluiewm crashed: %s\n", tostring(err)))
	if log.log_path then
		io.stderr:write(string.format("see %s for full log\n", log.log_path))
	end
	os.exit(1)
end
