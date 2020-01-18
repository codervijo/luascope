#!/usr/bin/lua

--[[
    Decode Instructions for Lua Scope
    A Lua 5.1 binary chunk disassembler
    LuaScope was inspired by Jein-Hong Man's ChunkSpy
--]]


package.path = package.path .. ";./?.lua;/usr/src/?.lua"

require("scope_config")

-- XXX is a hack, only temporary, hopefully.
config = get_config()
l51vm = {}

--[[-------------------------------------------------------------------
-- Instruction decoder functions (changed in Lua 5.1)
-- * some fixed decode data is placed in the config table
-- * these function are quite flexible, they can accept non-standard
--   instruction field sizes as long as the arrangement is the same.
-----------------------------------------------------------------------
  Visually, an instruction can be represented as one of:

   31      |     |     |         0  bit position
    +-----+-----+-----+----------+
    |  B  |  C  |  A  |  Opcode  |  iABC format
    +-----+-----+-----+----------+
    -  9  -  9  -  8  -    6     -  field sizes (standard Lua)
    +-----+-----+-----+----------+
    |   [s]Bx   |  A  |  Opcode  |  iABx | iAsBx format
    +-----+-----+-----+----------+

  The signed argument sBx is represented in excess K, with the range
  of -max to +max represented by 0 to 2*max.

  For RK(x) constants, MSB is set and constant number is in the rest
  of the bits.

--]]-------------------------------------------------------------------

-----------------------------------------------------------------------
-- instruction decoder initialization
-----------------------------------------------------------------------
function DecodeInit(oconfig)
	local sizea   = oconfig:GetLuaSize_A()
	local sizeb   = oconfig:GetLuaSize_B()
	local sizec   = oconfig:GetLuaSize_C()
	local sizeop  = oconfig:GetLuaSize_OP()

	---------------------------------------------------------------
	-- calculate masks
	---------------------------------------------------------------
	l51vm.SIZE_Bx = sizeb + sizec
	local MASK_OP = math.ldexp(1, sizeop)
	local MASK_A  = math.ldexp(1, sizea)
	local MASK_B  = math.ldexp(1, sizeb)
	local MASK_C  = math.ldexp(1, sizec)
	local MASK_Bx = math.ldexp(1, l51vm.SIZE_Bx)
	l51vm.MAXARG_sBx = math.floor((MASK_Bx - 1) / 2)
	l51vm.BITRK = math.ldexp(1, sizeb - 1)

	---------------------------------------------------------------
	-- iABC instruction segment tables
	---------------------------------------------------------------
	l51vm.iABC = {       -- tables allows field sequence to be extracted
		sizeop,     -- using a loop; least significant field first
		sizea,      -- additional lookups below, kludgy
		sizec,
		sizeb,
	}
	l51vm.mABC = { MASK_OP, MASK_A, MASK_C, MASK_B, }
	l51vm.nABC = { "OP", "A", "C", "B", }

	---------------------------------------------------------------
	-- Lua VM opcode name table (5.1)
	---------------------------------------------------------------
	local opcodes =
		"MOVE LOADK LOADBOOL LOADNIL GETUPVAL \
		GETGLOBAL GETTABLE SETGLOBAL SETUPVAL SETTABLE \
		NEWTABLE SELF ADD SUB MUL \
		DIV MOD POW UNM NOT \
		LEN CONCAT JMP EQ LT \
		LE TEST TESTSET CALL TAILCALL RETURN \
		FORLOOP FORPREP TFORLOOP SETLIST \
		CLOSE CLOSURE VARARG"

	---------------------------------------------------------------
	-- build opcode name table
	---------------------------------------------------------------
	l51vm.opnames = {}
	l51vm.NUM_OPCODES = 0
	if not l51vm.WIDTH_OPCODE then l51vm.WIDTH_OPCODE = 0 end
	for v in string.gmatch(opcodes, "[^%s]+") do
		if ShouldIPrintLowercase() then v = string.lower(v) end
		l51vm.opnames[l51vm.NUM_OPCODES] = v
		local vlen = string.len(v)
		-- find maximum opcode length
		if vlen > l51vm.WIDTH_OPCODE then
			l51vm.WIDTH_OPCODE = vlen
		end
		l51vm.NUM_OPCODES = l51vm.NUM_OPCODES + 1
	end
	-- opmode: 0=ABC, 1=ABx, 2=AsBx
	l51vm.opmode = "01000101000000000000002000000002200010"

	---------------------------------------------------------------
	-- initialize text widths and formats for display
	---------------------------------------------------------------
	l51vm.WIDTH_A = WidthOf(MASK_A)
	l51vm.WIDTH_B = WidthOf(MASK_B)
	l51vm.WIDTH_C = WidthOf(MASK_C)
	l51vm.WIDTH_Bx = WidthOf(MASK_Bx) + 1 -- with minus sign
	l51vm.FORMAT_A = string.format("%%-%dd", l51vm.WIDTH_A)
	l51vm.FORMAT_B = string.format("%%-%dd", l51vm.WIDTH_B)
	l51vm.FORMAT_C = string.format("%%-%dd", l51vm.WIDTH_C)
	l51vm.PAD_Bx = l51vm.WIDTH_A + l51vm.WIDTH_B + l51vm.WIDTH_C + 2
	          - l51vm.WIDTH_Bx
	if l51vm.PAD_Bx > 0 then
		l51vm.PAD_Bx = string.rep(" ", l51vm.PAD_Bx)
	else
		l51vm.PAD_Bx = ""
	end
	l51vm.FORMAT_Bx  = string.format("%%-%dd", l51vm.WIDTH_Bx)
	l51vm.FORMAT_AB  = string.format("%s %s %s", l51vm.FORMAT_A, l51vm.FORMAT_B, string.rep(" ", l51vm.WIDTH_C))
	l51vm.FORMAT_ABC = string.format("%s %s %s", l51vm.FORMAT_A, l51vm.FORMAT_B, l51vm.FORMAT_C)
	l51vm.FORMAT_AC  = string.format("%s %s %s", l51vm.FORMAT_A, string.rep(" ", l51vm.WIDTH_B), l51vm.FORMAT_C)
	l51vm.FORMAT_ABx = string.format("%s %s", l51vm.FORMAT_A, l51vm.FORMAT_Bx)
end

-----------------------------------------------------------------------
-- instruction decoder
-- * decoder loops starting from the least-significant byte, this allow
--   a field to be extracted using % operations
-- * returns a table populated with the appropriate fields
-- * WARNING B,C arrangement is hard-coded here for calculating [s]Bx
-----------------------------------------------------------------------
function DecodeInst(code, iValues)
	local iSeq, iMask = l51vm.iABC, l51vm.mABC
	local cValue, cBits, cPos = 0, 0, 1
	-- decode an instruction
	for i = 1, #iSeq do
		-- if need more bits, suck in a byte at a time
		while cBits < iSeq[i] do
			cValue = string.byte(code, cPos) * math.ldexp(1, cBits) + cValue
			cPos = cPos + 1; cBits = cBits + 8
		end
		-- extract and set an instruction field
		iValues[l51vm.nABC[i]] = cValue % iMask[i]
		cValue = math.floor(cValue / iMask[i])
		cBits = cBits - iSeq[i]
	end
	iValues.opname = l51vm.opnames[iValues.OP]   -- get mnemonic
	iValues.opmode = string.sub(l51vm.opmode, iValues.OP + 1, iValues.OP + 1)
	if iValues.opmode == "1" then                 -- set Bx or sBx
		iValues.Bx = iValues.B * iMask[3] + iValues.C
	elseif iValues.opmode == "2" then
		iValues.sBx = iValues.B * iMask[3] + iValues.C - l51vm.MAXARG_sBx
	end
	return iValues
end

-----------------------------------------------------------------------
-- describe an instruction
-- * make instructions descriptions more verbose and readable
-----------------------------------------------------------------------
function DescribeInst(inst, pos, func, oconfig)
	local Operand
	local Comment = ""

	---------------------------------------------------------------
	-- operand formatting helpers
	---------------------------------------------------------------
	local function OperandAB(i)   return string.format(l51vm.FORMAT_AB, i.A, i.B) end
	local function OperandABC(i)  return string.format(l51vm.FORMAT_ABC, i.A, i.B, i.C) end
	local function OperandAC(i)   return string.format(l51vm.FORMAT_AC, i.A, i.C) end
	local function OperandABx(i)  return string.format(l51vm.FORMAT_ABx, i.A, i.Bx) end
	local function OperandAsBx(i) return string.format(l51vm.FORMAT_ABx, i.A, i.sBx) end

	---------------------------------------------------------------
	-- comment formatting helpers
	-- calculate jump location, conditional flag
	---------------------------------------------------------------
	local function CommentLoc(sBx, cond)
		local loc = string.format("to [%d]", pos + 1 + sBx)
		if cond then loc = loc..cond end
		return loc
	end

	---------------------------------------------------------------
	-- Kst(x) - constant (in constant table)
	---------------------------------------------------------------
	local function CommentK(index, quoted)
		local c = func.k[index + 1]
		if type(c) == "string" then
			return EscapeString(c, quoted)
		elseif type(c) == "number" or type(c) == "boolean" then
			return tostring(c)
		else
			return "nil"
		end
	end

	---------------------------------------------------------------
	-- RK(x) == if BITRK then Kst(x&~BITRK) else R(x)
	---------------------------------------------------------------
	local function CommentRK(index, quoted)
		if index >= l51vm.BITRK then
			return CommentK(index - l51vm.BITRK, quoted)
		else
			return ""
		end
	end

	---------------------------------------------------------------
	-- comments for RK(B), RK(C)
	---------------------------------------------------------------
	local function CommentBC(inst)
		local B, C = CommentRK(inst.B, true), CommentRK(inst.C, true)
		if B == "" then
			if C == "" then return "" else return C end
			elseif C == "" then
			return B
		else
			return B.." "..C
		end
	end

	---------------------------------------------------------------
	-- floating point byte conversion
	-- bit positions: mmmmmxxx, actual: (1xxx) * 2^(m-1)
	---------------------------------------------------------------
	local function fb2int(x)
		local e = math.floor(x / 8) % 32
		if e == 0 then return x end
		return math.ldexp((x % 8) + 8, e - 1)
	end

	---------------------------------------------------------------
	-- yeah, I know this is monstrous...
	-- * see the descriptions in lopcodes.h for more information
	----
	if inst.prev then -- continuation of SETLIST
		Operand = string.format(l51vm.FORMAT_Bx, func.code[pos])
	--
	elseif inst.OP ==  0 then -- MOVE A B
		Operand = OperandAB(inst)
	--
	elseif inst.OP ==  1 then -- LOADK A Bx
		Operand = OperandABx(inst)
		Comment = CommentK(inst.Bx, true)
	--
	elseif inst.OP ==  2 then -- LOADBOOL A B C
		Operand = OperandABC(inst)
		if inst.B == 0 then Comment = "false" else Comment = "true" end
		if inst.C > 0 then Comment = Comment..", "..CommentLoc(1) end
	--
	elseif inst.OP ==  3 then -- LOADNIL A B
		Operand = OperandAB(inst)
	--
	elseif inst.OP ==  4 then -- GETUPVAL A B
		Operand = OperandAB(inst)
		Comment = func.upvalues[inst.B + 1]
	--
	elseif inst.OP ==  5 or   -- GETGLOBAL A Bx
		   inst.OP ==  7 then -- SETGLOBAL A Bx
		Operand = OperandABx(inst)
		Comment = CommentK(inst.Bx)
	--
	elseif inst.OP ==  6 then -- GETTABLE A B C
		Operand = OperandABC(inst)
		Comment = CommentRK(inst.C, true)
	--
	elseif inst.OP ==  8 then -- SETUPVAL A B
		Operand = OperandAB(inst)
		Comment = func.upvalues[inst.B + 1]
	--
	elseif inst.OP ==  9 then -- SETTABLE A B C
		Operand = OperandABC(inst)
		Comment = CommentBC(inst)
	--
	elseif inst.OP == 10 then -- NEWTABLE A B C
		Operand = OperandABC(inst)
		local ar = fb2int(inst.B)  -- array size
		local hs = fb2int(inst.C)  -- hash size
		Comment = "array="..ar..", hash="..hs
	--
	elseif inst.OP == 11 then -- SELF A B C
		Operand = OperandABC(inst)
		Comment = CommentRK(inst.C, true)
	--
	elseif inst.OP == 12 or   -- ADD A B C
		   inst.OP == 13 or   -- SUB A B C
		   inst.OP == 14 or   -- MUL A B C
		   inst.OP == 15 or   -- DIV A B C
		   inst.OP == 16 or   -- MOD A B C
		   inst.OP == 17 then -- POW A B C
		Operand = OperandABC(inst)
		Comment = CommentBC(inst)
	--
	elseif inst.OP == 18 or   -- UNM A B
		   inst.OP == 19 or   -- NOT A B
		   inst.OP == 20 then -- LEN A B
		Operand = OperandAB(inst)
	--
	elseif inst.OP == 21 then -- CONCAT A B C
		Operand = OperandABC(inst)
	--
	elseif inst.OP == 22 then -- JMP sBx
		Operand = string.format(l51vm.FORMAT_Bx, inst.sBx)
		Comment = CommentLoc(inst.sBx)
	--
	elseif inst.OP == 23 or   -- EQ A B C
		   inst.OP == 24 or   -- LT A B C
		   inst.OP == 25 or   -- LE A B C
		   inst.OP == 27 then -- TESTSET A B C
		Operand = OperandABC(inst)
		if inst.OP ~= 27 then Comment = CommentBC(inst) end
		if Comment ~= "" then Comment = Comment..", " end
		-- since the pc++ is in the 'else' path, the sense is opposite
		local sense = " if false"
		if inst.OP == 27 then
			if inst.C == 0 then sense = " if true" end
		else
			if inst.A == 0 then sense = " if true" end
		end
		Comment = Comment..CommentLoc(1, sense)
	elseif inst.OP == 26 then -- TEST A C
		Operand = OperandAC(inst)
		local sense = " if false"
		if inst.C == 0 then sense = " if true" end
		Comment = Comment..CommentLoc(1, sense)
	--
	elseif inst.OP == 28 or   -- CALL A B C
		   inst.OP == 29 then -- TAILCALL A B C
		Operand = OperandABC(inst)
	--
	elseif inst.OP == 30 then -- RETURN A B
		Operand = OperandAB(inst)
	--
	elseif inst.OP == 31 then -- FORLOOP A sBx
		Operand = OperandAsBx(inst)
		Comment = CommentLoc(inst.sBx, " if loop")
	--
	elseif inst.OP == 32 then -- FORPREP A sBx
		Operand = OperandAsBx(inst)
		Comment = CommentLoc(inst.sBx)
	--
	elseif inst.OP == 33 then -- TFORLOOP A C
		Operand = OperandAC(inst)
		Comment = CommentLoc(1, " if exit")
	--
	elseif inst.OP == 34 then -- SETLIST A B C
		Operand = OperandABC(inst)
		-- R(A)[(C-1)*FPF+i] := R(A+i), 1 <= i <= B
		local n = inst.B
		local c = inst.C
		if c == 0 then
			-- grab next inst when index position is large
			c = func.code[pos + 1]
			func.inst[pos + 1].prev = true
		end
		local start = (c - 1) * oconfig:GetLuaFPF() + 1
		local last = start + n - 1
		Comment = "index "..start.." to "
		if n ~= 0 then
			Comment = Comment..last
		else
			Comment = Comment.."top"
		end
	--
	elseif inst.OP == 35 then -- CLOSE A
		Operand = string.format(l51vm.FORMAT_A, inst.A)
	--
	elseif inst.OP == 36 then -- CLOSURE A Bx
		Operand = OperandABx(inst)
		-- lets user know how many following instructions are significant
		Comment = func.p[inst.Bx + 1].nups.." upvalues"
	--
	elseif inst.OP == 37 then -- VARARG A B
		Operand = OperandAB(inst)
	--
	else
		-- add your VM extensions here
		Operand = string.format("OP %d", inst.OP)
	end

	--
	-- compose operands and comments
	--
	if Comment and Comment ~= "" then
		Operand = Operand..GetOutputSep()
				  ..GetOutputComment()..Comment
	end
	return LeftJustify(inst.opname, l51vm.WIDTH_OPCODE)
			..GetOutputSep()..Operand
end
