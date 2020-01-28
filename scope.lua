#!/usr/bin/lua

--[[
  Lua Scope
  A Lua 5.1/5.2/5.3 binary chunk disassembler
  LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]


title = [[
LuaScope: A Lua debugger/disassembler
Version 0.0.0 (20190215)  Copyright (c) 2019-2020 Vijo Cherian
The COPYRIGHT file describes the conditions under which this
software may be distributed (basically a Lua 5-style license.)
]]

package.path = package.path .. ";./?.lua;/usr/src/?.lua"

require("scope_config")
require("conv")
require("scope_output")
require("scope_decoder")
require("scope_dechunk")


-- TODO Vijo Make the selection based on output of uname -m
SetProfile("x86_64") -- default profile
-- config.* profile parms set in Dechunk() call...
local ok, _ = pcall(Dechunk, "", LUA_SAMPLE)
--if not ok then error("error compiling sample to test local profile") end

--[[
-- Other globals
--]]

other_files = {}        -- non-chunks (may be source listings)
arg_other = {}          -- other arguments (for --run option)

-----------------------------------------------------------------------
-- No more TEST_NUMBER in Lua 5.1, uses size_lua_Number + integral
-----------------------------------------------------------------------
LUANUMBER_ID = {
  ["80"] = "double",         -- IEEE754 double
  ["40"] = "single",         -- IEEE754 single
  ["41"] = "int",            -- int
  ["81"] = "long long",      -- long long
}

--
-- set the default platform (can override with --auto auto-detection)
-- * both in & out paths use config.* parms, a bit clunky for now
--
config = get_config()
convert_to = get_convert_to()
convert_from = get_convert_from()


--
-- initialize display formatting settings
-- * chunk_size parameter used to set width of position column
--


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
	if config.source then config.srcprev = 0; return end
	if not source or source == "" or
	string.sub(source, 1, 1) ~= "@" then
		return
	end
	source = string.sub(source, 2)                -- chomp leading @
	for _, fname in ipairs(other_files) do        -- find a match
		if not config.source then
			if fname == source or
			 string.lower(fname) == string.lower(source) then
				config.source = fname
			end
		end
	end
	if not config.source then return end          -- no source file
	local INF = io.open(config.source, "rb")      -- read in source file
	if not INF then
		error("cannot read file \""..filename.."\"")
	end
	config.srcline = {}; config.srcmark = {}
	local n, line = 1
	repeat
		line = INF:read("*l")
		if line then
			config.srcline[n], config.srcmark[n] = line, false
			n = n + 1
		end
	until not line
	io.close(INF)
	config.srcsize = n - 1
	config.DISPLAY_SRC_WIDTH = WidthOf(config.srcsize)
	config.srcprev = 0
end
-----------------------------------------------------------------------
-- mark source lines
-- * marks source lines as a function is read to delineate stuff
-----------------------------------------------------------------------
function SourceMark(func)
	if not config.source then return end
	if func.sizelineinfo == 0 then return end
	for i = 1, func.sizelineinfo do
		if i <= config.srcsize then
			config.srcmark[func.lineinfo[i]] = true
		end
	end
end

-----------------------------------------------------------------------
-- generate source lines
-- * peek at lines above and print them if they have not been printed
-- * mark all printed lines so all non-code lines are printed once only
-----------------------------------------------------------------------
function SourceMerge(func, pc)
	if not config.source or not config.DISPLAY_FLAG then return end
	local lnum = func.lineinfo[pc]
	-- don't print anything new if instruction is on the same line
	if config.srcprev == lnum then return end
	config.srcprev = lnum
	if config.srcsize < lnum then return end      -- something fishy
	local lfrom = lnum
	config.srcmark[lnum] = true
	while lfrom > 1 and config.srcmark[lfrom - 1] == false do
		lfrom = lfrom - 1
		config.srcmark[lfrom] = true
	end
	for i = lfrom, lnum do
		WriteLine(GetOutputComment()
		  .."("..ZeroPad(i, config.DISPLAY_SRC_WIDTH)..")"
		  ..config.DISPLAY_SEP..config.srcline[i])
	end
end

function main()
    print("Found Lua Version", _VERSION)
    while not done do
        if prevline then io.stdout:write(">>") else io.stdout:write(">") end
        io.stdout:flush()
        local l = io.stdin:read("*l")
        
        if l == nil or (l == "exit" or l == "quit" and not prevline) then
            done = true
            
        elseif l == "help" and not prevline then
            io.stdout:write(interactive_help, "\n")
            
            -- handle line continuation
            
        elseif string.sub(l, -1, -1) == "\\" then
            if not prevline then prevline = "" end
                prevline = prevline..string.sub(l, 1, -2)
                
                -- compose source chunk, compile, disassemble
                
        else
            if prevline then l = prevline..l; prevline = nil end
            -- loadstring function was present in lua 5.1, and 5.2
            -- it got deprecated in lua 5.3 and is now load()
            -- load() also seems to work in lua 5.2
            local func, msg
            oconfig = Oconfig
            if _VERSION == 'Lua 5.3' then
            	func, msg = load(l, "(interactive mode)")
            	oconfig:SetVersion("5.3")
            else
            	func, msg = loadstring(l, "(interactive mode)")
            	oconfig:SetVersion("5.2")
            end
            func() -- Call the loaded lua string as a function
            if not func then
                print("Dechunk: failed to compile your input")
            else
                binchunk = string.dump(func)
                Dechunk("(interactive mode)", binchunk, oconfig)
            end
            
        end--if l
    end--while
end

main()