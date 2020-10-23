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
        DescCode(chunk, desc, oconfig)        -- normal displays positional order
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
local function LoadByte(chunk, previdx, func_movetonext)
    func_movetonext(1)
    return string.byte(chunk, previdx)
end

local function LoadByte53(chunk, idx, func_moveidx)
    func_moveidx(1)
    return string.byte(chunk, idx)
end

--
-- loads a block of endian-sensitive bytes
-- * rest of code assumes little-endian by default
--
local function LoadBlock(size, chunk, total_size, idx, func_movetonext)
    print("LoadBlock Checking for size "..size.." total size "..total_size.." Idx starts at "..string.format("%x", idx))
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
-- loads a number (can be zero) - loadInt can't load zero - used by 5.2
--
local function LoadNo(chunk, total_size, idx, func_movetonext)
    local x = LoadBlock(GetLuaIntSize(), chunk, total_size, idx, func_movetonext)

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
    print("Trying to load string at idx "..string.format("%x", idx).." from total size "..total_size)
    local len = LoadSize(chunk, total_size, idx, func_movetonext)
    if not len then
        error("could not load String")
    else
        if len == 0 then        -- there is no error, return a nil
            print("0-sized string at location "..string.format("%x", idx) )
            return nil
        end
        print("Size in string: "..len.." "..string.format("%x", len))
        idx = idx + GetLuaSizetSize() -- idx was incremented in our caller
        IsChunkSizeOk(len, idx, total_size, "LoadString")
        -- note that ending NUL is removed
        local s = string.sub(chunk, idx, idx + len )
        func_moveidx(len)
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

local function LoadLua53String(chunk, total_size, idx, func_movetonext, func_moveidx)
      print("idx: "..string.format("%x", idx))
      local len = LoadByte53(chunk, idx+1, func_moveidx)
      local islngstr = nil
      if not len then
        error("could not load String")
        return
      end
      print("Lua53string of len "..len.." at idx "..string.format("%x", idx)) 
      if len == 255 then
        len = LoadSize(chunk, total_size, idx, func_movetonext)
        islngstr = true
      end
      if len == 0 then        -- there is no error, return a nil
        return nil, len, islngstr
      end
      if len == 1 then
        return "", len, islngstr
      end
      --TestChunk(len - 1, idx, "LoadString")
      IsChunkSizeOk(len, idx+1, total_size, "LoadString")
      local s = string.sub(chunk, idx+1, idx + len)
      --idx = idx + len - 1
      func_moveidx(len)
      print("Loaded string at idx "..string.format("%x", idx).. " of length "..len .. ">"..s.."<")
      return s, len, islngstr
end

--
-- load line information
--
local function LoadLines(chunk, total_size, idx, previdx, func_movetonext, desc)
    local size = LoadInt(chunk, total_size, idx, func_movetonext)
    desc.pos_lineinfo = previdx
    print("VCVCVC Loading lines "..previdx..desc.pos_lineinfo)
    desc.lineinfo = {}
    desc.sizelineinfo = size
    for i = 1, size do
        desc.lineinfo[i] = LoadInt(chunk, total_size, idx, func_movetonext)
    end
end

--
-- load locals information
--
local function LoadLocals(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    desc.pos_locvars = previdx
    desc.locvars = {}
    desc.sizelocvars = n
    for i = 1, n do
        local locvar = {}
        locvar.varname = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
        locvar.pos_varname = previdx
        locvar.startpc = LoadInt(chunk, total_size, idx, func_movetonext)
        locvar.pos_startpc = previdx
        locvar.endpc = LoadInt(chunk, total_size, idx, func_movetonext)
        locvar.pos_endpc = previdx
        desc.locvars[i] = locvar
    end
end

--
-- load function prototypes information (Used in 5.2)
--
local function LoadFuncProto(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx)
    local n = LoadNo(chunk, total_size, idx, func_movetonext)
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
local function Load52Upvalues(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    print("No of Upvalues", n)
    desc.pos_upvalues = previdx
    desc.upvalues = {}
    desc.sizeupvalues = n
    desc.posupvalues = {}
    local x = LoadBlock(2, chunk, total_size, idx, func_movetonext)
    local y = 0
    for i = 2, 1, -1 do
        y = y * 256 + string.byte(x, i)
    end
    print("Read 2 bytes for upvalue", y)
end

--
-- load upvalues information
--
local function Load53Upvalues(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    print("No of Upvalues", n)
    desc.pos_upvalues = previdx
    desc.upvalues = {}
    desc.sizeupvalues = n
    desc.posupvalues = {}
    for i = 1, n do
        local upvalue = {}
        upvalue.instack = LoadByte(chunk, ix, func_movetonext)
        upvalue.pos_instack = previdx
        upvalue.idx = LoadByte(chunk, ix, func_movetonext)
        upvalue.pos_idx = previdx
        desc.upvalues[i] = upvalue
    end
    print("Read n bytes for upvalue", y)
end

--
-- load upvalues information
--
local function LoadUpvalues(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    if n ~= 0 and n~= desc.nups then
        error(string.format("bad nupvalues: read %d, expected %d", n, desc.nups))
        return
    end
    desc.pos_upvalues = previdx
    desc.upvalues = {}
    desc.sizeupvalues = n
    desc.posdescupvalues = {}
    for i = 1, n do
        desc.upvalues[i] = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
        desc.posupvalues[i] = previdx
        if not desc.upvalues[i] then
            error("empty string at index "..(i - 1).."in upvalue table")
        end
    end
end

--
-- load function code
--
local function LoadCode(chunk, total_size, idx, previdx, func_movetonext, desc)
    local size = LoadInt(chunk, total_size, idx, func_movetonext)
    print("Loading instructions of Size "..size.." at idx "..string.format("%x", idx))
    desc.pos_code = previdx
    desc.code = {}
    desc.sizecode = size
    for i = 1, size do
        desc.code[i] = LoadBlock(GetLuaInstructionSize(), chunk, total_size, idx, func_movetonext)
    end
end

--
-- load constants information (data)
--
local function LoadConstantKs(chunk, total_size, idx, previdx, func_movetonext, func_moveidx, desc)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    desc.pos_ks = previdx
    desc.k = {}
    desc.sizek = n
    desc.posk = {}
    pidx = idx
    ix = idx + GetLuaIntSize()  + 0
    print("Loading "..n.." constants")
    for i = 1, n do
        local t = LoadByte(chunk, ix, func_movetonext)
        pidx = pidx + 1
        ix = ix + 1
        desc.posk[i] = pidx
        if t == GetTypeNumber() then
            print("Got Number")
            desc.k[i] = LoadNumber(chunk, total_size, ix, func_movetonext)
        elseif t == GetTypeBoolean() then
            print("Got boolean")
            local b = LoadByte(chunk, ix, func_movetonext)
            if b == 0 then b = false else b = true end
            desc.k[i] = b
        elseif t == GetTypeString() then
            print("Got string")
            desc.k[i] = LoadString(chunk, total_size, ix, func_movetonext, func_moveidx)
            local strsize = SizeLoadString(chunk, total_size, ix)
            ix = ix + GetLuaSizetSize() + strsize
            pidx = pidx + GetLuaSizetSize() + strsize
        elseif t == GetTypeNIL() then
            print("NIL")
            desc.k[i] = nil
        else
            error(i.." bad constant type "..t.." at "..previdx)
        end
    end--for
end

--
-- load constants information (data)
--
local function LoadConstantsLua53(chunk, total_size, idx, previdx, func_movetonext, func_moveidx, desc)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
    desc.pos_ks = previdx
    desc.k = {}
    desc.sizek = n
    desc.posk = {}
    pidx = idx
    ix = idx + GetLuaIntSize()  + 0
    print("Loading "..n.." constants")
    for i = 1, n do
        local t = LoadByte(chunk, ix, func_movetonext)
        pidx = pidx + 1
        ix = ix + 1
        desc.posk[i] = pidx
        if t == GetTypeNumber() then
            print("Got Number")
            desc.k[i] = LoadNumber(chunk, total_size, ix, func_movetonext)
        elseif t == GetTypeBoolean() then
            print("Got boolean")
            local b = LoadByte(chunk, ix, func_movetonext)
            if b == 0 then b = false else b = true end
            desc.k[i] = b
        elseif t == GetTypeString() then
            print("Got string at "..string.format("%x", idx))
            ix = ix - 1  -- FIXME 5.3
            pidx = pidx - 1  -- FIXME 5.3
            desc.k[i], strsize = LoadLua53String(chunk, total_size, ix, func_movetonext, func_moveidx)
            ix = ix + strsize + 1
            pidx = pidx + strsize + 1
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
local function LoadConstantPs(chunk, total_size, idx, previdx, func_movetonext, desc)
    local n = LoadInt(chunk, total_size, idx, func_movetonext)
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
local function LoadDebug(chunk, total_size, idx, previdx, func_movetonext, desc, func_moveidx)
    desc.source = LoadString(chunk, total_size, idx, func_movetonext, func_moveidx)
    print("Source code: ", desc.source)
    --print("Source code length:", g)
    --local h = LoadNo(chunk, total_size, idx, MoveToNextTok)
    --print("Next 4 bytes:", h)
    --LoadLocals(chunk, total_size, idx, previdx, MoveToNextTok, func, MoveIdxLen)     SetStat("locals")

    local i = LoadInt(chunk, total_size, idx, func_movetonext)
    print("Next 4 bytes:", i)
    local j = LoadNo(chunk, total_size, idx, func_movetonext)
    print("Next 4 bytes:", j)
    local k = LoadNo(chunk, total_size, idx, func_movetonext)
    print("Next 4 bytes:", k)
end

--
-- this is recursively called to load the chunk or function body
--
function Load51Function(dechunker, chunk, descp, ix, pix, funcname, num, level)
    local desc       = {}
    local idx        = ix
    local previdx    = pix
    local total_size = desc.size

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
    desc.stat = {}
    local function SetStat(item)
        desc.stat[item] = idx - start
        start = idx
    end

    -- source file name
    print("Loading string at "..string.format("%x", idx))
    desc.source = LoadString(chunk, total_size, idx, MoveToNextTok, MoveIdxLen)
    desc.pos_source = previdx
    if desc.source == "" and level == 1 then desc.source = funcname end

    -- line where the function was defined
    print("Func source:" .. desc.source)
    desc.linedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Pos ".. desc.linedefined)
    desc.pos_linedefined = previdx
    desc.lastlinedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Last line"..desc.lastlinedefined)
    print "1"

    -------------------------------------------------------------
    -- some byte counts
    -------------------------------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    desc.nups = LoadByte(chunk, idx, MoveToNextTok)
    desc.numparams = LoadByte(chunk, idx, MoveToNextTok)
    desc.is_vararg = LoadByte(chunk, idx, MoveToNextTok)
    desc.maxstacksize = LoadByte(chunk, idx, MoveToNextTok)
    SetStat("header")
    print("Num params"..desc.numparams)
    print("Max stack size"..desc.maxstacksize)
    print "2"

    -------------------------------------------------------------
    -- these are lists, LoadConstantPs() may be recursive
    -------------------------------------------------------------
    -- load parts of a chunk (rearranged in 5.1)
    LoadCode(chunk, total_size, idx, previdx, MoveToNextTok, desc)                   SetStat("code")
    print "2.4"
    LoadConstantKs(chunk, total_size, idx, previdx, MoveToNextTok, MoveIdxLen, desc) SetStat("consts")
    print "2.8"
    LoadConstantPs(chunk, total_size, idx, previdx, MoveToNextTok,desc)              SetStat("funcs")
    print "3"
    LoadLines(chunk, total_size, idx, previdx, MoveToNextTok,desc)                   SetStat("lines")
    LoadLocals(chunk, total_size, idx, previdx, MoveToNextTok, desc, MoveIdxLen)     SetStat("locals")
    LoadUpvalues(chunk, total_size, idx, previdx, MoveToNextTok, desc, MoveIdxLen)   SetStat("upvalues")

    return desc
    -- end of Load51Function
end

-- References : lundump.[ch], http://files.catwell.info/misc/mirror/lua-5.2-bytecode-vm-dirk-laurie/lua52vm.html
function Load52Function(dechunker, chunk, descp, ix, pix, funcname, num, level)
    local desc       = {}
    local idx        = ix
    local previdx    = pix
    local total_size = desc.chunk_size

    local function MoveToNextTok(size)
        previdx = idx
        idx = idx + size
    end

    local function MoveIdxLen(len)
        idx = idx + len
    end

    local function Check52Signature(size, idx, chunk)
        local lua52signature = "\x19\x93\x0d\x0a\x1a\x0a"

        len = string.len(lua52signature)
        IsChunkSizeOk(len, idx, size, "lua52 signature")

        if string.sub(chunk, idx, len) ~= lua52signature then
            print("Lua 5.2 signature not found, this is not a Lua5.2 chunk")
        end

        return idx+len
    end

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
    idx = Check52Signature(total_size, idx, chunk)

    -- line where the function was defined
    desc.linedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Pos :".. desc.linedefined)
    desc.pos_linedefined = previdx
    desc.lastlinedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Last line :"..desc.lastlinedefined)
    print "1"

    -------------------------------------------------------------
    -- some byte counts
    --------------------desc-----------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    desc.numparams = LoadByte(chunk, idx, MoveToNextTok)
    desc.is_vararg = LoadByte(chunk, idx, MoveToNextTok)
    desc.maxstacksize = LoadByte(chunk, idx, MoveToNextTok)
    SetStat("header")
    print("Num params :"..desc.numparams)
    print("Max stack size :"..desc.maxstacksize)
    print "2"

    -- load parts of a chunk
    LoadCode(chunk, total_size, idx, previdx, MoveToNextTok, desc)                   SetStat("code")
    print "2.4"
    LoadConstantKs(chunk, total_size, idx, previdx, MoveToNextTok, MoveIdxLen, desc) SetStat("consts")
    --LoadConstantPs(chunk, total_size, idx, previdx, MoveToNextTok,func)              SetStat("funcs")
    --LoadLines(chunk, total_size, idx, previdx, MoveToNextTok,func)
    LoadFuncProto(chunk, total_size, idx, previdx, MoveToNextTok, desc, MoveIdxLen)   SetStat("upvalues")
                   --SetStat("fproto")
                   SetStat("funcs")
    Hexdump(string.sub(chunk, idx, idx+32))

    Load52Upvalues(chunk, total_size, idx, previdx, MoveToNextTok, desc, MoveIdxLen)   SetStat("upvalues")
                   SetStat("upvalues")

    Hexdump(string.sub(chunk, idx, idx+32))
    --LoadDebug(chunk, total_size, idx, previdx, MoveToNextTok, func, MoveIdxLen)
    desc.source = LoadString(chunk, total_size, idx, MoveToNextTok, MoveIdxLen)
    print("Source code: ", desc.source)
    desc.pos_source = previdx
  
    local n = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("No of Line Numbers:", n)
    desc.lineinfo = {}
    if n ~= 0 then
        for i = 1, n do
            local j = LoadNo(chunk, total_size, idx, MoveToNextTok)
            print("\t Line number:", j)
            desc.lineinfo[i] = j
        end
    end
    desc.pos_lineinfo = previdx
    desc.sizelineinfo = n
    SetStat("lines")

    local k = LoadNo(chunk, total_size, idx, MoveToNextTok)
    desc.pos_locvars = previdx
    desc.locvars = {}
    desc.sizelocvars = k
    print("No of Local variables:", k)
    if k ~= 0 then
        for i = 1, k do
            lvars = LoadString(chunk, total_size, idx, MoveToNextTok, MoveIdxLen)
        end
    end
    SetStat("locals")

    Hexdump(string.sub(chunk, idx, idx+32))
    local start = LoadNo(chunk, total_size, idx, MoveToNextTok)
    print("Goes into scope at instruction:", start)
    local stop = LoadNo(chunk, total_size, idx, MoveToNextTok)
    print("Goes out of scope at instruction:", stop)
    desc.nups = LoadNo(chunk, total_size, idx, MoveToNextTok)
    print("No of Upvalues:", nups)

    return desc
    -- end of Load52Function
end

-- References : https://github.com/viruscamp/luadec/blob/master/ChunkSpy/ChunkSpy53.lua
--              https://the-ravi-programming-language.readthedocs.io/en/latest/lua_bytecode_reference.html
--              https://raw.githubusercontent.com/viruscamp/luadec/master/ChunkSpy/ChunkSpy53.lua
function Load53Function(dechunker, chunk, descp, ix, pix, funcname, num, level)
    local desc       = {}
    local idx        = ix
    local previdx    = pix
    local total_size = descp.chunk_size

    local function MoveToNextTok(size)
        previdx = idx
        idx = idx + size
    end

    local function MoveIdxLen(len)
        idx = idx + len
    end

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
    local start = idx
    desc.stat = {}
    desc.stat.funcs = 0
    desc.stat.locvars = {}
    local function SetStat(item)
        desc.stat[item] = idx - start
        start = idx
    end
    print("Loading string at "..string.format("%x", idx).." 0x"..string.format("%x", idx))
    Hexdump(chunk)
    previdx = idx
    --idx = CheckLuaSignature(total_size, idx, chunk)
    local str = {}
    --desc.source 
    print("idx: "..string.format("%x", idx).." previdx: "..previdx)
    str.val, str.len, str.islong= LoadLua53String(chunk, total_size, idx, MoveToNextTok, MoveIdxLen)
    print("Source code: ", str.val, str.len)
    desc.pos_source = previdx
    print("idx: "..string.format("%x", idx).." previdx: "..previdx)

    -- line where the function was defined
    desc.linedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Pos :".. desc.linedefined.." 0x"..string.format("%x", desc.linedefined))
    desc.pos_linedefined = previdx
    desc.lastlinedefined = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("Last line :"..desc.lastlinedefined.." 0x"..string.format("%x", desc.lastlinedefined))
    print "1"

    -------------------------------------------------------------
    -- some byte counts
    --------------------desc-----------------------------------------
    if IsChunkSizeOk(4, idx, total_size, "function header") then return end
    desc.numparams = LoadByte(chunk, idx, MoveToNextTok)
    desc.is_vararg = LoadByte(chunk, idx, MoveToNextTok)
    desc.maxstacksize = LoadByte(chunk, idx, MoveToNextTok)
    SetStat("header")
    print("Num params :"..desc.numparams)
    print("Max stack size :"..desc.maxstacksize.." idx "..string.format("%x", idx))
    print "3"

    -- load parts of a chunk
    LoadCode(chunk, total_size, idx, previdx, MoveToNextTok, desc)                   SetStat("code")
    print "3.4"
    print("idx "..string.format("%x", idx))
    Hexdump(string.sub(chunk, idx, idx+32))

    nc  = LoadConstantsLua53(chunk, total_size, idx, previdx, MoveToNextTok, MoveIdxLen, desc) SetStat("consts")
    idx = idx + nc -- FIXME 
    previdx = previdx + nc -- FIXME
    Load53Upvalues(chunk, total_size, idx, previdx, MoveToNextTok, desc, MoveIdxLen)   SetStat("upvalues")
    LoadFuncProto(chunk, total_size, idx, previdx, MoveToNextTok, desc, MoveIdxLen) SetStat("proto")
    SetStat("funcs")

    local n = LoadInt(chunk, total_size, idx, MoveToNextTok)
    print("No of Line Numbers:", n)
    desc.lineinfo = {}
    if n ~= 0 then
        for i = 1, n do
            local j = LoadNo(chunk, total_size, idx, MoveToNextTok)
            print("\t Line number:", j)
            desc.lineinfo[i] = j
        end
    end
    desc.pos_lineinfo = previdx
    desc.sizelineinfo = n
    SetStat("lines")

    local k = LoadNo(chunk, total_size, idx, MoveToNextTok)
    desc.pos_locvars = previdx
    desc.locvars = {}
    desc.sizelocvars = k
    print("No of Local variables:", k)
    if k ~= 0 then
        for i = 1, k do
            lvars = LoadString(chunk, total_size, idx, MoveToNextTok, MoveIdxLen)
        end
    end
    SetStat("locals")

    Hexdump(string.sub(chunk, idx, idx+32))
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

function CheckSignature(size, idx, chunk, oconfig)
    len = string.len(oconfig:GetSign())
    IsChunkSizeOk(len, idx, size, "header signature")
    if string.sub(chunk, 1, len) ~= oconfig:GetSign() then
        error("header signature not found, this is not a Lua chunk")
    end

    return len
end

function CheckVersion(size, idx, chunk, func_movetonext, oconfig)
    IsChunkSizeOk(1, idx, size, "version byte")
    ver = LoadByte(chunk, idx, func_movetonext)
    if ver ~= oconfig:GetVersion() then
        error(string.format("Dechunk(%s) cannot read version %02X chunks", oconfig:GetVersion(), ver))
        --print(string.format("Dechunk cannot read version %02X chunks", ver))
    end

    return ver
end

function CheckFormat(size, idx, chunk, func_movetonext, oconfig)
    IsChunkSizeOk(1, idx, size, "format byte")
    format = LoadByte(chunk, idx, func_movetonext)
    if format ~= oconfig:GetFormat() then
        error(string.format("Dechunk cannot read format %02X chunks", format))
    end

    return format
end

function CheckEndianness(size, idx, chunk, func_movetonext, oconfig)
    IsChunkSizeOk(1, idx, size, "endianness byte")
    local endianness = LoadByte(chunk, idx, func_movetonext)
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

function CheckSizes(size, idx, previdx, chunk, func_movetonext, mysize, sizename, oconfig)
    IsChunkSizeOk(4, idx, size, "size bytes")
    local byte = LoadByte(chunk, idx, func_movetonext)
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

function CheckIntegral(size, idx, chunk, func_movetonext)
    IsChunkSizeOk(1, idx, size, "integral byte")
    SetLuaIntegral(LoadByte(chunk, idx, func_movetonext))
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

-- Lua 5.1 and 5.2 Header structures are identical
-- From lua source file lundump.c
function LuaChunkHeader(size, name, chunk, result, idx, previdx, stat,
                        func_movetonext, oconfig)
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
    len = CheckSignature(size, idx, chunk, oconfig)
    FormatLine(chunk, len, "header signature: "..EscapeString(config.SIGNATURE, 1), idx)
    idx = idx + len

    --
    -- test version
    --
    result.version = CheckVersion(size, idx, chunk,
                                  MoveToNextTok, oconfig)
    FormatLine(chunk, 1, "version (major:minor hex digits)", previdx)
    chunkdets.version  = result.version

    --
    -- test format (5.1)
    -- * Dechunk does not accept anything other than 0. For custom
    -- * binary chunks, modify Dechunk to read it properly.
    --
    result.format = CheckFormat(size, idx, chunk,
                                MoveToNextTok, oconfig)
    FormatLine(chunk, 1, "format (0=official)", previdx)

if chunkdets.version == 83 then
    local cfg_LUAC_DATA = "\25\147\r\n\26\n"
    local len = string.len(cfg_LUAC_DATA)
    --print("Length of LUAC_DATA is ",len)
    local LUAC_DATA = LoadBlock(len, chunk, size, idx, func_movetonext)
    --print("Read Luac_data as", LUAC_DATA)
    if LUAC_DATA ~= cfg_LUAC_DATA then
        error("header LUAC_DATA not found, this is not a Lua chunk")
    end
    FormatLine(chunk, len, "LUAC_DATA: "..cfg_LUAC_DATA, previdx)
    MoveIdxLen(6)
else

    --
    -- test endianness
    --
    endianness = CheckEndianness(size, idx, chunk,
                                MoveToNextTok, oconfig)
    FormatLine(chunk, 1, "endianness (1=little endian)", previdx)
    chunkdets.endianness = endianness
end

    Hexdump(chunk)

    --
    -- test sizes
    --
    -- byte sizes
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok,
               "size_int", "int", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "int", "bytes"), previdx)
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok,
               "size_size_t", "size_t", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "size_t", "bytes"), previdx)
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok,
               "size_Instruction", "Instruction", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "Instruction", "bytes"), previdx)
    CheckSizes(size, idx, previdx, chunk, MoveToNextTok,
               "size_lua_Number", "number", oconfig)
    FormatLine(chunk, 1, string.format("size of %s (%s)",
               "number", "bytes"), previdx)
    -- initialize decoder (see the 5.0.2 script if you want to customize
    -- bit field sizes; Lua 5.1 has fixed instruction bit field sizes)
    DecodeInit(oconfig)

    if chunkdets.version ~= 83 then

        --
        -- test integral flag (5.1)
        --
        CheckIntegral(size, idx, chunk, MoveToNextTok)
        FormatLine(chunk, 1, "integral (1=integral)", previdx)

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
        local endianness_bytes = LoadBlock(8, chunk, size, idx, MoveToNextTok)
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
        FormatLine(chunk, 8, "endianness bytes "..string.format("0x%x", endianness_value), previdx)
      
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
        local float_format_bytes = LoadBlock(8, chunk, size, idx, MoveToNextTok)
        print("float bytes "..float_format_bytes)
        local float_format_value = convert_from_double(float_format_bytes)
        FormatLine(chunk, 8, "float format "..float_format_value, previdx)
      
        IsChunkSizeOk(1, idx, size, "global closure nupvalues")
        local global_closure_nupvalues = LoadByte(chunk, idx, MoveToNextTok)
        FormatLine(chunk, 1, "global closure nupvalues "..global_closure_nupvalues, previdx)
  
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

    return idx, previdx, chunkdets
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
    ---------------------------------------------------------------
    -- variables
    ---------------------------------------------------------------
    local idx = 1
    local previdx, len
    local descp = {}     -- table with all parsed data, descriptor for chunk
    local stat = {}
    descp.chunk_name = chunk_name or ""
    descp.chunk_size = string.len(chunk)

    setmetatable(Lua51Dechunker, LuaDechunker)
    setmetatable(Lua52Dechunker, LuaDechunker)
    setmetatable(Lua53Dechunker, LuaDechunker)

    --[[
    -- Display support functions
    -- * considerable work is done to maintain nice alignments
    -- * some widths are initialized at chunk start
    -- * this is meant to make output customization easy
    --]]

    idx, previdx, dets = LuaChunkHeader(descp.chunk_size, descp.chunk_name,
                                        chunk, descp, idx, previdx,
                                        stat, MoveToNextTok, oconfig)

    if dets.version == 81 then
        --
        --  Lua version 5.1
        --
        -- actual call to start the function loading process
        --
        descp.desc = Lua51Dechunker:Func_LoadFunction(chunk, descp, idx, previdx, "(chunk)", 0, 1)
        DescFunction(chunk, descp.desc, 0, 1, oconfig)
        stat.total = idx - 1
        DisplayStat(chunk, "* TOTAL size = "..stat.total.." bytes", oconfig)
        descp.stat = stat
        FormatLine(chunk, 0, "** end of chunk **", idx)
    elseif dets.version == 82 then
        --
        --  Lua Version 5.2
        --
        print "Found Lua 52 chucnk"
        descp.desc = Lua52Dechunker:Func_LoadFunction(chunk, descp, idx, previdx, "(chunk)", 0, 1)
        DescFunction(chunk, descp.desc, 0, 1, oconfig)
    elseif dets.version == 83 then
        --
        -- Lua Version 5.3
        --
        print "Found Lua 53 Chunk"
        print "Lua 5.3 is not supported yet"
        descp.desc = Lua53Dechunker:Func_LoadFunction(chunk, descp, idx, previdx, "(chunk)", 0, 1)
        DescFunction(chunk, descp.desc, 0, 1, oconfig)
    end

    return descp
    -- end of Dechunk
end