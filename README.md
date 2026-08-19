LuieWM (working title) - a Wayland compositor and window manager written in entirely Lua/LuaJIT
Targets wlroots 0.20

How to run

Open a bare tty, cd into the directory where the main.lua file is, and run
luajit main.lua
running on a tty with another wayland compositor active will cause most inputs within apps not to work
it requires luajit, wl-roots-0.20, wayland, xkbcommon, libdrm, pixman, EGL/GLESv2 (only tests have been on arch, other distros will prolly work)
Flags
-s runs a startup command after WAYLAND_DISPLAY is set
-d toggles debug logging

Problems

Nested wayland (named above)
constant crashes/freezes
No layer-shell, xwayland, screencopy etc

bro i hate readmes so damn much
hi yracil if youre reading this
