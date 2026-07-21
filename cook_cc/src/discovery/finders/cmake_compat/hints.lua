-- cook_cc.discovery.finders.cmake_compat.hints — install hints for packages cmake --find-package cannot locate
-- domain:  discovery — registers probes (dependency finders, feature checks); facts in, no work units
-- effects: pure
local HINTS = {
    SDL3          = "apt: libsdl3-dev / brew: sdl3 / dnf: SDL3-devel",
    glfw3         = "apt: libglfw3-dev / brew: glfw / dnf: glfw-devel",
    Vulkan        = "apt: libvulkan-dev / brew: vulkan-headers / dnf: vulkan-devel",
    fmt           = "apt: libfmt-dev / brew: fmt / dnf: fmt-devel",
    nlohmann_json = "apt: nlohmann-json3-dev / brew: nlohmann-json / dnf: json-devel",
}

local M = {}
function M.for_package(name)
    return HINTS[name] or ("check 'cmake --find-package -DNAME=" .. name
        .. " -DCOMPILER_ID=GNU -DLANGUAGE=C -DMODE=EXIST'; install the upstream package or register a project finder")
end
return M
