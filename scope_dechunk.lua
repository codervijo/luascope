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

  ---------------------------------------------------------------
  -- tests if a given number of bytes is available
  ---------------------------------------------------------------
  local function IsChunkSizeOk(size, idx, errmsg)
    if idx + size - 1 > result.chunk_size then
      error(string.format("chunk too small for %s at offset %d", errmsg, idx - 1))
    end
  end

  ---------------------------------------------------------------
  -- loads a single byte and returns it as a number
  ---------------------------------------------------------------
  local function LoadByte()
    previdx = idx
    idx = idx + 1
    return string.byte(chunk, previdx)
  end

  -------------------------------------------------------------
  -- loads a block of endian-sensitive bytes
  -- * rest of code assumes little-endian by default
  -------------------------------------------------------------
  local function LoadBlock(size)
    if not pcall(IsChunkSizeOk, size, idx, "LoadBlock") then return end
    previdx = idx
    idx = idx + size
    local b = string.sub(chunk, idx - size, idx - 1)
    if GetLuaEndianness() == 1 then
      return b
    else-- reverse bytes if big endian
      return string.reverse(b)
    end
  end

--
-- * WARNING this will fail for large long longs (64-bit numbers)
--   because long longs exceeds the precision of doubles.
--
convert_to["long long"] = convert_to["int"]

--[[-------------------------------------------------------------------
-- Display support functions
-- * considerable work is done to maintain nice alignments
-- * some widths are initialized at chunk start
-- * this is meant to make output customization easy
--]]-------------------------------------------------------------------


  --
  -- initialize listing display
  --
  DisplayInit(result.chunk_size)
  HeaderLine()                  -- listing display starts here
  if result.chunk_name then
    FormatLine(chunk, 0, "** source chunk: "..result.chunk_name, idx)
    if ShouldIPrintBrief() then WriteLine(GetOutputComment().."source chunk: "..result.chunk_name) end
  end
  DescLine("** global header start **")

  --
  -- test signature
  --
  len = string.len(config.SIGNATURE)
  IsChunkSizeOk(len, idx, "header signature")
  if string.sub(chunk, 1, len) ~= config.SIGNATURE then
    error("header signature not found, this is not a Lua chunk")
  end
  FormatLine(chunk, len, "header signature: "..EscapeString(config.SIGNATURE, 1), idx)
  idx = idx + len

  --
  -- test version
  --
  IsChunkSizeOk(1, idx, "version byte")
  result.version = LoadByte()
  if result.version ~= config.VERSION then
    --error(string.format("Dechunk cannot read version %02X chunks", result.version))
    print(string.format("Dechunk cannot read version %02X chunks", result.version))
  end
  FormatLine(chunk, 1, "version (major:minor hex digits)", previdx)

  --
  -- test format (5.1)
  -- * Dechunk does not accept anything other than 0. For custom
  -- * binary chunks, modify Dechunk to read it properly.
  --
  IsChunkSizeOk(1, idx, "format byte")
  result.format = LoadByte()
  if result.format ~= config.FORMAT then
    error(string.format("Dechunk cannot read format %02X chunks", result.format))
  end
  FormatLine(chunk, 1, "format (0=official)", previdx)

  --
  -- test endianness
  --
  IsChunkSizeOk(1, idx, "endianness byte")
  local endianness = LoadByte()
  if not config.AUTO_DETECT then
    if endianness ~= GetLuaEndianness() then
      error(string.format("unsupported endianness %s vs %s", endianness, GetLuaEndianness()))
    end
  else
    SetLuaEndianness(endianness)
  end
  FormatLine(chunk, 1, "endianness (1=little endian)", previdx)

  --
  -- test sizes
  --
  IsChunkSizeOk(4, idx, "size bytes")
  local function TestSize(mysize, sizename, typename)
    local byte = LoadByte()
    if not config.AUTO_DETECT then
      if byte ~= config[mysize] then
        error(string.format("mismatch in %s size (needs %d but read %d)",
          sizename, config[mysize], byte))
      end
    else
      config[mysize] = byte
    end
    FormatLine(chunk, 1, string.format("size of %s (%s)", sizename, typename), previdx)
  end
  -- byte sizes
  TestSize("size_int", "int", "bytes")
  TestSize("size_size_t", "size_t", "bytes")
  TestSize("size_Instruction", "Instruction", "bytes")
  TestSize("size_lua_Number", "number", "bytes")
  -- initialize decoder (see the 5.0.2 script if you want to customize
  -- bit field sizes; Lua 5.1 has fixed instruction bit field sizes)
  DecodeInit()

  --
  -- test integral flag (5.1)
  --
  IsChunkSizeOk(1, idx, "integral byte")
  SetLuaIntegral(LoadByte())
  FormatLine(chunk, 1, "integral (1=integral)", previdx)

  --
  -- verify or determine lua_Number type
  --
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
  DescLine("* number type: "..GetLuaNumberType())

  init_scope_config_description()
  DescLine("* "..GetLuaDescription())
  if ShouldIPrintBrief() then WriteLine(GetOutputComment()..GetLuaDescription()) end
  -- end of global header
  stat.header = idx - 1
  DisplayStat("* global header = "..stat.header.." bytes")
  DescLine("** global header end **")

  --
  -- this is recursively called to load the chunk or function body
  --
  local function LoadFunction(funcname, num, level)
    local func = {}

    -------------------------------------------------------------
    -- loads an integer (signed)
    -------------------------------------------------------------
    local function LoadInt()
      local x = LoadBlock(GetLuaIntSize())
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

    -------------------------------------------------------------
    -- loads a size_t (assume unsigned)
    -------------------------------------------------------------
    local function LoadSize()
      local x = LoadBlock(GetLuaSizetSize())
      if not x then
        --error("could not load size_t") handled in LoadString()
        return
      else
        local sum = 0
        for i = GetLuaSizetSize(), 1, -1 do
          sum = sum * 256 + string.byte(x, i)
        end
        return sum
      end
    end

    -------------------------------------------------------------
    -- loads a number (lua_Number type)
    -------------------------------------------------------------
    local function LoadNumber()
      local x = LoadBlock(GetLuaNumberSize())
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

    -------------------------------------------------------------
    -- load a string (size, data pairs)
    -------------------------------------------------------------
    local function LoadString()
      local len = LoadSize()
      if not len then
        error("could not load String")
      else
        if len == 0 then        -- there is no error, return a nil
          return nil
        end
        IsChunkSizeOk(len, idx, "LoadString")
        -- note that ending NUL is removed
        local s = string.sub(chunk, idx, idx + len - 2)
        idx = idx + len
        return s
      end
    end

    -------------------------------------------------------------
    -- load line information
    -------------------------------------------------------------
    local function LoadLines()
      local size = LoadInt()
      func.pos_lineinfo = previdx
      func.lineinfo = {}
      func.sizelineinfo = size
      for i = 1, size do
        func.lineinfo[i] = LoadInt()
      end
    end

    -------------------------------------------------------------
    -- load locals information
    -------------------------------------------------------------
    local function LoadLocals()
      local n = LoadInt()
      func.pos_locvars = previdx
      func.locvars = {}
      func.sizelocvars = n
      for i = 1, n do
        local locvar = {}
        locvar.varname = LoadString()
        locvar.pos_varname = previdx
        locvar.startpc = LoadInt()
        locvar.pos_startpc = previdx
        locvar.endpc = LoadInt()
        locvar.pos_endpc = previdx
        func.locvars[i] = locvar
      end
    end

    -------------------------------------------------------------
    -- load upvalues information
    -------------------------------------------------------------
    local function LoadUpvalues()
      local n = LoadInt()
      if n ~= 0 and n~= func.nups then
        error(string.format("bad nupvalues: read %d, expected %d", n, func.nups))
        return
      end
      func.pos_upvalues = previdx
      func.upvalues = {}
      func.sizeupvalues = n
      func.posupvalues = {}
      for i = 1, n do
        func.upvalues[i] = LoadString()
        func.posupvalues[i] = previdx
        if not func.upvalues[i] then
          error("empty string at index "..(i - 1).."in upvalue table")
        end
      end
    end

    -------------------------------------------------------------
    -- load constants information (data)
    -------------------------------------------------------------
    local function LoadConstantKs()
      local n = LoadInt()
      func.pos_ks = previdx
      func.k = {}
      func.sizek = n
      func.posk = {}
      for i = 1, n do
        local t = LoadByte()
        func.posk[i] = previdx
        if t == GetTypeNumber() then
          func.k[i] = LoadNumber()
        elseif t == GetTypeBoolean() then
          local b = LoadByte()
          if b == 0 then b = false else b = true end
          func.k[i] = b
        elseif t == GetTypeString() then
          func.k[i] = LoadString()
        elseif t == GetTypeNIL() then
          func.k[i] = nil
        else
          error("bad constant type "..t.." at "..previdx)
        end
      end--for
    end

    -------------------------------------------------------------
    -- load constants information (local functions)
    -------------------------------------------------------------
    local function LoadConstantPs()
      local n = LoadInt()
      func.pos_ps = previdx
      func.p = {}
      func.sizep = n
      for i = 1, n do
        -- recursive call back on itself, next level
        func.p[i] = LoadFunction(func.source, i - 1, level + 1)
      end
    end

    -------------------------------------------------------------
    -- load function code
    -------------------------------------------------------------
    local function LoadCode()
      local size = LoadInt()
      func.pos_code = previdx
      func.code = {}
      func.sizecode = size
      for i = 1, size do
        func.code[i] = LoadBlock(GetLuaInstructionSize())
      end
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
    func.source = LoadString()
    func.pos_source = previdx
    if func.source == "" and level == 1 then func.source = funcname end
    -- line where the function was defined
    func.linedefined = LoadInt()
    func.pos_linedefined = previdx
    func.lastlinedefined = LoadInt()

    -------------------------------------------------------------
    -- some byte counts
    -------------------------------------------------------------
    if IsChunkSizeOk(4, idx, "function header") then return end
    func.nups = LoadByte()
    func.numparams = LoadByte()
    func.is_vararg = LoadByte()
    func.maxstacksize = LoadByte()
    SetStat("header")

    -------------------------------------------------------------
    -- these are lists, LoadConstantPs() may be recursive
    -------------------------------------------------------------
    -- load parts of a chunk (rearranged in 5.1)
    LoadCode()       SetStat("code")
    LoadConstantKs() SetStat("consts")
    LoadConstantPs() SetStat("funcs")
    LoadLines()      SetStat("lines")
    LoadLocals()     SetStat("locals")
    LoadUpvalues()   SetStat("upvalues")
    return func
    -- end of LoadFunction
  end

  ---------------------------------------------------------------
  -- displays function information
  -- * decoupled from LoadFunction due to 5.1 chunk rearrangement
  ---------------------------------------------------------------
  function DescFunction(chunk, func, num, level)
    -------------------------------------------------------------
    -- body of DescFunction() starts here
    -------------------------------------------------------------
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
  -- actual call to start the function loading process
  --
  result.func = LoadFunction("(chunk)", 0, 1)
  DescFunction(chunk, result.func, 0, 1)
  stat.total = idx - 1
  DisplayStat(chunk, "* TOTAL size = "..stat.total.." bytes")
  result.stat = stat
  FormatLine(chunk, 0, "** end of chunk **", idx)
  return result
  -- end of Dechunk
end