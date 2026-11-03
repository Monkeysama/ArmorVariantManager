local Support = {}

function Support.read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("a")
    file:close()
    return text
end

function Support.section(source, first, following)
    local start = assert(source:find(first, 1, true), first)
    local stop = assert(source:find(following, start + #first, true), following)
    return source:sub(start, stop - 1)
end

function Support.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Support.copy(item) end
    return result
end

function Support.equal(actual, expected, path)
    path = path or "value"
    assert(type(actual) == type(expected), path .. ": different types")
    if type(expected) ~= "table" then
        assert(actual == expected, path .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
        return
    end
    for key, value in pairs(expected) do Support.equal(actual[key], value, path .. "." .. tostring(key)) end
    for key in pairs(actual) do assert(expected[key] ~= nil, path .. ": unexpected " .. tostring(key)) end
end

return Support
