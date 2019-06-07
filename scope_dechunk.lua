#!/usr/bin/lua

--[[
    Decode Chunks for Lua Scope
    A Lua 5.1 binary chunk disassembler
    LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]

package.path = package.path .. ";./?.lua;/usr/src/?.lua"

require("scope_config")

-- XXX is a hack, only temporary, hopefully.
config = get_config()

--
-- brief display mode with indentation style option
--
local function BriefLine(desc)
    if ShouldIPrintXYZ() then return end
    if DISPLAY_INDENT then
        WriteLine(string.rep(GetOutputSep(), level - 1)..desc)
    else
        WriteLine(desc)
    end
end

--
-- describe a string (size, data pairs)
--
local function DescString(chunk, s, pos)
    local len = string.len(s or "")
    if len > 0 then 
        len = len + 1   -- add the NUL back
        s = s.."\0"     -- was removed by LoadString
    end
    FormatLine(chunk, GetLuaSizetSize(), string.format("string size (%s)", len), pos)
    if len == 0 then return end
    pos = pos + GetLuaSizetSize()
    if len <= GetOutputHexWidth() then
        FormatLine(chunk, len, EscapeString(s, 1), pos)
    else
        -- split up long strings nicely, easier to view
        while len > 0 do
            local seg_len = GetOutputHexWidth()
            if len < seg_len then seg_len = len end
            local seg = string.sub(s, 1, seg_len)
            s = string.sub(s, seg_len + 1)
            len = len - seg_len
            FormatLine(chunk, seg_len, EscapeString(seg, 1), pos, len > 0)
            pos = pos + seg_len
        end
    end
end

--
-- describe line information
--
local function DescLines(chunk, func)
    local size = func.sizelineinfo
    local pos = func.pos_lineinfo
    DescLine("* lines:")
    FormatLine(chunk, GetLuaIntSize(), "sizelineinfo ("..size..")", pos)
    pos = pos + GetLuaIntSize()
    local WIDTH = WidthOf(size)
    DescLine("[pc] (line)")
    for i = 1, size do
        local s = string.format("[%s] (%s)", ZeroPad(i, WIDTH), func.lineinfo[i])
        FormatLine(chunk, GetLuaIntSize(), s, pos)
        pos = pos + GetLuaIntSize()
    end
    -- mark significant lines in source listing
    SourceMark(func)
end

--
-- describe locals information
--
local function DescLocals(chunk, func)
    local n = func.sizelocvars
    DescLine(chunk, "* locals:")
    FormatLine(chunk, GetLuaIntSize(), "sizelocvars ("..n..")", func.pos_locvars)
    for i = 1, n do
        local locvar = func.locvars[i]
        DescString(chunk, locvar.varname, locvar.pos_varname)
        DescLine(chunk, "local ["..(i - 1).."]: "..EscapeString(locvar.varname))
        BriefLine(".local"..GetOutputSep()..EscapeString(locvar.varname, 1)
                    ..GetOutputSep()..GetOutputComment()..(i - 1))
        FormatLine(chunk, GetLuaIntSize(), "  startpc ("..locvar.startpc..")", locvar.pos_startpc)
        FormatLine(chunk, GetLuaIntSize(), "  endpc   ("..locvar.endpc..")",locvar.pos_endpc)
    end
end

--
-- describe upvalues information
--
local function DescUpvalues(chunk, func)
    local n = func.sizeupvalues
    DescLine(chunk, "* upvalues:")
    FormatLine(chunk, GetLuaIntSize(), "sizeupvalues ("..n..")", func.pos_upvalues)
    for i = 1, n do
        local upvalue = func.upvalues[i]
        DescString(chunk, upvalue, func.posupvalues[i])
        DescLine(chunk, "upvalue ["..(i - 1).."]: "..EscapeString(upvalue))
        BriefLine(".upvalue"..GetOutputSep()..EscapeString(upvalue, 1)
                    ..GetOutputSep()..GetOutputComment()..(i - 1))
    end
end

--
-- describe constants information (data)
--
local function DescConstantKs(chunk, func)
    local n = func.sizek
    local pos = func.pos_ks
    DescLine(chunk, "* constants:")
    FormatLine(chunk, GetLuaIntSize(), "sizek ("..n..")", pos)
    for i = 1, n do
        local posk = func.posk[i]
        local CONST = "const ["..(i - 1).."]: "
        local CONSTB = GetOutputSep()..GetOutputComment()..(i - 1)
        local k = func.k[i]
        if type(k) == "number" then
            FormatLine(chunk,1, "const type "..GetTypeNumber(), posk)
            FormatLine(chunk, GetLuaNumberSize(), CONST.."("..k..")", posk + 1)
            BriefLine(".const"..GetOutputSep()..k..CONSTB)
        elseif type(k) == "boolean" then
            FormatLine(chunk,1, "const type "..GetTypeBoolean(), posk)
            FormatLine(chunk,1, CONST.."("..tostring(k)..")", posk + 1)
            BriefLine(".const"..GetOutputSep()..tostring(k)..CONSTB)
        elseif type(k) == "string" then
            FormatLine(chunk, 1, "const type "..GetTypeString(), posk)
            DescString(chunk, k, posk + 1)
            DescLine(chunk, CONST..EscapeString(k, 1))
            BriefLine(".const"..GetOutputSep()..EscapeString(k, 1)..CONSTB)
        elseif type(k) == "nil" then
            FormatLine(chunk, 1, "const type "..GetTypeNIL(), posk)
            DescLine(chunk, CONST.."nil")
            BriefLine(".const"..GetOutputSep().."nil"..CONSTB)
        end
    end--for
end

--
-- describe constants information (local functions)
--
local function DescConstantPs(chunk, func)
    local n = func.sizep
    DescLine(chunk,"* functions:")
    FormatLine(chunk, GetLuaIntSize(), "sizep ("..n..")", func.pos_ps)
    for i = 1, n do
        -- recursive call back on itself, next level
        DescFunction(chunk,func.p[i], i - 1, level + 1)
    end
end

--
-- describe function code
-- * inst decode subfunctions: DecodeInst() and DescribeInst()
--
local function DescCode(chunk, func)
    local size = func.sizecode
    local pos = func.pos_code
    DescLine(chunk,"* code:")
    FormatLine(chunk, GetLuaIntSize(), "sizecode ("..size..")", pos)
    pos = pos + GetLuaIntSize()
    func.inst = {}
    local ISIZE = WidthOf(size)
    for i = 1, size do
        func.inst[i] = {}
    end
    for i = 1, size do
        DecodeInst(func.code[i], func.inst[i])
        local inst = func.inst[i]
        -- compose instruction: opcode operands [; comments]
        local d = DescribeInst(inst, i, func)
        d = string.format("[%s] %s", ZeroPad(i, ISIZE), d)
        -- source code insertion
        SourceMerge(func, i)
        FormatLine(chunk, GetLuaInstructionSize(), d, pos)
        BriefLine(d)
        pos = pos + GetLuaInstructionSize()
    end
end

--
-- displays function information
-- * decoupled from LoadFunction due to 5.1 chunk rearrangement
--
function DescFunction(chunk, func, num, level)
    DescLine(chunk, "")
    BriefLine("")
    FormatLine(chunk, 0, "** function ["..num.."] definition (level "..level..")",
    func.pos_source)
    BriefLine("; function ["..num.."] definition (level "..level..")")
    DescLine(chunk, "** start of function **")

    -- source file name
    DescString(chunk, func.source, func.pos_source)
    if func.source == nil then
        DescLine(chunk, "source name: (none)")
    else
        DescLine(chunk, "source name: "..EscapeString(func.source))
    end

    -- optionally initialize source listing merging
    SourceInit(func.source)

    -- line where the function was defined
    local pos = func.pos_linedefined
    FormatLine(chunk, GetLuaIntSize(), "line defined ("..func.linedefined..")", pos)
    pos = pos + GetLuaIntSize()
    FormatLine(chunk, GetLuaIntSize(), "last line defined ("..func.lastlinedefined..")", pos)
    pos = pos + GetLuaIntSize()

    -- display byte counts
    FormatLine(chunk, 1, "nups ("..func.nups..")", pos)
    FormatLine(chunk, 1, "numparams ("..func.numparams..")", pos + 1)
    FormatLine(chunk, 1, "is_vararg ("..func.is_vararg..")", pos + 2)
    FormatLine(chunk, 1, "maxstacksize ("..func.maxstacksize..")", pos + 3)
    BriefLine(string.format("; %d upvalues, %d params, %d stacks",
    func.nups, func.numparams, func.maxstacksize))
    BriefLine(string.format(".function%s%d %d %d %d", GetOutputSep(),
    func.nups, func.numparams, func.is_vararg, func.maxstacksize))

    -- display parts of a chunk
    if ShouldIPrintParts() then
        DescLines(chunk,func)       -- brief displays 'declarations' first
        DescLocals(chunk, func)
        DescUpvalues(chunk, func)
        DescConstantKs(chunk, func)
        DescConstantPs(chunk, func)
        DescCode(chunk, func)
    else
        DescCode(chunk, func)        -- normal displays positional order
        DescConstantKs(chunk, func)
        DescConstantPs(chunk, func)
        DescLines(chunk,func)
        DescLocals(chunk, func)
        DescUpvalues(chunk, func)
    end

    -- show function statistics block
    DisplayStat("* func header   = "..func.stat.header.." bytes")
    DisplayStat("* lines size    = "..func.stat.lines.." bytes")
    DisplayStat("* locals size   = "..func.stat.locals.." bytes")
    DisplayStat("* upvalues size = "..func.stat.upvalues.." bytes")
    DisplayStat("* consts size   = "..func.stat.consts.." bytes")
    DisplayStat("* funcs size    = "..func.stat.funcs.." bytes")
    DisplayStat("* code size     = "..func.stat.code.." bytes")
    func.stat.total = func.stat.header + func.stat.lines +
    func.stat.locals + func.stat.upvalues +
    func.stat.consts + func.stat.funcs +
    func.stat.code
    DisplayStat(chunk, "* TOTAL size    = "..func.stat.total.." bytes")
    DescLine(chunk, "** end of function **\n")
    BriefLine("; end of function\n")
end

--
-- tests if a given number of bytes is available
--
local function IsChunkSizeOk(size, idx, total_size, errmsg)
    if idx + size - 1 > total_size then
        error(string.format("chunk too small for %s at offset %d", errmsg, idx - 1))
    end
end

--
-- loads a single byte and returns it as a number
--
local function LoadByte(chunk, previdx, func_movetonext)
    func_movetonext(1)
    return string.byte(chunk, previdx)
end

--
-- loads a block of endian-sensitive bytes
-- * rest of code assumes little-endian by default
--
local function LoadBlock(size, chunk, total_size, idx, func_movetonext)
    if not pcall(IsChunkSizeOk, size, idx, total_size, "LoadBlock") then return end
    if func_movetonext ~= nil then
        func_movetonext(size)
    end
    local b = string.sub(chunk, idx, idx + size - 1)
    if GetLuaEndianness() == 1 then
        return b
    else-- reverse bytes if big endian
        return string.reverse(b)
    end
end

--
-- loads an integer (signed)
--
local function LoadInt(chunk, total_size, idx, func_movetonext)
    local x = LoadBlock(GetLuaIntSize(), chunk, total_size, idx, func_movetonext)
    if not x then
        error("could not load integer")
    else
    local sum = 0
    for i = GetLuaIntSize(), 1, -1 do
        sum = sum * 256 + string.byte(x, i)
    end
    -- test for negative number
    if string.byte(x, GetLuaIntSize()) > 127 then
        sum = sum - math.ldexp(1, 8 * GetLuaIntSize())
    end
    -- from the looks of it, integers needed are positive
    if sum < 0 then error("bad integer") end
    return sum
    end
end

--
-- loads a size_t (assume unsigned)
--
local function LoadSize(chunk, total_size, idx, func_movetonext)
    local x = LoadBlock(GetLuaSizetSize(), chunk, total_size, idx, func_movetonext)
    if not x then
        print("total_size was ", total_size)
        error("could not load size_t at "..idx) --handled in LoadString()
        return
    else
        local sum = 0
        for i = GetLuaSizetSize(), 1, -1 do
            sum = sum * 256 + string.byte(x, i)
        end
        return sum
    end
end

--
-- loads a number (lua_Number type)
--
local function LoadNumber(chunk, total_size, idx, func_movetonext)
    local x = LoadBlock(GetLuaNumberSize(), chunk, total_size, idx, func_movetonext)
    if not x then
        error("could not load lua_Number")
    else
        local convert_func = convert_from[GetLuaNumberType()]
        if not convert_func then
            error("could not find conversion function for lua_Number")
        end
        return convert_func(x)
    end
end

--
-- load a string (size, data pairs)
--
local function LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
    local len = LoadSize(chunk, total_size, idx, func_movetonext)
    if not len then
        error("could not load String")
    else
        if len == 0 then        -- there is no error, return a nil
            return nil
        end
        IsChunkSizeOk(len, idx, total_size, "LoadString")
        -- note that ending NUL is removed
        local s = string.sub(chunk, idx, idx + len - 2)
        func_moveidx(len)
        print("Loading string at idx "..idx.. " of length "..len .. ">"..s.."<")
        return s
    end
end

--
-- Find size of string to be loaded (size, data pairs)
--
local function SizeLoadString(chunk, total_size, idx)
    local len = LoadSize(chunk, total_size, idx)
    if not len then
        error("could not load String")
    else
        if len == 0 then        -- there is no error, return a nil
            return 0
        end
        IsChunkSizeOk(len, idx, total_size, "LoadString")
        -- note that ending NUL is removed
        --local s = string.sub(chunk, idx, idx + len - 2)
        print("Size of String to Load at idx "..idx.. " of length "..len)
        --return s
        return len
    end
end
--
-- load line information
--
local function LoadLines(chunk, total_size, idx, previdx, func_movetonext, func)
    local size = LoadInt(chunk, total_size, idx, func_movetonext)
    func.pos_lineinfo = previdx
    print("VCVCVC Loading lines "..previdx..func.pos_lineinfo)
    func.lineinfo = {}
    func.sizelineinfo = size
    for i = 1, size do
        func.lineinfo[i] = LoadInt(chunk, total_size, idx, func_movetonext)
    end
end

--
-- load locals information
--
local function LoadLocals(chunk, total_size, idx, previdx, func_movetonext, func, func_moveidx)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    func.pos_locvars = previdx
    func.locvars = {}
    func.sizelocvars = n
    for i = 1, n do
        local locvar = {}
        locvar.varname = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
        locvar.pos_varname = previdx
        locvar.startpc = LoadInt(chunk, total_size, idx, func_movetonext)
        locvar.pos_startpc = previdx
        locvar.endpc = LoadInt(chunk, total_size, idx, func_movetonext)
        locvar.pos_endpc = previdx
        func.locvars[i] = locvar
    end
end

--
-- load upvalues information
--
local function LoadUpvalues(chunk, total_size, idx, previdx, func_movetonext, func, func_moveidx)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    if n ~= 0 and n~= func.nups then
        error(string.format("bad nupvalues: read %d, expected %d", n, func.nups))
        return
    end
    func.pos_upvalues = previdx
    func.upvalues = {}
    func.sizeupvalues = n
    func.posupvalues = {}
    for i = 1, n do
        func.upvalues[i] = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
        func.posupvalues[i] = previdx
        if not func.upvalues[i] then
            error("empty string at index "..(i - 1).."in upvalue table")
        end
    end
end

--
-- load function code
--
local function LoadCode(chunk, total_size, idx, previdx, func_movetonext, func)
    local size = LoadInt(chunk, total_size, idx, func_movetonext)
    print("Loading code of Size", size)
    func.pos_code = previdx
    func.code = {}
    func.sizecode = size
    for i = 1, size do
        func.code[i] = LoadBlock(GetLuaInstructionSize(), chunk, total_size, idx, func_movetonext)
    end
end

--
-- load constants information (data)
--
local function LoadConstantKs(chunk, total_size, idx, previdx, func_movetonext, func_moveidx, func)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    func.pos_ks = previdx
    func.k = {}
    func.sizek = n
    func.posk = {}
    pidx = idx
    ix = idx + GetLuaIntSize()
    print("Loading "..n.." constants")
    for i = 1, n do
        local t = LoadByte(chunk, ix, func_movetonext)
        pidx = pidx + 1
        ix = ix + 1
        func.posk[i] = pidx
        if t == GetTypeNumber() then
            print("Got Number")
            func.k[i] = LoadNumber(chunk, total_size, ix, func_movetonext)
        elseif t == GetTypeBoolean() then
            print("Got boolan")
            local b = LoadByte(chunk, ix, func_movetonext)
            if b == 0 then b = false else b = true end
            func.k[i] = b
        elseif t == GetTypeString() then
            print("Got string")
            func.k[i] = LoadString(chunk, total_size, ix, func_movetonext, func_moveidx)
            local strsize = SizeLoadString(chunk, total_size, ix)
            ix = ix + GetLuaSizetSize() + strsize
            pidx = pidx + GetLuaSizetSize() + strsize
        elseif t == GetTypeNIL() then
            print("NIL")
            func.k[i] = nil
        else
            error(i.." bad constant type "..t.." at "..previdx)
        end
    end--for
end

--
-- load constants information (local functions)
--
local function LoadConstantPs(chunk, total_size, idx, previdx, func_movetonext, func)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    func.pos_ps = previdx
    func.p = {}
    func.sizep = n
    for i = 1, n do
        -- recursive call back on itself, next level
        func.p[i] = LoadFunction(chunk, total_size, idx, previdx, func.source, i - 1, level + 1)
    end
end

--
-- this is recursively called to load the chunk or function body
--
function LoadFunction(chunk, total_size, ix, pix, funcname, num, level)
    local func = {}
    local idx  = ix
    local previdx = pix

    local function MoveToNextTok(size)
    previdx = idx
    idx = idx + size
    end

    local function MoveIdxLen(len)
    idx = idx + len
    end

    -------------------------------------------------------------
    -- body of LoadFunction() starts here
    -------------------------------------------------------------
    -- statistics handler
    local start = idx
    func.stat = {}
    local function SetStat(item)
      func.stat[item] = idx - start
      start = idx
    end
    -- source file name
    print("Loading string at "..idx)
    func.source = LoadString(chunk, total_size, idx, MoveToNextTok, MoveIdxLen)
    func.pos_source = previdx
    if func.source == "" and level == 1 then func.source = funcname end
    -- line where the function was defined
    print("Func source:" .. func.source)
    func.linedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Pos ".. func.linedefined)
    func.pos_linedefined = previdx
    func.lastlinedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Last line"..func.lastlinedefined)
    print "1"
    -------------------------------------------------------------
    -- some byte counts
    -------------------------------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    func.nups = LoadByte(chunk, idx, MoveToNextTok)
    func.numparams = LoadByte(chunk, idx, MoveToNextTok)
    func.is_vararg = LoadByte(chunk, idx, MoveToNextTok)
    func.maxstacksize = LoadByte(chunk, idx, MoveToNextTok)
    SetStat("header")
    print("Num params"..func.numparams)
    print("Max stack size"..func.maxstacksize)
    print "2"
    -------------------------------------------------------------
    -- these are lists, LoadConstantPs() may be recursive
    -------------------------------------------------------------
    -- load parts of a chunk (rearranged in 5.1)
    LoadCode(chunk, total_size, idx, previdx, MoveToNextTok, func)                 SetStat("code")
    print "2.4"
    LoadConstantKs(chunk, total_size, idx, previdx, MoveToNextTok, MoveIdxLen, func)                   SetStat("consts")
    print "2.8"
    LoadConstantPs(chunk, total_size, idx, previdx, MoveToNextTok,func)                     SetStat("funcs")
    print "3"
    LoadLines(chunk, total_size, idx, previdx, MoveToNextTok,func)                 SetStat("lines")
    LoadLocals(chunk, total_size, idx, previdx, MoveToNextTok, func, MoveIdxLen)   SetStat("locals")
    LoadUpvalues(chunk, total_size, idx, previdx, MoveToNextTok, func, MoveIdxLen) SetStat("upvalues")
    return func
    -- end of LoadFunction
end

function CheckSignature(size, idx, chunk)
    len = string.len(config.SIGNATURE)
    IsChunkSizeOk(len, idx, size, "header signature")
    if string.sub(chunk, 1, len) ~= config.SIGNATURE then
        error("header signature not found, this is not a Lua chunk")
    end
    return len
end

function CheckVersion(size, idx, chunk, func_movetonext)
    IsChunkSizeOk(1, idx, size, "version byte")
    ver = LoadByte(chunk, idx, func_movetonext)
    if ver ~= config.VERSION then
        --error(string.format("Dechunk cannot read version %02X chunks", ver))
        print(string.format("Dechunk cannot read version %02X chunks", ver))
    end
    return ver
end

function CheckFormat(size, idx, chunk, func_movetonext)
    IsChunkSizeOk(1, idx, size, "format byte")
    format = LoadByte(chunk, idx, func_movetonext)
    if format ~= config.FORMAT then
        error(string.format("Dechunk cannot read format %02X chunks", format))
    end
    return format
end

function CheckEndianness(size, idx, chunk, func_movetonext)
    IsChunkSizeOk(1, idx, size, "endianness byte")
    local endianness = LoadByte(chunk, idx, func_movetonext)
    if not config.AUTO_DETECT then
        if endianness ~= GetLuaEndianness() then
            error(string.format("unsupported endianness %s vs %s",
                  endianness, GetLuaEndianness()))
        end
    else
        SetLuaEndianness(endianness)
    end
    return endianness
end

function CheckSizes(size, idx, previdx, chunk, func_movetonext, mysize, sizename, typename)
    IsChunkSizeOk(4, idx, size, "size bytes")
    local byte = LoadByte(chunk, idx, func_movetonext)
    if not config.AUTO_DETECT then
        if byte ~= config[mysize] then
            error(string.format("mismatch in %s size (needs %d but read %d)",
                  sizename, config[mysize], byte))
        end
    else
        config[mysize] = byte
    end
end

function CheckIntegral(size, idx, chunk, func_movetonext)
    IsChunkSizeOk(1, idx, size, "integral byte")
    SetLuaIntegral(LoadByte(chunk, idx, func_movetonext))
end

function CheckLuaNumber()
    local num_id = GetLuaNumberSize() .. GetLuaIntegral()
    if not config.AUTO_DETECT then
        if GetLuaNumberType() ~= LUANUMBER_ID[num_id] then
            error("incorrect lua_Number format or bad test number")
        end
    else
        -- look for a number type match in our table
        SetLuaNumberType(nil)
        for i, v in pairs(LUANUMBER_ID) do
            if num_id == i then SetLuaNumberType(v) end
        end
        if not GetLuaNumberType() then
            error("unrecognized lua_Number type")
        end
    end
end

-- Lua 5.1 and 5.2 Header structures are identical
-- From lua source file lundump.c
function LuaChunkHeader(size, name, chunk, result, idx, previdx, stat, func_movetonext)
    local chunkdets = {}

    local function MoveToNextTok(size)
        previdx = idx
        idx = idx + size
    end

    local function MoveIdxLen(len)
        idx = idx + len
    end

    --
    -- initialize listing display
    --
    OutputHeader(size, name, chunk, idx)

    --
    -- test signature
    --
    len = CheckSignature(size, idx, chunk)
    FormatLine(chunk, len, "header signature: "..EscapeString(config.SIGNATURE, 1), idx)
    idx = idx + len

    --
    -- test version
    --
    result.version = CheckVersion(size, idx, chunk, MoveToNextTok)
    FormatLine(chunk, 1, "version (major:minor hex digits)", previdx)
    chunkdets.version  = result.version

    --
    -- test format (5.1)
    -- * Dechunk does not accept anything other than 0. For custom
    -- * binary chunks, modify Dechunk to read it properly.
    --
    result.format = CheckFormat(size, idx, chunk, MoveToNextTok)
    FormatLine(chunk, 1, "format (0=official)", previdx)

    --
    -- test endianness
    --
    endianness = CheckEndianness(size, idx, chunk, MoveToNextTok)
    FormatLine(chunk, 1, "endianness (1=little endian)", previdx)
    chunkdets.endianness = endianness

    --
    -- test sizes
    --
    -- byte sizes
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok, "size_int", "int", "bytes")
    FormatLine(chunk, 1, string.format("size of %s (%s)", "int", "bytes"),
               previdx)
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok, "size_size_t", "size_t", "bytes")
    FormatLine(chunk, 1, string.format("size of %s (%s)", "size_t", "bytes"),
               previdx)
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok, "size_Instruction", "Instruction", "bytes")
    FormatLine(chunk, 1, string.format("size of %s (%s)", "Instruction", "bytes"),
               previdx)
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok, "size_lua_Number", "number", "bytes")
    FormatLine(chunk, 1, string.format("size of %s (%s)", "number", "bytes"),
               previdx)
    -- initialize decoder (see the 5.0.2 script if you want to customize
    -- bit field sizes; Lua 5.1 has fixed instruction bit field sizes)
    DecodeInit()

    --
    -- test integral flag (5.1)
    --
    CheckIntegral(size, idx, chunk, MoveToNextTok)
    FormatLine(chunk, 1, "integral (1=integral)", previdx)

    --
    -- verify or determine lua_Number type
    --
    CheckLuaNumber()
    DescLine("* number type: "..GetLuaNumberType())

    init_scope_config_description()
    DescLine("* "..GetLuaDescription())
    if ShouldIPrintBrief() then WriteLine(GetOutputComment()..GetLuaDescription()) end
    -- end of global header
    stat.header = idx - 1
    DisplayStat("* global header = "..stat.header.." bytes")
    DescLine("** global header end **")

    return idx, previdx, chunkdets
end

--[[
-- Dechunk main processing function
-- * in order to maintain correct positional order, the listing will
--   show functions as nested; a level number is kept to help the
--   user trace the extent of functions in the listing
--]]

function Dechunk(chunk_name, chunk)
    ---------------------------------------------------------------
    -- variables
    ---------------------------------------------------------------
    local idx = 1
    local previdx, len
    local result = {}     -- table with all parsed data
    local stat = {}
    result.chunk_name = chunk_name or ""
    result.chunk_size = string.len(chunk)

    --[[
    -- Display support functions
    -- * considerable work is done to maintain nice alignments
    -- * some widths are initialized at chunk start
    -- * this is meant to make output customization easy
    --]]

    idx, previdx, dets = LuaChunkHeader(result.chunk_size, result.chunk_name, chunk, result, idx, previdx, stat, MoveToNextTok)

    -- Temporary check for version 5.1
    if dets.version ~= 81 then return nil end

    --
    -- actual call to start the function loading process
    --
    result.func = LoadFunction(chunk, result.chunk_size, idx, previdx, "(chunk)", 0, 1)
    DescFunction(chunk, result.func, 0, 1)
    stat.total = idx - 1
    DisplayStat(chunk, "* TOTAL size = "..stat.total.." bytes")
    result.stat = stat
    FormatLine(chunk, 0, "** end of chunk **", idx)
    return result
    -- end of Dechunk
end
