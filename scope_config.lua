#!/usr/bin/lua

--[[
    Configuration for Lua Scope
    A Lua 5.1 binary chunk disassembler
    LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]

config = {}
--
--[[
-- Configuration table
-- * Contains fixed constants, display constants and options, and
--   platform-dependent configuration constants
--
-- Configuration settings of binary chunks to be processed. Such tables
-- may be used to sort of "auto-detect" binary chunks from different
-- platforms. More or less equivalent to the global header.
-- * There is currently only one supported host, "x86 standard"
-- * MAX_STACK is no longer required for decoding RK register indices,
--   instead, the MSB bit in the field is used as a flag (Lua 5.1)
-- * number_type is also used to lookup conversion function, etc.
--]]
--

CONFIGURATION = {
    ["x86 standard"] = {
        description = "x86 standard (32-bit, little endian, doubles)",
        endianness = 1,             -- 1 = little endian
        size_int = 4,               -- (data type sizes in bytes)
        size_size_t = 4,
        size_Instruction = 4,
        size_lua_Number = 8,        -- this & integral identifies the
        integral = 0,               -- type of lua_Number
        number_type = "double",     -- used for lookups
    },
    ["x86_64"] = {
        description = "x86_64 (64-bit, little endian, doubles)",
        endianness = 1,             -- 1 = little endian
        size_int = 4,               -- (data type sizes in bytes)
        size_size_t = 8,
        size_Instruction = 4,
        size_lua_Number = 8,        -- this & integral identifies the
        integral = 0,               -- type of lua_Number
        number_type = "double",     -- used for lookups
    },
    ["big endian int"] = {
        description = "(32-bit, big endian, ints)",
        endianness = 0,
        size_int = 4,
        size_size_t = 4,
        size_Instruction = 4,
        size_lua_Number = 4,
        integral = 1,
        number_type = "int",
    },
    -- you can add more platforms here
}

--
-- chunk constants
-- * changed in 5.1: VERSION, FPF, SIZE_* are now fixed; LUA_TBOOLEAN
--   added for constant table; TEST_NUMBER removed; FORMAT added
--
config.SIGNATURE    = "\27Lua"
-- TEST_NUMBER no longer needed, using size_lua_Number + integral
config.LUA_TNIL     = 0
config.LUA_TBOOLEAN = 1
config.LUA_TNUMBER  = 3
config.LUA_TSTRING  = 4
config.VERSION      = 81 -- 0x51
config.FORMAT       = 0  -- LUAC_FORMAT (new in 5.1)
config.FPF          = 50 -- LFIELDS_PER_FLUSH
config.SIZE_OP      = 6  -- instruction field bits
config.SIZE_A       = 8
config.SIZE_B       = 9
config.SIZE_C       = 9
-- MAX_STACK no longer needed for instruction decoding, removed
-- LUA_FIRSTINDEX currently not supported; used in SETLIST
config.LUA_FIRSTINDEX = 1

--
-- display options: you can set your defaults here
--
config.DISPLAY_FLAG       = true         -- global listing output on/off
config.DISPLAY_BRIEF      = nil          -- brief listing style
config.DISPLAY_INDENT     = nil          -- indent flag for brief style
config.STATS              = nil          -- set if always display stats
config.DISPLAY_OFFSET_HEX = true         -- use hexadecimal for position
config.DISPLAY_SEP        = "  "         -- column separator
config.DISPLAY_COMMENT    = "; "         -- comment sign
config.DISPLAY_HEX_DATA   = true         -- show hex data column
config.WIDTH_HEX          = 8            -- width of hex data column
config.WIDTH_OFFSET       = nil          -- width of position column
config.DISPLAY_LOWERCASE  = true         -- lower-case operands
config.WIDTH_OPCODE       = nil          -- width of opcode field
config.VERBOSE_TEST       = false        -- more verbosity for --test

--
-- Detected run time configs
--
config.version            = "5.1"

--
-- primitive platform auto-detection
--
function init_scope_config_description()
    if config.AUTO_DETECT then
        config.description = nil
        for _, cfg in pairs(CONFIGURATION) do
            if cfg.endianness == config.endianness and
            cfg.size_int == config.size_int and
            cfg.size_size_t == config.size_size_t and
            cfg.size_Instruction == config.size_Instruction and
            cfg.size_lua_Number == config.size_lua_Number and
            cfg.integral == config.integral and
            cfg.number_type == config.number_type then
                config.description = cfg.description
            end
        end
        if not config.description then
            config.description = "chunk platform unrecognized"
        end
        -- some parameters are not in the global header, e.g. FPF
        -- see the config table for more on these constants
    end
end

function init_print_width(size)
    if not config.WIDTH_OFFSET then config.WIDTH_OFFSET = 0 end
    if config.DISPLAY_OFFSET_HEX then
        local w = string.len(string.format("%X", size))
        if w > config.WIDTH_OFFSET then config.WIDTH_OFFSET = w end
        if (config.WIDTH_OFFSET % 2) == 1 then
            config.WIDTH_OFFSET = config.WIDTH_OFFSET + 1
        end
    else
        config.WIDTH_OFFSET = string.len(tonumber(size))
    end
end

function init_display_config()
    if config.WIDTH_OFFSET < 4 then config.WIDTH_OFFSET = 4 end
    if not config.DISPLAY_SEP then config.DISPLAY_SEP = "  " end
    if config.DISPLAY_HEX_DATA == nil then config.DISPLAY_HEX_DATA = true end
    if not config.WIDTH_HEX then config.WIDTH_HEX = 8 end
    config.BLANKS_HEX_DATA = string.rep(" ", config.WIDTH_HEX * 2 + 1)
end

function SetProfile(profile)
    if profile == "local" then
        -- arrives here only for --rewrite and --run option
        local flag1, flag2 = config.DISPLAY_FLAG, config.AUTO_DETECT
        config.DISPLAY_FLAG, config.AUTO_DETECT = false, true
        local LUA_SAMPLE = string.dump(function() end)
        config.DISPLAY_FLAG, config.AUTO_DETECT = flag1, flag2
        -- resume normal operation
    else
        local c = CONFIGURATION[profile]
        if not c then return false end
        for i, v in pairs(c) do config[i] = v end
    end
    return true
end

function get_config()
    return config
end

function GetTypeNIL()
    return config.LUA_TNIL
end

function GetTypeBoolean()
    return config.LUA_TBOOLEAN
end

function GetTypeNumber()
    return config.LUA_TNUMBER
end

function GetTypeString()
    return config.LUA_TSTRING
end

function GetOutputSep()
    return config.DISPLAY_SEP
end

function GetOutputShowHexData()
    return config.DISPLAY_HEX_DATA
end

function GetOutputBlankHex()
    return config.BLANKS_HEX_DATA
end

function GetOutputHexWidth()
    return config.WIDTH_HEX
end

function GetOutputPosWidth()
    return config.WIDTH_OFFSET
end

function GetOutputComment()
    return config.DISPLAY_COMMENT
end

function GetOutputPosString(i)
    if config.DISPLAY_OFFSET_HEX then
        return string.format("%X", i - 1)
    else
        return tonumber(i - 1)
    end
end

function GetLuaDescription()
    return config.description
end

function GetLuaIntSize()
    return config.size_int
end

function GetLuaSizetSize()
    return config.size_size_t
end

function GetLuaNumberSize()
    return config.size_lua_Number
end

function GetLuaInstructionSize()
    return config.size_Instruction
end

function GetLuaNumberType()
    return config.number_type
end

function GetLuaRuntimeVersion()
    return config.version
end

function SetLuaRuntimeVersion(ver)
    config.version = ver
end

function SetLuaNumberType(t)
    config.number_type = t
end

function GetLuaEndianness()
    return config.endianness
end

function SetLuaEndianness(e)
    config.endianness = e
end

function GetLuaIntegral()
    return config.integral
end

function SetLuaIntegral(b)
    config.integral = b
end

function ShouldIPrintStats()
    return config.STATS and not config.DISPLAY_BRIEF
end

-- TODO : combine next 4 functions
function ShouldIPrintLess()
    return not config.DISPLAY_FLAG or config.DISPLAY_BRIEF
end

function ShouldIPrintBrief()
    return config.DISPLAY_BRIEF
end

function ShouldIPrintXYZ()
    return not config.DISPLAY_FLAG or not config.DISPLAY_BRIEF
end

function ShouldIPrintParts()
    return config.DISPLAY_FLAG and config.DISPLAY_BRIEF
end

function ShouldIPrintHexData()
    return config.DISPLAY_HEX_DATA
end

function ShouldIPrintLowercase()
    return config.DISPLAY_LOWERCASE
end

Oconfig = {
    SetVersion       =  function (self, v)
                            SetLuaRuntimeVersion(v)
                        end,
    GetVersion       =  function (self)
                            return 0x53 /* TODO fix */
                        end,
    GetVersionString =  function (self)
                            return config.version
                        end,
    GetSign          =  function (self)
                            return config.SIGNATURE
                        end
}

