#!/usr/bin/lua

--[[
    Decode Chunks for Lua Scope
    A Lua 5.1/5.2/5.3 binary chunk disassembler
    LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]

package.path = package.path .. ";./?.lua;/usr/src/?.lua"

require("scope_config")

-- XXX is a hack, only temporary, hopefully.
config = get_config()

srcinfo = {}

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

--[[
-- Source listing merging
-- * for convenience, file name matching is first via case-sensitive
--   comparison, then case-insensitive comparison, and the first
--   match found using either method is the one that is used
--]]

-----------------------------------------------------------------------
-- initialize source list for merging
-- * this will normally be called by the main chunk function
-- * the source listing is read only once, upon initialization
-----------------------------------------------------------------------
function SourceInit(source)
    if srcinfo.source then srcinfo.srcprev = 0; return end
    if not  source or
            source == "" or
            string.sub(source, 1, 1) ~= "@" then
        return
    end
    source = string.sub(source, 2)                -- chomp leading @
    for _, fname in ipairs(other_files) do        -- find a match
        if not srcinfo.source then
            if fname == source or
               string.lower(fname) == string.lower(source) then
                srcinfo.source = fname
            end
        end
    end
    if not srcinfo.source then return end          -- no source file
    local INF = io.open(srcinfo.source, "rb")      -- read in source file
    if not INF then
        error("cannot read file \""..filename.."\"")
    end
    srcinfo.srcline = {}; srcinfo.srcmark = {}
    local n, line = 1
    repeat
        line = INF:read("*l")
        if line then
            srcinfo.srcline[n], srcinfo.srcmark[n] = line, false
            n = n + 1
        end
    until not line
    io.close(INF)
    srcinfo.srcsize = n - 1
    srcinfo.DISPLAY_SRC_WIDTH = WidthOf(srcinfo.srcsize)
    srcinfo.srcprev = 0
end

-----------------------------------------------------------------------
-- mark source lines
-- * marks source lines as a function is read to delineate stuff
-----------------------------------------------------------------------
function SourceMark(func)
    if not srcinfo.source then return end
    if func.sizelineinfo == 0 then return end
    for i = 1, func.sizelineinfo do
        if i <= srcinfo.srcsize then
            srcinfo.srcmark[func.lineinfo[i]] = true
        end
    end
end

-----------------------------------------------------------------------
-- generate source lines
-- * peek at lines above and print them if they have not been printed
-- * mark all printed lines so all non-code lines are printed once only
-----------------------------------------------------------------------
function SourceMerge(func, pc)
    if not srcinfo.source or not srcinfo.DISPLAY_FLAG then return end
    local lnum = func.lineinfo[pc]
    -- don't print anything new if instruction is on the same line
    if srcinfo.srcprev == lnum then return end
    srcinfo.srcprev = lnum
    if srcinfo.srcsize < lnum then return end      -- something fishy
    local lfrom = lnum
    srcinfo.srcmark[lnum] = true
    while lfrom > 1 and srcinfo.srcmark[lfrom - 1] == false do
        lfrom = lfrom - 1
        srcinfo.srcmark[lfrom] = true
    end
    for i = lfrom, lnum do
        WriteLine(GetOutputComment()
          .."("..ZeroPad(i, srcinfo.DISPLAY_SRC_WIDTH)..")"
          ..srcinfo.DISPLAY_SEP..srcinfo.srcline[i])
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
local function DescLines(chunk, desc)
    local size = desc.sizelineinfo
    local pos = desc.pos_lineinfo
    DescLine("* lines:")
    FormatLine(chunk, GetLuaIntSize(), "sizelineinfo ("..size..")", pos)
    pos = pos + GetLuaIntSize()
    local WIDTH = WidthOf(size)
    DescLine("[pc] (line)")
    for i = 1, size do
        local s = string.format("[%s] (%s)", ZeroPad(i, WIDTH), desc.lineinfo[i])
        FormatLine(chunk, GetLuaIntSize(), s, pos)
        pos = pos + GetLuaIntSize()
    end
    -- mark significant lines in source listing
    SourceMark(desc)
end

--
-- describe locals information
--
local function DescLocals(chunk, desc)
    local n = desc.sizelocvars
    DescLine(chunk, "* locals:")
    FormatLine(chunk, GetLuaIntSize(), "sizelocvars ("..n..")", desc.pos_locvars)
    for i = 1, n do
        local locvar = desc.locvars[i]
        if locvar.pos_varname ~= 0 then -- FIXME hack for 5.3
            DescString(chunk, locvar.varname, locvar.pos_varname)
            DescLine(chunk, "local ["..(i - 1).."]: "..EscapeString(locvar.varname))
            BriefLine(".local"..GetOutputSep()..EscapeString(locvar.varname, 1)
                        ..GetOutputSep()..GetOutputComment()..(i - 1))
            FormatLine(chunk, GetLuaIntSize(), "  startpc ("..locvar.startpc..")", locvar.pos_startpc)
            FormatLine(chunk, GetLuaIntSize(), "  endpc   ("..locvar.endpc..")",locvar.pos_endpc)
        end
    end
end

--
-- describe upvalues information
--
local function DescUpvalues(chunk, desc)
    local n = desc.sizeupvalues
    DescLine(chunk, "* upvalues:") 
    if n == nil then return end
    if n == 1 then return end -- XX HACK by Vijo for lua 5.2
    FormatLine(chunk, GetLuaIntSize(), "sizeupvalues ("..n..")", desc.pos_upvalues)
    for i = 1, n do
        local upvalue = desc.upvalues[i]
        DescString(chunk, upvalue, desc.posupvalues[i])
        DescLine(chunk, "upvalue ["..(i - 1).."]: "..EscapeString(upvalue))
        BriefLine(".upvalue"..GetOutputSep()..EscapeString(upvalue, 1)
                    ..GetOutputSep()..GetOutputComment()..(i - 1))
    end
end

--
-- describe constants information (data)
--
local function DescConstantKs(chunk, desc)
    local n = desc.sizek
    local pos = desc.pos_ks
    DescLine(chunk, "* constants:")
    FormatLine(chunk, GetLuaIntSize(), "sizek ("..n..")", pos)
    for i = 1, n do
        local posk = desc.posk[i]
        local CONST = "const ["..(i - 1).."]: "
        local CONSTB = GetOutputSep()..GetOutputComment()..(i - 1)
        local k = desc.k[i]
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
local function DescConstantPs(chunk, desc)
    local n = desc.sizep
    if n == nil then return end
    DescLine(chunk,"* functions:")
    FormatLine(chunk, GetLuaIntSize(), "sizep ("..n..")", desc.pos_ps)
    for i = 1, n do
        -- recursive call back on itself, next level
        DescFunction(chunk,desc.p[i], i - 1, level + 1)
    end
end

--
-- describe function code
-- * inst decode subfunctions: DecodeInst() and DescribeInst()
--
local function DescCode(chunk, desc, oconfig)
    local size = desc.sizecode
    local pos = desc.pos_code
    DescLine(chunk,"* code:")
    FormatLine(chunk, oconfig:GetLuaIntSize(), "sizecode ("..size..")", pos)
    pos = pos + oconfig:GetLuaIntSize()
    desc.inst = {}
    local ISIZE = WidthOf(size)
    for i = 1, size do
        desc.inst[i] = {}
    end
    for i = 1, size do
        DecodeInst(desc.code[i], desc.inst[i])
        local inst = desc.inst[i]
        -- compose instruction: opcode operands [; comments]
        local d = DescribeInst(inst, i, desc, oconfig)
        d = string.format("[%s] %s", ZeroPad(i, ISIZE), d)
        -- source code insertion
        SourceMerge(desc, i)
        FormatLine(chunk, oconfig:GetLuaInstructionSize(), d, pos)
        BriefLine(d)
        pos = pos + oconfig:GetLuaInstructionSize()
    end
end

--
-- displays function information
--
function DescFunction(chunk, desc, num, level, oconfig)
    DescLine(chunk, "")
    BriefLine("")
    FormatLine(chunk, 0, "** function ["..num.."] definition (level "..level..")", desc.pos_source)
    BriefLine("; function ["..num.."] definition (level "..level..")")
    DescLine(chunk, "** start of function **")

    -- source file name
    DescString(chunk, desc.source, desc.pos_source)
    if desc.source == nil then
        DescLine(chunk, "source name: (none)")
    else
        DescLine(chunk, "source name: "..EscapeString(desc.source))
    end

    -- optionally initialize source listing merging
    SourceInit(desc.source)

    -- line where the function was defined
    local pos = desc.pos_linedefined
    FormatLine(chunk, oconfig:GetLuaIntSize(), "line defined ("..desc.linedefined..")", pos)
    pos = pos + oconfig:GetLuaIntSize()
    FormatLine(chunk, oconfig:GetLuaIntSize(), "last line defined ("..desc.lastlinedefined..")", pos)
    pos = pos + oconfig:GetLuaIntSize()

    -- display byte counts
    FormatLine(chunk, 1, "nups ("..desc.nups..")", pos)
    FormatLine(chunk, 1, "numparams ("..desc.numparams..")", pos + 1)
    FormatLine(chunk, 1, "is_vararg ("..desc.is_vararg..")", pos + 2)
    FormatLine(chunk, 1, "maxstacksize ("..desc.maxstacksize..")", pos + 3)
    BriefLine(string.format("; %d upvalues, %d params, %d stacks",
    desc.nups, desc.numparams, desc.maxstacksize))
    BriefLine(string.format(".function%s%d %d %d %d", GetOutputSep(),
    desc.nups, desc.numparams, desc.is_vararg, desc.maxstacksize))

    -- display parts of a chunk
    if ShouldIPrintParts() then
        DescLines(chunk,desc)       -- brief displays 'declarations' first
        DescLocals(chunk, desc)
        DescUpvalues(chunk, desc)
        DescConstantKs(chunk, desc)
        DescConstantPs(chunk, desc)
        DescCode(chunk, desc, oconfig)
    else
        --DescCode(chunk, desc, oconfig)        -- normal displays positional order
        DescConstantKs(chunk, desc)
        DescConstantPs(chunk, desc)
        DescLines(chunk,desc)
        DescLocals(chunk, desc)
        DescUpvalues(chunk, desc)
    end

    -- show function statistics block
    DisplayStat("* func header   = "..desc.stat.header.." bytes", oconfig)
    DisplayStat("* lines size    = "..desc.stat.lines.." bytes", oconfig)
    DisplayStat("* locals size   = "..desc.stat.locals.." bytes", oconfig)
    DisplayStat("* upvalues size = "..desc.stat.upvalues.." bytes", oconfig)
    DisplayStat("* consts size   = "..desc.stat.consts.." bytes", oconfig)
    DisplayStat("* funcs size    = "..desc.stat.funcs.." bytes", oconfig)
    DisplayStat("* code size     = "..desc.stat.code.." bytes", oconfig)
    desc.stat.total = desc.stat.header + desc.stat.lines +
                      desc.stat.locals + desc.stat.upvalues +
                      desc.stat.consts + desc.stat.funcs +
                      desc.stat.code
    DisplayStat("* TOTAL size    = "..desc.stat.total.." bytes", oconfig)
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
local function LoadByte(chunk, chunkinfo)
    chunkinfo.previdx = chunkinfo.idx
    chunkinfo.idx     =  chunkinfo.idx + 1
    return string.byte(chunk, chunkinfo.previdx)
end

local function LoadByte53(chunk, chunkinfo)
    return string.byte(chunk, chunkinfo.idx)
end

--
-- loads a block of endian-sensitive bytes
-- * rest of code assumes little-endian by default
--
local function LoadBlock(size, chunk, chunkinfo)
    local total_size = chunkinfo.chunk_size
    local idx        = chunkinfo.idx
    local previdx    = chunkinfo.previdx

    print("LoadBlock Checking for size "..size.."  size "..total_size.." Idx starts at "..string.format("%x", idx))
    if not pcall(IsChunkSizeOk, size, idx, total_size, "LoadBlock") then return end
    chunkinfo.previdx = chunkinfo.idx
    chunkinfo.idx     = chunkinfo.idx + size
    local b = string.sub(chunk, idx, idx + size - 1)
    if GetLuaEndianness() == 1 then
        return b
    else-- reverse bytes if big endian
        return string.reverse(b)
    end
end

--
-- loads a number (can be zero) - loadInt can't load zero - used by 5.2
--
local function LoadNo(chunk, chunkinfo)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local x       = LoadBlock(GetLuaIntSize(), chunk, chunkinfo)

    if x == nil then return 0 end
    local sum = 0
    for i = GetLuaIntSize(), 1, -1 do
        sum = sum * 256 + string.byte(x, i)
    end
    return sum
end

--
-- loads an integer (signed)
--
local function LoadInt(chunk, chunkinfo)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx

    local x = LoadBlock(GetLuaIntSize(), chunk, chunkinfo)
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
local function LoadSize(chunk, chunkinfo)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local x       = LoadBlock(GetLuaSizetSize(), chunk, chunkinfo)

    if not x then
        print("total_size was ", total_size)
        error("could not load size_t at "..string.format("%x", idx)) --handled in LoadString()
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
local function LoadNumber(chunk, chunkinfo)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx

    local x = LoadBlock(GetLuaNumberSize(), chunk, chunkinfo)
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
local function LoadString(chunk, chunkinfo)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx

    print("Trying to load string at idx "..string.format("%x", idx).." from total size "..size)
    local len = LoadSize(chunk, chunkinfo)
    if not len then
        error("could not load String")
    else
        if len == 0 then        -- there is no error, return a nil
            print("0-sized string at location "..string.format("%x", idx) )
            return nil
        end
        print("Size in string: "..len.." "..string.format("%x", len))
        idx = idx + GetLuaSizetSize() -- idx was incremented in our caller
        IsChunkSizeOk(len, idx, size, "LoadString")
        -- note that ending NUL is removed
        local s = string.sub(chunk, idx, idx + len )
        chunkinfo.idx = chunkinfo.idx + len
        print("Loading string at idx "..string.format("%x", idx).. " of length "..len .. ">"..s.."<")
        Hexdump(s)
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
        idx = idx + GetLuaSizetSize() -- idx was incremented in our caller
        IsChunkSizeOk(len, idx, total_size, "LoadString")
        -- note that ending NUL is removed
        local s = string.sub(chunk, idx, idx + len)
        print("Size of String to Load at idx "..string.format("%x", idx).. " of length "..len..s)
        Hexdump(s)
        --return s
        return len
    end
end

local function LoadLua53String(chunk, chunkinfo)
    local size = chunkinfo.chunk_size
    local idx  = chunkinfo.idx

    print("idx: "..string.format("%x", idx))
    local len = LoadByte53(chunk, chunkinfo)
    local islngstr = nil
    if not len then
        error("could not load String")
        return
    end
    chunkinfo.idx =  chunkinfo.idx + 1
    print("Lua53string of len "..len.." at idx "..string.format("%x", idx)) 
    if len == 255 then
        len = LoadSize(chunk, size, idx, {})
        islngstr = true
    end

    if len == 0 then        -- there is no error, return a nil
        return nil, len, islngstr
    end
    if len == 1 then
        return "", len, islngstr
    end
    --TestChunk(len - 1, idx, "LoadString")
    IsChunkSizeOk(len, idx+1, size, "LoadString")
    local s = string.sub(chunk, idx+1, idx + len)
    --idx = idx + len - 1
    --func_moveidx(len)
    chunkinfo.idx = chunkinfo.idx + len
    print("Loaded string at idx "..string.format("%x", chunkinfo.idx).. " of length "..len .. ">"..s.."<")
    return s, len, islngstr
end

--
-- load line information
--
local function LoadLines(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local size    = LoadInt(chunk, chunkinfo)

    desc.pos_lineinfo = previdx
    print("VCVCVC Loading lines "..previdx..desc.pos_lineinfo)
    desc.lineinfo = {}
    desc.sizelineinfo = size
    for i = 1, size do
        desc.lineinfo[i] = LoadInt(chunk, chunkinfo)
    end
end

--
-- load locals information
--
local function LoadLocals(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    desc.pos_locvars = previdx
    desc.locvars = {}
    desc.sizelocvars = n
    for i = 1, n do
        local locvar = {}
        locvar.varname = LoadString(chunk, chunkinfo)
        locvar.pos_varname = previdx
        locvar.startpc = LoadInt(chunk, chunkinfo)
        locvar.pos_startpc = previdx
        locvar.endpc = LoadInt(chunk, chunkinfo)
        locvar.pos_endpc = previdx
        desc.locvars[i] = locvar
    end
end

--
-- load function prototypes information (Used in 5.2)
--
local function LoadFuncProto(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadNo(chunk, chunkinfo)
    --if n > 1 then
        --error(string.format("bad Function prototypes: read %d, expected %d", n, func.nups))
        --return
    --end
    print("No of Function prototypes:", n)
    --func.pos_upvalues = previdx
    --func.upvalues = {}
    --func.sizeupvalues = n
    --func.posupvalues = {}
    --for i = 1, n do
    --    func.upvalues[i] = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
    --    func.posupvalues[i] = previdx
    --    if not func.upvalues[i] then
    --        error("empty string at index "..(i - 1).."in upvalue table")
    --    end
    --end
end

--
-- load upvalues information
--
local function Load52Upvalues(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    print("No of Upvalues", n)
    desc.pos_upvalues = previdx
    desc.upvalues = {}
    desc.sizeupvalues = n
    desc.posupvalues = {}
    local x = LoadBlock(2, chunk, chunkinfo)
    local y = 0
    for i = 2, 1, -1 do
        y = y * 256 + string.byte(x, i)
    end
    print("Read 2 bytes for upvalue", y)
end

--
-- load upvalues information
--
local function Load53Upvalues(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    print("No of Upvalues", n)
    desc.pos_upvalues = chunkinfo.previdx
    desc.upvalues     = {}
    desc.sizeupvalues = n
    desc.posupvalues  = {}
    for i = 1, n do
        local upvalue = {}
        upvalue.instack = LoadByte(chunk, chunkinfo)
        upvalue.pos_instack = chunkinfo.previdx
        upvalue.idx = LoadByte(chunk, chunkinfo)
        upvalue.pos_idx = chunkinfo.previdx
        desc.upvalues[i] = upvalue
    end
    print("Read n bytes for upvalue", y)
end

--
-- load upvalues information
--
local function LoadUpvalues(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    if n ~= 0 and n~= desc.nups then
        error(string.format("bad nupvalues: read %d, expected %d", n, desc.nups))
        return
    end
    desc.pos_upvalues = previdx
    desc.upvalues = {}
    desc.sizeupvalues = n
    desc.posdescupvalues = {}
    for i = 1, n do
        desc.upvalues[i] = LoadString(chunk, chunkinfo)
        desc.posupvalues[i] = previdx
        if not desc.upvalues[i] then
            error("empty string at index "..(i - 1).."in upvalue table")
        end
    end
end

--
-- load function code
--
local function LoadCode(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local size    = LoadInt(chunk, chunkinfo)

    print("Loading instructions of Size "..size.." hex:" ..string.format("%x", size).." at idx "..string.format("%x", idx))
    desc.pos_code = previdx
    desc.code = {}
    desc.sizecode = size
    for i = 1, size do
        desc.code[i] = LoadBlock(GetLuaInstructionSize(), chunk, chunkinfo)
    end
end

--
-- load constants information (data)
--
local function LoadConstantKs(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    desc.pos_ks   = previdx
    desc.k        = {}
    desc.sizek    = n
    desc.posk     = {}
    pidx          = idx
    ix            = idx + GetLuaIntSize()  + 0
    print("Loading "..n.." constants")
    for i = 1, n do
        local t = LoadByte(chunk, chunkinfo)
        desc.posk[i] = chunkinfo.previdx
        if t == GetTypeNumber() then
            print("Got Number")
            desc.k[i] = LoadNumber(chunk, total_size, ix, func_movetonext)
        elseif t == GetTypeBoolean() then
            print("Got boolean")
            local b = LoadByte(chunk, chunkinfo)
            if b == 0 then b = false else b = true end
            desc.k[i] = b
        elseif t == GetTypeString() then
            print("Got string")
            desc.k[i] = LoadString(chunk, chunkinfo)
            --local strsize = SizeLoadString(chunk, total_size, ix)
            --ix = ix + GetLuaSizetSize() + strsize
            --pidx = pidx + GetLuaSizetSize() + strsize
        elseif t == GetTypeNIL() then
            print("NIL")
            desc.k[i] = nil
        else
            error(i.." bad constant type "..t.." at "..chunkinfo.previdx)
        end
    end--for
end

--
-- load constants information (data)
--
local function LoadConstantsLua53(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    desc.pos_ks   = previdx
    desc.k        = {}
    desc.sizek    = n
    desc.posk     = {}
    pidx          = idx
    ix            = idx + GetLuaIntSize()  + 0
    chunkinfo.idx = ix
    print("Loading "..n.." constants")
    for i = 1, n do
        print("reading byte at "..string.format("%x", chunkinfo.idx))
        local t = LoadByte(chunk, chunkinfo)
        pidx    = pidx + 1
        ix      = ix + 1
        desc.posk[i] = pidx
        if t == GetTypeNumber() then
            print("Got Number")
            desc.k[i] = LoadNumber(chunk, size, ix, func_movetonext)
        elseif t == GetTypeBoolean() then
            print("Got boolean at idx ".. (string.format("%x", idx)).."  c.i : "..string.format("%x", chunkinfo.idx))
            local b = LoadByte(chunk, chunkinfo)
            if b == 0 then b = false else b = true end
            desc.k[i] = b
        elseif t == GetTypeString() then
            print("Got string at "..string.format("%x", idx))
            desc.k[i], strsize = LoadLua53String(chunk, chunkinfo)
            chunkinfo.idx = chunkinfo.idx -1 
            chunkinfo.previdx = chunkinfo.previdx -1
        elseif t == GetTypeNIL() then
            print("NIL")
            desc.k[i] = nil
        else
            error(i.." bad constant type "..t.." at "..previdx)
        end
    end--for

    return n
end

--
-- load constants information (local functions)
--
local function LoadConstantPs(chunk, chunkinfo, desc)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx
    local n       = LoadInt(chunk, chunkinfo)

    desc.pos_ps = previdx
    desc.p = {}
    desc.sizep = n
    for i = 1, n do
        -- recursive call back on itself, next leveldescdesc
        desc.p[i] = LoadFunction(chunk, total_size, idx, previdx, desc.source, i - 1, level + 1)
    end
end

--
-- load debug information (used in Lua 5.2)
-- TODO: DOESN'T WORK
--
local function LoadDebug(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx, chunkinfo)
    desc.source = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
    print("Source code: ", desc.source)
    --print("Source code length:", g)
    --local h = LoadNo(chunk, total_size, idx, MoveToNextTok)
    --print("Next 4 bytes:", h)
    --LoadLocals(chunk, total_size, idx, previdx, MoveToNextTok, func, MoveIdxLen)     SetStat("locals")

    local i = LoadInt(chunk, chunkinfo)
    print("Next 4 bytes:", i)
    local j = LoadNo(chunk, total_size, idx, func_movetonext)
    print("Next 4 bytes:", j)
    local k = LoadNo(chunk, total_size, idx, func_movetonext)
    print("Next 4 bytes:", k)
end

function CheckSignature(chunk, chunkinfo, oconfig)
    local size = chunkinfo.chunk_size
    local idx  = chunkinfo.idx
    local len  = string.len(oconfig:GetSign())

    IsChunkSizeOk(len, idx, size, "header signature")

    if string.sub(chunk, 1, len) ~= oconfig:GetSign() then
        error("header signature not found, this is not a Lua chunk")
    end

    chunkinfo.idx = chunkinfo.idx + len

    return len
end

function Check52Signature(size, idx, chunk)
    local lua52signature = "\x19\x93\x0d\x0a\x1a\x0a"

    len = string.len(lua52signature)
    IsChunkSizeOk(len, idx, size, "lua52 signature")

    if string.sub(chunk, idx, len) ~= lua52signature then
        print("Lua 5.2 signature not found, this is not a Lua5.2 chunk")
    end

    return idx+len
end

function CheckVersion(chunk, chunkinfo, oconfig)
    local size = chunkinfo.chunk_size
    local idx  = chunkinfo.idx

    IsChunkSizeOk(1, idx, size, "version byte")
    ver = LoadByte(chunk, chunkinfo)

    if oconfig:IsVersionOK(ver) == false then
        error(string.format("Dechunk(%s) cannot read version %02X chunks", oconfig:GetVersion(), ver))
        --print(string.format("Dechunk cannot read version %02X chunks", ver))
    end

    return ver
end

function CheckFormat(chunk, chunkinfo, oconfig)
    local size = chunkinfo.chunk_size
    local idx  = chunkinfo.idx

    IsChunkSizeOk(1, idx, size, "format byte")
    format = LoadByte(chunk, chunkinfo)
    if format ~= oconfig:GetFormat() then
        error(string.format("Dechunk cannot read format %02X chunks", format))
    end

    return format
end

function CheckEndianness(chunk, chunkinfo, oconfig)
    local size = chunkinfo.chunk_size
    local idx  = chunkinfo.idx

    IsChunkSizeOk(1, idx, size, "endianness byte")
    local endianness = LoadByte(chunk, chunkinfo)
    if not oconfig:GetConfigDetect() then
        if endianness ~= oconfig:GetLuaEndianness() then
            error(string.format("unsupported endianness %s vs %s",
                  endianness, oconfig:GetLuaEndianness()))
        end
    else
        SetLuaEndianness(endianness)
    end
    return endianness
end

function CheckSizes(chunk, chunkinfo, sizename, oconfig)
    local size    = chunkinfo.chunk_size
    local idx     = chunkinfo.idx
    local previdx = chunkinfo.previdx

    IsChunkSizeOk(4, idx, size, "size bytes")
    local byte = LoadByte(chunk, chunkinfo)
    lt = oconfig:GetLuavmSizeTbl(sizename)["get"]
    if not oconfig:GetConfigDetect() then
        if byte ~= lt() then
            error(string.format("mismatch in %s size (needs %d but read %d)",
                  sizename, lt(), byte))
        end
    else
        lt.set(byte)
    end
end

function CheckIntegral(chunk, chunkinfo)
    local size = chunkinfo.chunk_size
    local idx  = chunkinfo.idx

    IsChunkSizeOk(1, idx, size, "integral byte")
    SetLuaIntegral(LoadByte(chunk, chunkinfo))
end

function CheckLuaNumber(oconfig)
    local num_id = oconfig:GetLuaNumberSize() .. oconfig:GetLuaIntegral()
    if not oconfig:GetConfigDetect() then
        if oconfig:GetLuaNumberType() ~= LUANUMBER_ID[num_id] then
            error("incorrect lua_Number format or bad test number")
        end
    else
        -- look for a number type match in our table
        SetLuaNumberType(nil)
        for i, v in pairs(LUANUMBER_ID) do
            if num_id == i then SetLuaNumberType(v) end
        end
        if not oconfig:GetLuaNumberType() then
            error("unrecognized lua_Number type")
        end
    end
end

--
-- this is recursively called to load the chunk or function body
--
function Load51Function(dechunker, chunk, chunkinfo, funcname, num, level)
    local desc       = {}
    local idx        = chunkinfo.idx
    local previdx    = chunkinfo.previdx
    local total_size = chunkinfo.chunk_size

    -------------------------------------------------------------
    -- body of LoadFunction() starts here
    -------------------------------------------------------------
    -- statistics handler
    local start = idx
    desc.stat = {}
    local function SetStat(item)
        desc.stat[item] = idx - start
        start = idx
    end

    -- source file name
    print("Loading string at "..string.format("%x", idx))
    desc.source = LoadString(chunk, chunkinfo)
    desc.pos_source = previdx
    if desc.source == "" and level == 1 then desc.source = funcname end

    -- line where the function was defined
    print("Func source:" .. desc.source)
    desc.linedefined = LoadInt(chunk, chunkinfo)
    print("Pos ".. desc.linedefined)
    desc.pos_linedefined = previdx
    desc.lastlinedefined = LoadInt(chunk, chunkinfo)
    print("Last line"..desc.lastlinedefined)
    print "1"

    -------------------------------------------------------------
    -- some byte counts
    -------------------------------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    desc.nups         = LoadByte(chunk, chunkinfo)
    desc.numparams    = LoadByte(chunk, chunkinfo)
    desc.is_vararg    = LoadByte(chunk, chunkinfo)
    desc.maxstacksize = LoadByte(chunk, chunkinfo)
    SetStat("header")
    print("Num params"..desc.numparams)
    print("Max stack size"..desc.maxstacksize)
    print "2"

    -------------------------------------------------------------
    -- these are lists, LoadConstantPs() may be recursive
    -------------------------------------------------------------
    -- load parts of a chunk (rearranged in 5.1)
    LoadCode(chunk, chunkinfo, desc)       SetStat("code")
    print "2.4"
    LoadConstantKs(chunk, chunkinfo, desc) SetStat("consts")
    print "2.8"
    LoadConstantPs(chunk, chunkinfo, desc) SetStat("funcs")
    print "3"
    LoadLines(chunk, chunkinfo, desc)      SetStat("lines")
    LoadLocals(chunk, chunkinfo, desc)     SetStat("locals")
    LoadUpvalues(chunk, chunkinfo, desc)   SetStat("upvalues")

    -- XXX this should get redundant once chunkinfo is propogated everywhere
    chunkinfo.idx = idx
    chunkinfo.previdx = previdx

    return desc
    -- end of Load51Function
end

-- References : lundump.[ch], http://files.catwell.info/misc/mirror/lua-5.2-bytecode-vm-dirk-laurie/lua52vm.html
function Load52Function(dechunker, chunk, chunkinfo, funcname, num, level)
    local desc       = {}
    local idx        = chunkinfo.idx
    local previdx    = chunkinfo.previdx
    local total_size = chunkinfo.chunk_size

    -------------------------------------------------------------
    -- body of LoadFunction() starts here
    -------------------------------------------------------------
    -- statistics handler
    local start = idx
    desc.stat = {}
    local function SetStat(item)
        desc.stat[item] = idx - start
        start = idx
    end
    print("Loading string at "..string.format("%x", idx))
    Hexdump(chunk)
    previdx = idx
    chunkinfo.idx = dechunker.Func_CheckSignature(total_size, idx, chunk)

    -- line where the function was defined
    desc.linedefined = LoadInt(chunk, chunkinfo)
    print("Pos :".. desc.linedefined)
    desc.pos_linedefined = chunkinfo.previdx
    desc.lastlinedefined = LoadInt(chunk, chunkinfo)
    print("Last line :"..desc.lastlinedefined)
    print "1"

    -------------------------------------------------------------
    -- some byte counts
    --------------------desc-----------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    desc.numparams    = LoadByte(chunk, chunkinfo)
    desc.is_vararg    = LoadByte(chunk, chunkinfo)
    desc.maxstacksize = LoadByte(chunk, chunkinfo)
    SetStat("header")
    print("Num params :"..desc.numparams)
    print("Max stack size :"..desc.maxstacksize)
    print "2"

    -- load parts of a chunk
    LoadCode(chunk, chunkinfo, desc)                   SetStat("code")
    print "2.4"
    LoadConstantKs(chunk, chunkinfo, desc) SetStat("consts")
    --LoadConstantPs(chunk, total_size, idx, previdx, MoveToNextTok,func)              SetStat("funcs")
    --LoadLines(chunk, total_size, idx, previdx, MoveToNextTok,func)
    LoadFuncProto(chunk, chunkinfo, desc)   SetStat("upvalues")
                   --SetStat("fproto")
                   SetStat("funcs")
    Hexdump(string.sub(chunk, idx, idx+32))

    Load52Upvalues(chunk, chunkinfo, desc)   SetStat("upvalues")
                   SetStat("upvalues")

    Hexdump(string.sub(chunk, idx, idx+32))
    --LoadDebug(chunk, total_size, idx, previdx, MoveToNextTok, func, MoveIdxLen)
    desc.source = LoadString(chunk, chunkinfo)
    print("Source code: ", desc.source)
    desc.pos_source = chunkinfo.previdx
  
    local n = LoadInt(chunk, chunkinfo)
    print("No of Line Numbers:", n)
    desc.lineinfo = {}
    if n ~= 0 then
        for i = 1, n do
            local j = LoadNo(chunk, chunkinfo)
            print("\t Line number:", j)
            desc.lineinfo[i] = j
        end
    end
    desc.pos_lineinfo = chunkinfo.previdx
    desc.sizelineinfo = n
    SetStat("lines")

    local k = LoadNo(chunk, chunkinfo)
    desc.pos_locvars = chunkinfo.previdx
    desc.locvars     = {}
    desc.sizelocvars = k
    print("No of Local variables:", k)
    if k ~= 0 then
        for i = 1, k do
            lvars = LoadString(chunk, chunkinfo)
        end
    end
    SetStat("locals")

    Hexdump(string.sub(chunk, idx, idx+32))
    local start = LoadNo(chunk, chunkinfo)
    print("Goes into scope at instruction:", start)
    local stop = LoadNo(chunk, chunkinfo)
    print("Goes out of scope at instruction:", stop)
    desc.nups = LoadNo(chunk, chunkinfo)
    print("No of Upvalues:", nups)

    return desc
    -- end of Load52Function
end

-- References : https://github.com/viruscamp/luadec/blob/master/ChunkSpy/ChunkSpy53.lua
--              https://the-ravi-programming-language.readthedocs.io/en/latest/lua_bytecode_reference.html
--              https://raw.githubusercontent.com/viruscamp/luadec/master/ChunkSpy/ChunkSpy53.lua
function Load53Function(dechunker, chunk, chunkinfo, funcname, num, level)
    local desc       = {}
    local idx        = chunkinfo.idx
    local previdx    = chunkinfo.previdx
    local total_size = chunkinfo.chunk_size

    local function CheckLuaSignature(size, idx, chunk)
        local lua53signature = "\x19\x93\x0d\x0a\x1a\x0a"

        len = string.len(lua53signature)
        IsChunkSizeOk(len, idx, size, "lua53 signature")

        if string.sub(chunk, idx, len) ~= lua53signature then
            print("Lua 5.3 signature not found, this is not a Lua5.3 chunk")
        end

        return idx+len
    end

    -------------------------------------------------------------
    -- body of LoadFunction() starts here
    -------------------------------------------------------------
    -- statistics handler
    local start       = chunkinfo.idx
    desc.stat         = {}
    desc.stat.funcs   = 0
    desc.stat.locvars = {}
    local function SetStat(item, chunkinfo)
        desc.stat[item] = chunkinfo.idx - start
        start = chunkinfo.idx
    end
    print("Loading string at "..string.format("%x", chunkinfo.idx).." 0x"..string.format("%x", chunkinfo.idx))
    Hexdump(chunk)

    --idx = CheckLuaSignature(total_size, idx, chunk)
    local str = {}

    chunkinfo.idx = chunkinfo.idx + 1
    --desc.source 
    print("idx: "..string.format("%x", chunkinfo.idx).." previdx: "..chunkinfo.previdx)
    str.val, str.len, str.islong= LoadLua53String(chunk, chunkinfo)
    print("Source code: ", str.val, str.len)
    desc.pos_source = chunkinfo.previdx
    print("idx: "..string.format("%x", chunkinfo.idx).." previdx: "..chunkinfo.previdx)

    -- line where the function was defined
    desc.linedefined = LoadInt(chunk, chunkinfo)
    print("Pos :".. desc.linedefined.." 0x"..string.format("%x", desc.linedefined))
    desc.pos_linedefined = previdx
    desc.lastlinedefined = LoadInt(chunk, chunkinfo)
    print("Last line :"..desc.lastlinedefined.." 0x"..string.format("%x", desc.lastlinedefined))
    print "1"

    -------------------------------------------------------------
    -- some byte counts
    -------------------------------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    desc.numparams    = LoadByte(chunk, chunkinfo)
    desc.is_vararg    = LoadByte(chunk, chunkinfo)
    desc.maxstacksize = LoadByte(chunk, chunkinfo)
    SetStat("header", chunkinfo)
    chunkinfo.idx = chunkinfo.idx - 1 -- FIXME
    print("Num params :"..desc.numparams)
    print("Max stack size :"..desc.maxstacksize.." idx "..string.format("%x", chunkinfo.idx))
    print "3"

    LoadCode(chunk, chunkinfo, desc)                 SetStat("code", chunkinfo)
    print "3.4"
    print("idx "..string.format("%x", chunkinfo.idx))

    nc  = LoadConstantsLua53(chunk, chunkinfo, desc) SetStat("consts", chunkinfo)
    Load53Upvalues(chunk, chunkinfo, desc)           SetStat("upvalues", chunkinfo)
    chunkinfo.idx = chunkinfo.idx + 4
    chunkinfo.previdx = chunkinfo.previdx + 4
    LoadFuncProto(chunk, chunkinfo, desc) SetStat("proto", chunkinfo)
    SetStat("funcs", chunkinfo)

    local n = LoadInt(chunk, chunkinfo)
    print("No of Line Numbers:", n)
    desc.lineinfo = {}
    if n ~= 0 then
        for i = 1, n do
            local j = LoadNo(chunk, chunkinfo)
            print("\t Line number:", j)
            desc.lineinfo[i] = j
        end
    end
    desc.pos_lineinfo = chunkinfo.previdx
    desc.sizelineinfo = n
    SetStat("lines", chunkinfo)

    local k = LoadNo(chunk, chunkinfo)
    desc.pos_locvars = chunkinfo.previdx
    desc.locvars = {}
    desc.sizelocvars = k
    print("No of Local variables:", k)
    if k ~= 0 then
        for i = 1, k do
            lvars = LoadString(chunk, chunkinfo)
        end
    end
    SetStat("locals", chunkinfo)

    --local start = LoadNo(chunk, total_size, idx, MoveToNextTok)
    --print("Goes into scope at instruction:", start)
    --local stop = LoadNo(chunk, total_size, idx, MoveToNextTok)
    --print("Goes out of scope at instruction:", stop)
    --desc.nups = LoadNo(chunk, total_size, idx, MoveToNextTok)
    desc.nups = 0
    print("No of Upvalues:", nups)
    -- Fixups
    desc.upvalues = {} -- FIXME : desc.upvalues stores a table that messes with DescribeInst
    local locvar = {}
    locvar.varname = "NONE"
    locvar.pos_varname = 0
    locvar.startpc = 0
    locvar.pos_startpc = 0
    locvar.endpc = 0
    locvar.pos_endpc = 0
    desc.locvars[1] = locvar
    return desc
    -- end of Load53Function
end

-- Lua 5.1 and 5.2 Header structures are identical
-- From lua source file lundump.c
function LuaChunkHeader(dechunker, chunk, chunkinfo, oconfig)
    local size      = chunkinfo.chunk_size
    local name      = chunkinfo.chunk_name
    local chunkdets = {}
    local stat      = chunkinfo.stats
    local idx       = chunkinfo.idx
    local previdx   = chunkinfo.previdx

    --
    -- initialize listing display
    --
    OutputHeader(size, name, chunk, idx)

    --
    -- test signature
    --
    len = dechunker.Func_CheckSignature(chunk, chunkinfo, oconfig)
    FormatLine(chunk, len, "header signature: "..EscapeString(config.SIGNATURE, 1), idx)

    --
    -- test version
    --
    chunkinfo.version = dechunker.Func_CheckVersion(chunk, chunkinfo, oconfig)
    FormatLine(chunk, 1, "version (major:minor hex digits)", chunkinfo.previdx)
    chunkdets.version  = chunkinfo.version

    --
    -- test format (5.1)
    -- * Dechunk does not accept anything other than 0. For custom
    -- * binary chunks, modify Dechunk to read it properly.
    --
    chunkinfo.format = dechunker.Func_CheckFormat(chunk, chunkinfo, oconfig)
    FormatLine(chunk, 1, "format (0=official)", chunkinfo.previdx)

    if chunkdets.version == 83 then
        local cfg_LUAC_DATA = "\25\147\r\n\26\n"
        local len = string.len(cfg_LUAC_DATA)
        print("Length of LUAC_DATA is ",len)
        local LUAC_DATA = LoadBlock(len, chunk, chunkinfo)
        --print("Read Luac_data as", LUAC_DATA)
        if LUAC_DATA ~= cfg_LUAC_DATA then
            error("header LUAC_DATA not found, this is not a Lua chunk")
        end
        FormatLine(chunk, len, "LUAC_DATA: "..cfg_LUAC_DATA, chunkinfo.previdx)
    else

        --
        -- test endianness
        --
        endianness = CheckEndianness(chunk, chunkinfo, oconfig)
        FormatLine(chunk, 1, "endianness (1=little endian)", chunkinfo.previdx)
        chunkdets.endianness = endianness
    end

    Hexdump(chunk)

    --
    -- test sizes
    --
    -- byte sizes
    dechunker.Func_CheckSizes(chunk, chunkinfo, "int", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "int", "bytes"), chunkinfo.previdx)
    dechunker.Func_CheckSizes(chunk, chunkinfo, "size_t", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "size_t", "bytes"), chunkinfo.previdx)
    dechunker.Func_CheckSizes(chunk, chunkinfo, "Instruction", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "Instruction", "bytes"), chunkinfo.previdx)
    dechunker.Func_CheckSizes(chunk, chunkinfo, "number", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "number", "bytes"), chunkinfo.previdx)
    -- initialize decoder (see the 5.0.2 script if you want to customize
    -- bit field sizes; Lua 5.1 has fixed instruction bit field sizes)
    DecodeInit(oconfig)

    if chunkdets.version ~= 83 then

        --
        -- test integral flag (5.1)
        --
        CheckIntegral(chunk, chunkinfo)
        FormatLine(chunk, 1, "integral (1=integral)", chunkinfo.previdx)

        --
        -- verify or determine lua_Number type
        --
        CheckLuaNumber(oconfig)
        DescLine("* number type: "..oconfig:GetLuaNumberType())
    else
        GetLuaIntSize()
        CheckLuaNumber(oconfig)
        DescLine("* number type: "..oconfig:GetLuaNumberType())

        --- TODO Next : convert the following into luascope mechanism
        ---------------------------------------------------------------
        -- test endianness
        -- LUAC_INT = 0x5678 in lua 5.3
        ---------------------------------------------------------------
        local convert_from_int = convert_from["int"]
        if not convert_from_int then
            error("could not find conversion function for int")
        end
        IsChunkSizeOk(8, idx, size, "endianness bytes")
        local endianness_bytes = LoadBlock(8, chunk, chunkinfo)
        local endianness_value = convert_from_int(endianness_bytes, 8)
        --MoveToNextTok(size)
        --
        --if not config.AUTO_DETECT then
        --  if endianness ~= config.endianness then
        --    error("unsupported endianness")
        --  end
        --else
        --  config.endianness = endianness
        --end
        --
        FormatLine(chunk, 8, "endianness bytes "..string.format("0x%x", endianness_value), chunkinfo.previdx)
      
        ---------------------------------------------------------------
        -- test endianness
        -- LUAC_NUM = cast_num(370.5) in lua 5.3
        ---------------------------------------------------------------
        local convert_from_double = convert_from["double"]
        if not convert_from_double then
            error("could not find conversion function for double")
        end
        print("Total Size"..size.."Current index"..string.format("%x", idx))
        IsChunkSizeOk(8, idx, size, "float format bytes")
        local float_format_bytes = LoadBlock(8, chunk, chunkinfo)
        print("float bytes "..float_format_bytes)
        local float_format_value = convert_from_double(float_format_bytes)
        FormatLine(chunk, 8, "float format "..float_format_value, chunkinfo.previdx)
      
        IsChunkSizeOk(1, idx, size, "global closure nupvalues")
        local global_closure_nupvalues = LoadByte(chunk, chunkinfo)
        FormatLine(chunk, 1, "global closure nupvalues "..global_closure_nupvalues, chunkinfo.previdx)
  
        -- end of global header
        stat.header = idx - 1
        DisplayStat("* global header = "..stat.header.." bytes", oconfig)
        DescLine("** global header end **")
    end


    init_scope_config_description()
    DescLine("* "..oconfig:GetLuaDescription())
    if ShouldIPrintBrief() then WriteLine(oconfig:GetOutputComment()..oconfig:GetLuaDescription()) end
    -- end of global header
    stat.header = idx - 1
    DisplayStat("* global header = "..stat.header.." bytes", oconfig)
    DescLine("** global header end **")

    return chunkinfo.idx, chunkinfo.previdx, chunkdets
end

local LuaDechunker   = {}
local Lua51Dechunker = {}
local Lua52Dechunker = {}
local Lua53Dechunker = {}
LuaDechunker.__index = LuaDechunker

LuaDechunker = {
    Func_DescFunction          = DescFunction,
    Func_DechunkHeader         = LuaChunkHeader,
    Func_DechunkGlobalHeader,
    Func_LoadFunction          = LoadFunction,
    Func_LoadUpvalues          = LoadUpvalues,
    Func_LoadString            = LoadString,
    Func_LoadByte              = LoadByte,
    Func_LoadBlock             = LoadBlock,
    Func_LoadNo                = LoadNo,
    Func_LoadInt               = LoadInt,
    Func_LoadSize              = LoadSize,
    Func_LoadNumber            = LoadNumber,
    Func_LoadLines             = LoadLines,
    Func_LoadLocals            = LoadLocals,
    Func_LoadFuncProto         = LoadFuncProto,
    Func_LoadCode              = LoadCode,
    Func_LoadConstantPs        = LoadConstantPs,
    Func_LoadDebug             = LoadDebug,
    Func_LoadConstantKs        = LoadConstantKs,
    Func_CheckSignature        = CheckSignature,
    Func_CheckVersion          = CheckVersion,
    Func_CheckFormat           = CheckFormat,
    Func_CheckEndianness       = CheckEndianness,
    Func_CheckSizes            = CheckSizes,
    Func_CheckIntegral         = CheckIntegral,
    Func_CheckLuaNumber        = CheckLuaNumber,
    Func_CheckLuaSignature     = CheckLuaSignature
}

Lua51Dechunker = {
    Func_DescFunction          = DescFunction,
    Func_DechunkHeader         = LuaChunkHeader,
    Func_DechunkGlobalHeader,
    Func_LoadFunction          = Load51Function,
    Func_LoadUpvalues          = Load51Upvalues,
    Func_LoadString            = LoadString,
    Func_LoadByte              = LoadByte,
    Func_LoadFuncProto         = LoadFuncProto,
}

Lua52Dechunker = {
    Func_DescFunction          = DescFunction,
    Func_DechunkHeader         = LuaChunkHeader,
    Func_DechunkGlobalHeader,
    Func_LoadFunction          = Load52Function,
    Func_LoadUpvalues          = Load52Upvalues,
    Func_LoadString            = LoadString,
    Func_LoadByte              = LoadByte,
    Func_LoadFuncProto         = LoadFuncProto,
    Func_CheckSignature        = Check52Signature,
}

Lua53Dechunker = {
    Func_DescFunction          = DescFunction,
    Func_DechunkHeader         = LuaChunkHeader,
    Func_DechunkGlobalHeader,
    Func_LoadFunction          = Load53Function,
    Func_LoadUpvalues          = Load52Upvalues,
    Func_LoadString            = LoadString,
    Func_LoadByte              = LoadByte53,
    Func_LoadFuncProto         = LoadFuncProto,
}

--
-- Dechunk main processing function
-- * in order to maintain correct positional order, the listing will
--   show functions as nested; a level number is kept to help the
--   user trace the extent of functions in the listing
--
function Dechunk(chunk_name, chunk, oconfig)
    local chunkinfo = {}     -- table with all parsed data, descriptor for chunk
    chunkinfo.chunk_name = chunk_name or ""
    chunkinfo.chunk_size = string.len(chunk)
    chunkinfo.stats      = {}
    chunkinfo.idx        = 1
    chunkinfo.previdx    = 0

    setmetatable(Lua51Dechunker, LuaDechunker)
    setmetatable(Lua52Dechunker, LuaDechunker)
    setmetatable(Lua53Dechunker, LuaDechunker)

    --[[
    -- Display support functions
    -- * considerable work is done to maintain nice alignments
    -- * some widths are initialized at chunk start
    -- * this is meant to make output customization easy
    --]]

    chunkinfo.idx, chunkinfo.previdx, dets = LuaDechunker:Func_DechunkHeader(chunk, chunkinfo, oconfig)

    if dets.version == 81 then
        --
        --  Lua version 5.1
        --
        -- actual call to start the function loading process
        --
        chunkinfo.desc = Lua51Dechunker:Func_LoadFunction(chunk, chunkinfo, "(chunk)", 0, 1)
        DescFunction(chunk, chunkinfo.desc, 0, 1, oconfig)
        chunkinfo.stats.total = chunkinfo.idx - 1
        -- TODO DisplayStat(chunk, "* TOTAL size = "..stat.total.." bytes", oconfig)
        FormatLine(chunk, 0, "** end of chunk **", chunkinfo.idx)
    elseif dets.version == 82 then
        --
        --  Lua Version 5.2
        --
        print "Found Lua 52 chucnk"
        chunkinfo.desc = Lua52Dechunker:Func_LoadFunction(chunk, chunkinfo, "(chunk)", 0, 1)
        DescFunction(chunk, chunkinfo.desc, 0, 1, oconfig)
    elseif dets.version == 83 then
        --
        -- Lua Version 5.3
        --
        print "Found Lua 53 Chunk"
        print "Lua 5.3 is not supported yet"
        chunkinfo.desc = Lua53Dechunker:Func_LoadFunction(chunk, chunkinfo, "(chunk)", 0, 1)
        DescFunction(chunk, chunkinfo.desc, 0, 1, oconfig)
    end

    return chunkinfo
    -- end of Dechunk
end