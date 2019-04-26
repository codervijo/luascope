#!/usr/bin/lua

--[[
    Output for Lua Scope
    Display / Output handler
    A Lua 5.1 binary chunk disassembler
    LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]

package.path = package.path .. ";./?.lua;/usr/src/?.lua"

require("scope_config")

outfile = {}

--[[
-- Display support functions
-- * considerable work is done to maintain nice alignments
-- * some widths are initialized at chunk start
-- * this is meant to make output customization easy
--]]

--
-- width of number, left justify, zero padding
--
function WidthOf(n)            return string.len(tostring(n)) end
function LeftJustify(s, width) return s..string.rep(" ", width - string.len(s)) end
function ZeroPad(s, width)     return string.rep("0", width - string.len(s))..s end

--
-- initialize display formatting settings
-- * chunk_size parameter used to set width of position column
--
function DisplayInit(chunk_size)
	--
	-- set up printing widths
	--
	init_print_width(chunk_size)

	--
	-- sane defaults
	--
	init_display_config()

	-- default output path
	if not WriteLine then WriteLine = print end
end

--
-- initialize listing output path (an optional redirect)
-- * this is done before calling Dechunk to redirect output
--
function OutputInit()
	if outfile.OUTPUT_FILE then
		if type(outfile.OUTPUT_FILE) == "string" then
			local INF = io.open(outfile.OUTPUT_FILE, "wb")
			if not INF then
				error("cannot open \""..outfile.OUTPUT_FILE.."\" for writing")
			end
			outfile.OUTPUT_FILE = INF
			WriteLine = PrintToFile
		end
	end
end

function PrintToFile(msg)
    outfile.OUTPUT_FILE:write(msg, "\n")
end

function CloseOutput()
    io.close(outfile.OUTPUT_FILE)
end

--
-- cleanup listing output path
--
function OutputExit()
	if WriteLine and WriteLine ~= print then CloseOutput() end
end

--
-- escape control bytes in strings
--
function EscapeString(s, quoted)
	local v = ""
	for i = 1, string.len(s) do
	local c = string.byte(s, i)
	-- other escapees with values > 31 are "(34), \(92)
	if c < 32 or c == 34 or c == 92 then
		if c >= 7 and c <= 13 then
			c = string.sub("abtnvfr", c - 6, c - 6)
		elseif c == 34 or c == 92 then
				c = string.char(c)
			end
			v = v.."\\"..c
		else-- 32 <= v <= 255
			v = v..string.char(c)
		end
	end
	if quoted then return string.format("\"%s\"", v) end
	return v
end

--
-- listing legend/header
--
function HeaderLine()
	if ShouldIPrintLess() then return end
	WriteLine(LeftJustify("Pos", GetOutputPosWidth())..GetOutputSep()
	          ..LeftJustify("Hex Data", GetOutputPosWidth() * 2 + 1)..GetOutputSep()
	          .."Description or Code\n"
	          ..string.rep("-", 72))
end

--
-- description-only line, no position or hex data
--
function DescLine(desc)
	if ShouldIPrintLess() then return end
	WriteLine(string.rep(" ", GetOutputPosWidth())..GetOutputSep()..GetOutputBlankHex()..GetOutputSep()
	          ..desc)
end

--
-- optionally display a pre-formatted statistic
--
function DisplayStat(stat)
	if ShouldIPrintStats() then DescLine(stat) end
end

--
-- returns position, i uses string index (starts from 1)
--
function FormatPos(i)
	local pos = GetOutputPosString(i)
	return ZeroPad(pos, GetOutputPosWidth())
end

--
-- display a position, hex data, description line
--
function FormatLine(chunk, size, desc, index, segment)
	if ShouldIPrintLess() then return end
	if ShouldIPrintHexData() then
		-- nicely formats binary chunk data in multiline hexadecimal
		if size == 0 then
			WriteLine(FormatPos(index)..GetOutputSep()..GetOutputBlankHex()..GetOutputSep()
						..desc)
		else
			-- split hex data into config.WIDTH_HEX byte strings
			while size > 0 do
				local d, dlen = "", size
				if size > GetOutputHexWidth() then dlen = GetOutputHexWidth() end
				-- build hex data digits
				for i = 0, dlen - 1 do
					d = d..string.format("%02X", string.byte(chunk, index + i))
				end
				-- add padding or continuation indicator
				d = d..string.rep("  ", GetOutputHexWidth() - dlen)
				if segment or size > GetOutputHexWidth() then
					d = d.."+"; size = size - GetOutputHexWidth()
				else
					d = d.." "; size = 0
				end
				-- description only on first line of a multiline
				if desc then
					WriteLine(FormatPos(index)..GetOutputSep()
								..d..GetOutputSep()
								..desc)
					desc = nil
				else
					WriteLine(FormatPos(index)..GetOutputSep()..d)
				end
				index = index + dlen
			end--while
		end--if size
	else--no hex data mode
		WriteLine(FormatPos(index)..GetOutputSep()..desc)
	end
	-- end of FormatLine
end

function OutputHeader(size, name, chunk, idx)
	DisplayInit(size)
	HeaderLine()                  -- listing display starts here
	if name then
		FormatLine(chunk, 0, "** source chunk: "..name, idx)
		if ShouldIPrintBrief() then
			WriteLine(GetOutputComment().."source chunk: "..name)
		end
	end
	DescLine("** global header start **")
end