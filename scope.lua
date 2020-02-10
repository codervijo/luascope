#!/usr/bin/lua

--[[
  Lua Scope
  A Lua 5.1/5.2/5.3 binary chunk disassembler
  LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]


title = [[
LuaScope: A Lua debugger/disassembler
Version 0.0.1 (20200210)  Copyright (c) 2019-2020 Vijo Cherian
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