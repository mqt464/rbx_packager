-- Bitwise helpers
local bit = bit32
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

-- Magic tags
local MAGIC_AUTO = "PKA" -- 3 bytes
local MAGIC_SCHEMA = "PKS"
local VERSION: number = 1

-- Options
export type Options = {
	profile: string?, -- "realtime" | "datastore" | "lossless"
	maxArray: number?,
	maxStringBytes: number?,
	maxDepth: number?,
	failOnQuantClamp: boolean?,
}

local DEFAULTS: Options = {
	profile = "realtime",
	maxArray = 200000,
	maxStringBytes = 1000000,
	maxDepth = 64,
	failOnQuantClamp = false,
}

local function mergeOptions(base: Options, override: Options?): Options
	local out: Options = table.clone(base)
	if override then
		for k, v in pairs(override) do
			(out :: any)[k] = v
		end
	end
	return out
end

local runtimeOpts: Options = table.clone(DEFAULTS) -- init() optional; safe defaults

-- Quantization bounds
local POS_MIN = Vector3.new(-2048, -256, -2048)
local POS_MAX = Vector3.new( 2048,  512,  2048)
local ROT_MIN = Vector3.new(-math.pi, -math.pi, -math.pi)
local ROT_MAX = Vector3.new( math.pi,  math.pi,  math.pi)

-- Auto type tags
local TAG = {
	NIL = 0,
	BOOL = 1,
	SINT = 2,  -- zigzag varint
	FLOAT = 3, -- f32
	STRING = 4,
	VECTOR3 = 5,
	VECTOR2 = 6,
	CFRAME = 7,
	ARRAY = 8,
	MAP = 9,
	COLOR3 = 10,
	UDIM2 = 11,
	DATETIME = 12,
}

-- ByteBuilder
export type ByteBuilderT = {
	chunks: {string},
	putByte: (self: ByteBuilderT, b: number) -> (),
	putBytes: (self: ByteBuilderT, s: string) -> (),
	putU16LE: (self: ByteBuilderT, n: number) -> (),
	putF32LE: (self: ByteBuilderT, x: number) -> (),
	putVarUint: (self: ByteBuilderT, u: number) -> (),
	putVarInt: (self: ByteBuilderT, i: number) -> (),
	toBuffer: (self: ByteBuilderT) -> buffer,
}
local ByteBuilder = {} :: any
ByteBuilder.__index = ByteBuilder

function ByteBuilder.new(): ByteBuilderT
	local self = setmetatable({}, ByteBuilder)
	self.chunks = {}
	return (self :: any) :: ByteBuilderT
end

function ByteBuilder:putByte(b: number)
	local v = math.clamp(math.floor(b), 0, 255)
	self.chunks[#self.chunks+1] = string.char(v)
end

function ByteBuilder:putBytes(s: string)
	self.chunks[#self.chunks+1] = s
end

function ByteBuilder:putU16LE(n: number)
	n = math.floor(n) % 65536
	local lo = n % 256
	local hi = math.floor(n / 256) % 256
	self.chunks[#self.chunks+1] = string.char(lo, hi)
end

function ByteBuilder:putF32LE(x: number)
	local tmp = buffer.create(4)
	buffer.writef32(tmp, 0, x)
	self.chunks[#self.chunks+1] = buffer.tostring(tmp)
end

local function zigzagEncode(i: number): number
	i = math.floor(i)
	return bxor(lshift(i, 1), rshift(i, 31))
end

local function zigzagDecode(u: number): number
	local sign = band(u, 1)
	return bxor(rshift(u, 1), -sign)
end

function ByteBuilder:putVarUint(u: number)
	u = math.floor(u)
	while u >= 128 do
		self:putByte(bor(band(u, 127), 128))
		u = math.floor(u / 128)
	end
	self:putByte(u)
end

function ByteBuilder:putVarInt(i: number)
	self:putVarUint(zigzagEncode(i))
end

function ByteBuilder:toBuffer(): buffer
	return buffer.fromstring(table.concat(self.chunks))
end

-- ByteReader
export type ByteReaderT = {
	s: string,
	i: number,
	readByte: (self: ByteReaderT) -> number,
	readBytes: (self: ByteReaderT, n: number) -> string,
	readU16LE: (self: ByteReaderT) -> number,
	readF32LE: (self: ByteReaderT) -> number,
	readVarUint: (self: ByteReaderT) -> number,
	readVarInt: (self: ByteReaderT) -> number,
}
local ByteReader = {} :: any
ByteReader.__index = ByteReader

function ByteReader.new(buf: buffer): ByteReaderT
	local self = setmetatable({}, ByteReader)
	self.s = buffer.tostring(buf)
	self.i = 1
	return (self :: any) :: ByteReaderT
end

function ByteReader:readByte(): number
	local b: number? = string.byte(self.s, self.i)
	if b == nil then error("readByte: out of bounds at index "..tostring(self.i)) end
	self.i = self.i + 1
	return b
end

function ByteReader:readBytes(n: number): string
	local j = self.i + n - 1
	if j > #self.s then error("readBytes: out of bounds") end
	local out = string.sub(self.s, self.i, j)
	self.i = j + 1
	return out
end

function ByteReader:readU16LE(): number
	local a: number? = string.byte(self.s, self.i); self.i = self.i + 1
	local b: number? = string.byte(self.s, self.i); self.i = self.i + 1
	if a == nil or b == nil then error("readU16LE: out of bounds") end
	return a + b*256
end

function ByteReader:readF32LE(): number
	local bytes = self:readBytes(4)
	local tmp = buffer.fromstring(bytes)
	return buffer.readf32(tmp, 0)
end

function ByteReader:readVarUint(): number
	local shift = 0
	local result = 0
	while true do
		local b = self:readByte()
		result = result + lshift(band(b, 127), shift)
		if band(b, 128) == 0 then break end
		shift = shift + 7
	end
	return result
end

function ByteReader:readVarInt(): number
	return zigzagDecode(self:readVarUint())
end

-- Helpers
local function isArray(t: any): boolean
	if typeof(t) ~= "table" then return false end
	local n = #t
	for k, _ in pairs(t) do
		if typeof(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > n then
			return false
		end
	end
	return true
end

local function q16(v: number, minV: number, maxV: number, opts: Options): number
	if v < minV or v > maxV then
		if opts.failOnQuantClamp then
			error(string.format("quant clamp: %.3f not in [%.3f, %.3f]", v, minV, maxV))
		end
		v = math.clamp(v, minV, maxV)
	end
	local norm = (v - minV) / (maxV - minV)
	return math.floor(norm * 65535 + 0.5)
end

local function uq16(q: number, minV: number, maxV: number): number
	local norm = q / 65535
	return minV + norm * (maxV - minV)
end

local function packVector3(bb: ByteBuilderT, v: Vector3, opts: Options)
	bb:putU16LE(q16(v.X, POS_MIN.X, POS_MAX.X, opts))
	bb:putU16LE(q16(v.Y, POS_MIN.Y, POS_MAX.Y, opts))
	bb:putU16LE(q16(v.Z, POS_MIN.Z, POS_MAX.Z, opts))
end

local function unpackVector3(br: ByteReaderT): Vector3
	local x = uq16(br:readU16LE(), POS_MIN.X, POS_MAX.X)
	local y = uq16(br:readU16LE(), POS_MIN.Y, POS_MAX.Y)
	local z = uq16(br:readU16LE(), POS_MIN.Z, POS_MAX.Z)
	return Vector3.new(x, y, z)
end

local function packVector2(bb: ByteBuilderT, v: Vector2, opts: Options)
	bb:putU16LE(q16(v.X, POS_MIN.X, POS_MAX.X, opts))
	bb:putU16LE(q16(v.Y, POS_MIN.Y, POS_MAX.Y, opts))
end

local function unpackVector2(br: ByteReaderT): Vector2
	local x = uq16(br:readU16LE(), POS_MIN.X, POS_MAX.X)
	local y = uq16(br:readU16LE(), POS_MIN.Y, POS_MAX.Y)
	return Vector2.new(x, y)
end

local function packCFrame(bb: ByteBuilderT, cf: CFrame, opts: Options)
	local pos = cf.Position
	packVector3(bb, pos, opts)
	local rx, ry, rz = cf:ToOrientation()
	bb:putU16LE(q16(rx, ROT_MIN.X, ROT_MAX.X, opts))
	bb:putU16LE(q16(ry, ROT_MIN.Y, ROT_MAX.Y, opts))
	bb:putU16LE(q16(rz, ROT_MIN.Z, ROT_MAX.Z, opts))
end

local function unpackCFrame(br: ByteReaderT): CFrame
	local pos = unpackVector3(br)
	local rx = uq16(br:readU16LE(), ROT_MIN.X, ROT_MAX.X)
	local ry = uq16(br:readU16LE(), ROT_MIN.Y, ROT_MAX.Y)
	local rz = uq16(br:readU16LE(), ROT_MIN.Z, ROT_MAX.Z)
	return CFrame.new(pos) * CFrame.fromOrientation(rx, ry, rz)
end

local function packColor565(bb: ByteBuilderT, c: Color3)
	local r = math.floor(c.R * 31 + 0.5)
	local g = math.floor(c.G * 63 + 0.5)
	local b = math.floor(c.B * 31 + 0.5)
	local v = bor(lshift(r, 11), bor(lshift(g, 5), b))
	bb:putU16LE(v)
end

local function unpackColor565(br: ByteReaderT): Color3
	local v = br:readU16LE()
	local r5 = rshift(v, 11) % 32
	local g6 = rshift(v, 5) % 64
	local b5 = v % 32
	return Color3.new(r5/31, g6/63, b5/31)
end

local function packUDim(bb: ByteBuilderT, u: UDim)
	bb:putF32LE(u.Scale)
	bb:putF32LE(u.Offset)
end

local function unpackUDim(br: ByteReaderT): UDim
	local s = br:readF32LE()
	local o = br:readF32LE()
	return UDim.new(s, o)
end

local function packUDim2(bb: ByteBuilderT, u: UDim2)
	packUDim(bb, u.X)
	packUDim(bb, u.Y)
end

local function unpackUDim2(br: ByteReaderT): UDim2
	return UDim2.new(unpackUDim(br), unpackUDim(br))
end

local function packDateTime(bb: ByteBuilderT, dt: DateTime)
	-- seconds since epoch, integer varint (compact)
	bb:putVarUint(math.floor(dt.UnixTimestamp))
end

local function unpackDateTime(br: ByteReaderT): DateTime
	local ts = br:readVarUint()
	return DateTime.fromUnixTimestamp(ts)
end

-- Auto mode helpers
local function collectKeyStrings(t: any, acc: {[string]: boolean}, depth: number, opts: Options)
	if depth > (opts.maxDepth :: number) then error("maxDepth exceeded while collecting keys") end
	if typeof(t) ~= "table" then return end
	if isArray(t) then
		for i = 1, #t do
			collectKeyStrings(t[i], acc, depth + 1, opts)
		end
		return
	end
	for k, v in pairs(t) do
		acc[tostring(k)] = true
		collectKeyStrings(v, acc, depth + 1, opts)
	end
end

local function makeDict(keys: {[string]: boolean}): {string}
	local arr = {}
	for k, _ in pairs(keys) do arr[#arr+1] = k end
	table.sort(arr)
	return arr
end

local function buildKeyToId(dict: {string}): {[string]: number}
	local m: {[string]: number} = {}
	for i, s in ipairs(dict) do m[s] = i end
	return m
end

local function writeString(bb: ByteBuilderT, s: string, opts: Options)
	if #s > (opts.maxStringBytes :: number) then error("string too long") end
	bb:putVarUint(#s)
	bb:putBytes(s)
end

local function writeValueAuto(bb: ByteBuilderT, v: any, depth: number, opts: Options, keyToId: {[string]: number})
	if depth > (opts.maxDepth :: number) then error("maxDepth exceeded") end
	local t = typeof(v)
	if v == nil then
		bb:putByte(TAG.NIL)
	elseif t == "boolean" then
		bb:putByte(TAG.BOOL); bb:putByte(v and 1 or 0)
	elseif t == "number" then
		if v % 1 == 0 then
			bb:putByte(TAG.SINT); bb:putVarInt(v)
		else
			bb:putByte(TAG.FLOAT); bb:putF32LE(v)
		end
	elseif t == "string" then
		bb:putByte(TAG.STRING); writeString(bb, v, opts)
	elseif t == "Vector3" then
		bb:putByte(TAG.VECTOR3); packVector3(bb, v, opts)
	elseif t == "Vector2" then
		bb:putByte(TAG.VECTOR2); packVector2(bb, v, opts)
	elseif t == "CFrame" then
		bb:putByte(TAG.CFRAME); packCFrame(bb, v, opts)
	elseif t == "Color3" then
		bb:putByte(TAG.COLOR3); packColor565(bb, v)
	elseif t == "UDim2" then
		bb:putByte(TAG.UDIM2); packUDim2(bb, v)
	elseif t == "DateTime" then
		bb:putByte(TAG.DATETIME); packDateTime(bb, v)
	elseif t == "table" then
		if isArray(v) then
			local n = #v
			if n > (opts.maxArray :: number) then error("array too long") end
			bb:putByte(TAG.ARRAY); bb:putVarUint(n)
			for i = 1, n do writeValueAuto(bb, v[i], depth + 1, opts, keyToId) end
		else
			-- MAP
			local keys = {}
			for k, _ in pairs(v) do keys[#keys+1] = tostring(k) end
			table.sort(keys)
			local count = #keys
			if count > (opts.maxArray :: number) then error("object too large") end
			bb:putByte(TAG.MAP); bb:putVarUint(count)
			for _, sk in ipairs(keys) do
				local id = keyToId[sk]
				if not id then error("key not in dictionary: "..sk) end
				bb:putVarUint(id)
				writeValueAuto(bb, v[sk], depth + 1, opts, keyToId)
			end
		end
	else
		error("unsupported type: " .. t)
	end
end

local function readString(br: ByteReaderT, opts: Options): string
	local n = br:readVarUint()
	if n > (opts.maxStringBytes :: number) then error("string too long") end
	return br:readBytes(n)
end

local function readValueAuto(br: ByteReaderT, dict: {string}, depth: number, opts: Options): any
	if depth > (opts.maxDepth :: number) then error("maxDepth exceeded") end
	local tag = br:readByte()
	if tag == TAG.NIL then
		return nil
	elseif tag == TAG.BOOL then
		return br:readByte() ~= 0
	elseif tag == TAG.SINT then
		return br:readVarInt()
	elseif tag == TAG.FLOAT then
		return br:readF32LE()
	elseif tag == TAG.STRING then
		return readString(br, opts)
	elseif tag == TAG.VECTOR3 then
		return unpackVector3(br)
	elseif tag == TAG.VECTOR2 then
		return unpackVector2(br)
	elseif tag == TAG.CFRAME then
		return unpackCFrame(br)
	elseif tag == TAG.COLOR3 then
		return unpackColor565(br)
	elseif tag == TAG.UDIM2 then
		return unpackUDim2(br)
	elseif tag == TAG.DATETIME then
		return unpackDateTime(br)
	elseif tag == TAG.ARRAY then
		local n = br:readVarUint()
		if n > (opts.maxArray :: number) then error("array too long") end
		local arr = table.create(n)
		for i = 1, n do arr[i] = readValueAuto(br, dict, depth + 1, opts) end
		return arr
	elseif tag == TAG.MAP then
		local pairsN = br:readVarUint()
		if pairsN > (opts.maxArray :: number) then error("object too large") end
		local obj: {[string]: any} = {}
		for _ = 1, pairsN do
			local keyId = br:readVarUint()
			local key = dict[keyId]
			if key == nil then error("bad key id") end
			obj[key] = readValueAuto(br, dict, depth + 1, opts)
		end
		return obj
	else
		error("unknown tag: " .. tostring(tag))
	end
end

local function autoPack(root: any, opts: Options): buffer
	local keys: {[string]: boolean} = {}
	collectKeyStrings(root, keys, 0, opts)
	local dict = makeDict(keys)
	local keyToId = buildKeyToId(dict)

	local bb = ByteBuilder.new()
	bb:putBytes(MAGIC_AUTO)
	bb:putByte(VERSION)
	bb:putByte(0) -- flags reserved

	bb:putVarUint(#dict)
	for _, s in ipairs(dict) do
		writeString(bb, s, opts)
	end

	if typeof(root) == "table" and not isArray(root) then
		-- Encode as MAP for root object
		local keysRoot = {}
		for k, _ in pairs(root) do keysRoot[#keysRoot+1] = tostring(k) end
		table.sort(keysRoot)
		bb:putByte(TAG.MAP)
		bb:putVarUint(#keysRoot)
		for _, sk in ipairs(keysRoot) do
			local id = keyToId[sk]
			if not id then error("key not in dictionary: "..sk) end
			bb:putVarUint(id)
			writeValueAuto(bb, (root :: any)[sk], 0, opts, keyToId)
		end
	else
		writeValueAuto(bb, root, 0, opts, keyToId)
	end

	return bb:toBuffer()
end

local function autoUnpack(buf: buffer, opts: Options): any
	local br = ByteReader.new(buf)
	local magic = br:readBytes(3)
	if magic ~= MAGIC_AUTO then error("not a Packager-AUTO buffer") end
	local ver = br:readByte(); if ver ~= VERSION then error("version mismatch") end
	local _flags = br:readByte()

	local dictN = br:readVarUint()
	local dict = table.create(dictN)
	for i = 1, dictN do
		dict[i] = readString(br, opts)
	end

	return readValueAuto(br, dict, 0, opts)
end

-- Schema system (minimal)
export type SchemaType = {
	enc: (bb: ByteBuilderT, v: any, opts: Options) -> (),
	dec: (br: ByteReaderT, opts: Options) -> any,
}

local S = {}

function S.u32(): SchemaType
	return {
		enc = function(bb, v, _)
			if typeof(v) ~= "number" or v < 0 then error("u32 expects non-negative number") end
			bb:putVarUint(math.floor(v))
		end,
		dec = function(br, _)
			return br:readVarUint()
		end,
	}
end

function S.f32(): SchemaType
	return {
		enc = function(bb, v, _)
			bb:putF32LE(v)
		end,
		dec = function(br, _)
			return br:readF32LE()
		end,
	}
end

function S.bool(): SchemaType
	return {
		enc = function(bb, v, _)
			bb:putByte(v and 1 or 0)
		end,
		dec = function(br, _)
			return br:readByte() ~= 0
		end,
	}
end

function S.str(): SchemaType
	return {
		enc = function(bb, v, opts)
			if typeof(v) ~= "string" then error("str expects string") end
			writeString(bb, v, opts)
		end,
		dec = function(br, opts)
			return readString(br, opts)
		end,
	}
end

function S.vec3(): SchemaType
	return {
		enc = function(bb, v, opts)
			if typeof(v) ~= "Vector3" then error("vec3 expects Vector3") end
			packVector3(bb, v, opts)
		end,
		dec = function(br, _)
			return unpackVector3(br)
		end,
	}
end

function S.vec2(): SchemaType
	return {
		enc = function(bb, v, opts)
			if typeof(v) ~= "Vector2" then error("vec2 expects Vector2") end
			packVector2(bb, v, opts)
		end,
		dec = function(br, _)
			return unpackVector2(br)
		end,
	}
end

function S.cframe(): SchemaType
	return {
		enc = function(bb, v, opts)
			if typeof(v) ~= "CFrame" then error("cframe expects CFrame") end
			packCFrame(bb, v, opts)
		end,
		dec = function(br, _)
			return unpackCFrame(br)
		end,
	}
end

function S.color(): SchemaType
	return {
		enc = function(bb, v, _)
			if typeof(v) ~= "Color3" then error("color expects Color3") end
			packColor565(bb, v)
		end,
		dec = function(br, _)
			return unpackColor565(br)
		end,
	}
end

function S.udim2(): SchemaType
	return {
		enc = function(bb, v, _)
			if typeof(v) ~= "UDim2" then error("udim2 expects UDim2") end
			packUDim2(bb, v)
		end,
		dec = function(br, _)
			return unpackUDim2(br)
		end,
	}
end

function S.enum(items: {string}): SchemaType
	-- items is ordered list of allowed names, e.g., {"None","Blue","Red"}
	local nameToId: {[string]: number} = {}
	for i, nm in ipairs(items) do nameToId[nm] = i end
	return {
		enc = function(bb, v, _)
			if typeof(v) ~= "EnumItem" then error("enum expects EnumItem") end
			local id = nameToId[v.Name]
			if not id then error("enum: unexpected "..v.Name) end
			bb:putVarUint(id)
		end,
		dec = function(br, _)
			local id = br:readVarUint()
			local nm = items[id]
			if not nm then error("enum: bad id") end
			-- decoder can return the string name, or you can map back to an Enum table you supply
			return nm
		end,
	}
end

function S.datetime(): SchemaType
	return {
		enc = function(bb, v, _)
			if typeof(v) ~= "DateTime" then error("datetime expects DateTime") end
			packDateTime(bb, v)
		end,
		dec = function(br, _)
			return unpackDateTime(br)
		end,
	}
end

function S.array(inner: SchemaType): SchemaType
	return {
		enc = function(bb, v, opts)
			if typeof(v) ~= "table" then error("array expects table") end
			local n = #v
			if n > (opts.maxArray :: number) then error("array too long") end
			bb:putVarUint(n)
			for i = 1, n do inner.enc(bb, v[i], opts) end
		end,
		dec = function(br, opts)
			local n = br:readVarUint()
			if n > (opts.maxArray :: number) then error("array too long") end
			local arr = table.create(n)
			for i = 1, n do arr[i] = inner.dec(br, opts) end
			return arr
		end,
	}
end

function S.struct(fields: {[string]: SchemaType}): SchemaType
	local order = {}
	for k, _ in pairs(fields) do order[#order+1] = k end
	table.sort(order)
	return {
		enc = function(bb, v, opts)
			if typeof(v) ~= "table" then error("struct expects table") end
			for _, k in ipairs(order) do
				local t = fields[k]
				local val = (v :: any)[k]
				if val == nil then error("missing field: "..k) end
				t.enc(bb, val, opts)
			end
		end,
		dec = function(br, opts)
			local out: {[string]: any} = {}
			for _, k in ipairs(order) do
				local t = fields[k]
				out[k] = t.dec(br, opts)
			end
			return out
		end,
	}
end

export type Schema = { name: string, version: number, root: SchemaType }

local function schemaPack(rootValue: any, sch: Schema, opts: Options): buffer
	local bb = ByteBuilder.new()
	bb:putBytes(MAGIC_SCHEMA)
	bb:putByte(VERSION)
	bb:putByte(0)
	writeString(bb, sch.name, opts)
	bb:putVarUint(sch.version)
	sch.root.enc(bb, rootValue, opts)
	return bb:toBuffer()
end

local function schemaUnpack(buf: buffer, sch: Schema, opts: Options): any
	local br = ByteReader.new(buf)
	local magic = br:readBytes(3)
	if magic ~= MAGIC_SCHEMA then error("not a Packager-SCHEMA buffer") end
	local ver = br:readByte(); if ver ~= VERSION then error("version mismatch") end
	local _flags = br:readByte()
	local name = readString(br, opts)
	local versionN = br:readVarUint()
	if name ~= sch.name or versionN ~= sch.version then
		error("schema header mismatch ("..name.." v"..tostring(versionN)..")")
	end
	return sch.root.dec(br, opts)
end

-- Public API
local Packager = {}

function Packager.init(opts: Options?)
	-- Optional global override; not required for use.
	runtimeOpts = mergeOptions(DEFAULTS, opts)
end

function Packager.pack(data: any, schOrOpts: any?, maybeOpts: Options?): (buffer, any?)
	local opts: Options
	local sch: Schema? = nil
	if schOrOpts and typeof(schOrOpts) == "table" and (schOrOpts :: any).root then
		sch = schOrOpts :: Schema
		opts = mergeOptions(runtimeOpts, maybeOpts)
	else
		opts = mergeOptions(runtimeOpts, schOrOpts)
	end
	if sch then
		return schemaPack(data, sch, opts), nil
	else
		return autoPack(data, opts), nil
	end
end

function Packager.unpack(buf: buffer, schOrOpts: any?, maybeOpts: Options?): any
	local opts: Options
	local sch: Schema? = nil
	if schOrOpts and typeof(schOrOpts) == "table" and (schOrOpts :: any).root then
		sch = schOrOpts :: Schema
		opts = mergeOptions(runtimeOpts, maybeOpts)
	else
		opts = mergeOptions(runtimeOpts, schOrOpts)
	end
	if sch then
		return schemaUnpack(buf, sch, opts)
	else
		return autoUnpack(buf, opts)
	end
end

function Packager.schema(name: string, version: number, root: SchemaType): Schema
	return { name = name, version = version, root = root }
end

Packager.S = S

return Packager
