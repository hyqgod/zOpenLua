local json = require("cjson")
local util = loadMod("core.util")
local exception = loadMod("core.exception")
local response = loadMod("core.response")
local ctrlBase = loadMod("core.base.ctrl")
local sysConf = loadMod("config.system")
local actConf = loadMod("config.action")
local errConf = loadMod("config.error")


local MODULE_PATTERN = "%-%-%-%s*(%S+)%s*\nlocal%s*" .. moduleName .. "%s*="
local COMMENT_PATTERN = "%-%-%-%s*(%S+)%s*\n%-%-%s*(.-)%s*\nfunction%s+" .. moduleName .. ":([%w_]+)%s*%(%s*%)"
local PARAM_PATTERN = "@param%s*([%w_]+)%s*([%w_]+)%s*([^\n]*)"
local RESULT_PATTERN = "@return%s*([^\n]*)%s*"
local ERROR_PATTERN = "@error%s*([^\n]*)%s*"
local ECODE_PATTERN = "([%w_]+%.[%w_]+)"

--- 开发控制器
local Develop = {}

--- 分析模块对应文件的注释并获得模块信息
--
-- @param string module 模块名
-- @return table 模块信息
local function parseModule(module)
    local moduleName = util.string:capital(module)

    local path = sysConf.ROOT_PATH .. "/code/ctrl/" .. module .. ".lua"
    local content = util:readFile(path)
    local moduleDesc = content:match(MODULE_PATTERN)

    if not moduleDesc then
        exception:raise("core.parseFailed", { file = path, module = module })
    end

    local info = { desc = moduleDesc, methods = {} }

    for methodDesc, methodComment, methodName in content:gmatch(COMMENT_PATTERN) do
        local errors = {}
        local params = {}

        for paramType, paramName, paramDesc in methodComment:gmatch(PARAM_PATTERN) do
            paramType = paramType:lower()

            if paramType == "number" then
                paramType = "Int"
            elseif paramType == "string" then
                paramType = "String"
            else
                exception:raise("core.parseFailed", {
                    file = path,
                    module = module,
                    method = methodName,
                    param = paramName,
                    type = paramType
                })
            end

            params[#params + 1] = { type = paramType, name = paramName, desc = paramDesc }
        end

        for errCodes in methodComment:gmatch(ERROR_PATTERN) do
            for errCode in errCodes:gmatch(ECODE_PATTERN) do
                errors[#errors + 1] = errCode
            end
        end

        info.methods[methodName] = {
            method = methodName,
            params = params,
            errors = errors,
            result = methodComment:match(RESULT_PATTERN) or "",
            desc = methodDesc
        }
    end

    return info
end

--- 读取模块信息
--
-- @param string module 模块名
-- @return table 模块信息
local function getModuleInfo(module)
    if not ngx.ctx[Develop] then
        ngx.ctx[Develop] = {}
    end

    if not ngx.ctx[Develop][module] then
        ngx.ctx[Develop][module] = parseModule(module)
    end

    return ngx.ctx[Develop][module]
end

--- 过滤器
--
-- @return boolean
function Develop:filter()
    if not sysConf.DEBUG_MODE then
        exception:raise("core.forbidden", { debug = sysConf.DEBUG_MODE })
    end
end

--- 生成API文档数据文件
--
-- @return {"ok":true}
function Develop:makeDocs()
    local ops, errors, modules = {}, {}, {}

    for eType, eCodes in pairs(errConf) do
        for eCode, eMsg in pairs(eCodes) do
            errors[eType .. "." .. eCode] = eMsg
        end
    end

    for op, act in pairs(actConf) do
        local action = table.concat(act, ".")
        local module, method = unpack(act)
        local moduleInfo = getModuleInfo(module)
        local methodInfo = moduleInfo.methods[method]

        if not methodInfo then
            exception:raise(exception.BAD_ACTION, { module = module, method = method })
        end

        ops[util:strval(op)] = action

        if not modules[module] then
            modules[module] = {
                name = module,
                desc = moduleInfo.desc,
                methods = {}
            }
        end

        modules[module].methods[method] = {
            op = op,
            action = action,
            errors = methodInfo.errors,
            params = methodInfo.params,
            result = methodInfo.result,
            desc = methodInfo.desc
        }
    end

    local jsPath = ngx.var.document_root .. "/docs/js/docs.data.js"
    local docsData = {
        version = "1.0",
        domain = ngx.var.server_name,
        ops = ops,
        errors = errors,
        modules = modules
    }

    util:writeFile(jsPath, "var docsData = " .. json.encode(docsData) .. ";\n")
    response:reply({ ok = true, docsData = docsData })
end

return util:inherit(Develop, ctrlBase)

