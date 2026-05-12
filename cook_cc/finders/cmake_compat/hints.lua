local M = {}
function M.for_package(name)
    return "check 'cmake --find-package -DNAME=" .. name
        .. " -DCOMPILER_ID=GNU -DLANGUAGE=C -DMODE=EXIST'; install the upstream package or register a project finder"
end
return M
