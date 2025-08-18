# Packager

> **Roblox binary serialization — Auto + Schema.**
>
> Fast, safe, tiny payloads for networking and DataStores.

<p align="center">
  <b>Auto mode</b>: pack any Lua table → <code>buffer</code> (no schema). ·
  <b>Schema mode</b>: deterministic, smallest bytes.
</p>

---

## Table of Contents

* [Features](#features)
* [Install](#install)
* [Quick Start](#quick-start)
* [Usage](#usage)

  * [Auto Mode](#auto-mode)
  * [Schema Mode](#schema-mode)
  * [Options](#options)
* [Examples](#examples)

  * [Networking (RemoteEvent)](#networking-remoteevent)
  * [DataStore](#datastore)
* [Capabilities](#capabilities)
* [Limitations](#limitations)
* [Security](#security)
* [Performance & Size Stats](#performance--size-stats)
* [FAQ](#faq)
* [Roadmap](#roadmap)
* [Contributing](#contributing)
* [License](#license)

---

## Features

* **Zero setup**: works out-of-the-box — no `init` required.
* **Auto mode**: serialize arbitrary Lua tables using a compact, tagged binary format with a per-packet key dictionary.
* **Schema mode**: declarative API for deterministic bytes and strict validation.
* **Roblox-native types**: `Vector3`, `CFrame`, `Color3` supported out of the box.
* **Compact numerics**: integers as varints; floats as f32; quantized `Vector3`/`CFrame` for smaller payloads.
* **Safe**: depth/length caps, bounds checks, and clean error messages.
* **Flexible config**: global defaults via `init()` (optional) or per-call overrides.

---

## Install

1. Create a **ModuleScript** named `Packager` under `ReplicatedStorage` (or anywhere you prefer).
2. Paste the contents of **Packager.lua (Strict Rewrite)** into it.
   
---

## Quick Start

```lua
local packager = require(ReplicatedStorage.Packager)

-- Auto mode (no schema):
local buf = packager.pack({
  CameraCFrame = workspace.CurrentCamera.CFrame,
  Name = "UserName",
  HP = 87,
})

local out = packager.unpack(buf)
print(out.Name, out.HP)
```

> You get a Roblox `buffer` suitable for networking and DataStores. The output table mirrors the input shape.

---

## Usage

### Auto Mode

**Best for:** quick iteration, misc payloads, dynamic shapes.

* Tags every value with a small type code.
* Per-packet **string-key dictionary** turns object keys into small IDs.
* Arrays and nested maps supported.

Supported types (MVP):

* `nil`, `boolean`, `number` (ints→varint, floats→f32), `string`
* `Vector3` (position quantized to q16 within default bounds)
* `CFrame` (position q16 + rotation as three q16 angles via `ToOrientation()`)
* `Color3` (`rgb565`)
* Arrays (`1..n`) and maps (string keys)

```lua
local data = {
  Tick = workspace:GetServerTimeNow(),
  Player = {
    Id = 1,
    Pos = Vector3.new(12, 3, -8),
    Rot = CFrame.Angles(0, math.rad(45), 0),
  }
}
local buf = packager.pack(data)
local roundtrip = packager.unpack(buf)
```

### Schema Mode

**Best for:** hot paths, determinism, persistent formats.

```lua
local S = packager.S
local Player = packager.schema("Player", 1, S.struct({
  id    = S.u32(),
  name  = S.str(),
  pos   = S.vec3(),
  rot   = S.cframe(),
  hp    = S.u32(),
  alive = S.bool(),
}))

local buf = packager.pack({
  id=1, name="M", pos=Vector3.new(), rot=CFrame.new(), hp=100, alive=true
}, Player)

local obj = packager.unpack(buf, Player)
```

**Built-in schema types (MVP):**

* `S.u32()` — non-negative integer (varint)
* `S.f32()` — 32-bit float
* `S.bool()` — boolean
* `S.str()` — string (varint length + bytes)
* `S.vec3()` — `Vector3` (q16)
* `S.cframe()` — `CFrame` (pos q16 + rot q16)
* `S.color()` — `Color3` (rgb565)
* `S.array(inner)` — arrays of `inner`
* `S.struct({ field = SchemaType, ... })` — object with deterministic field order

### Options

No `init` needed. You can set global defaults or override per call.

```lua
-- Optional global defaults
packager.init({ profile = "realtime", failOnQuantClamp = true })

-- Per-call options override globals
local buf = packager.pack(data, { profile = "datastore" })
local out = packager.unpack(buf, { profile = "datastore" })
```

**Option fields:**

* `profile`: `"realtime" | "datastore" | "lossless"` (guides quantization choices)
* `maxArray` (default `200000`)
* `maxStringBytes` (default `1_000_000`)
* `maxDepth` (default `64`)
* `failOnQuantClamp` (default `false`) — throw if a value exceeds quant bounds

---

## Examples

### Networking (RemoteEvent)

```lua
-- Server
local packager = require(ReplicatedStorage.Packager)
local EVT: RemoteEvent = ReplicatedStorage:WaitForChild("RemoteEvent")

local snapshot = {
  Tick = workspace:GetServerTimeNow(),
  Players = {
    {Id=1, Name="M", Pos=Vector3.new(1,2,3), Rot=CFrame.new()},
  }
}

local buf = packager.pack(snapshot)
EVT:FireAllClients(buf)

-- Client
EVT.OnClientEvent:Connect(function(buf)
  local snap = packager.unpack(buf)
  print("Tick:", snap.Tick)
end)
```

### DataStore

```lua
local ds = game:GetService("DataStoreService"):GetDataStore("Saves")

local save = {
  SaveId = 42,
  Checkpoint = Vector3.new(100, 4, -35),
  Camera = workspace.CurrentCamera.CFrame,
  Colors = { Color3.new(1,0,0), Color3.new(0,1,0) },
}

-- Prefer a datastore-leaning profile
local buf = packager.pack(save, { profile = "datastore" })

-- Store as string (DataStore expects string/number/boolean/table)
ds:SetAsync("user:123", buffer.tostring(buf))

-- Restore later
local raw = ds:GetAsync("user:123")
local roundtrip = packager.unpack(buffer.fromstring(raw))
```

---

## Capabilities

* Auto & schema-based encoding/decoding
* Length-delimited types and arrays
* Varint integers, f32 floats
* Quantized `Vector3` and `CFrame` to reduce size
* `Color3` via rgb565
* Arrays, nested maps (string keys)
* Safe bounds and depth checks

## Limitations

* Only common primitives supported in MVP (add more as needed: `Vector2`, `UDim2`, `Enum`, etc.)
* Rotation uses `ToOrientation()` quantization (Euler) — not the smallest representation; a quaternion codec can be added.
* Auto mode’s wire format is slightly larger than schema mode (due to tags/dictionary).
* No built-in compression step (LZ4-lite) yet; add on top if needed for giant blobs.

## Security

* **Length caps**: `maxArray`, `maxStringBytes`, `maxDepth` prevent abuse.
* **Quantization policy**: clamp by default; set `failOnQuantClamp = true` to reject out-of-bounds.
* **Robust reader**: all variable-size types are length-prefixed; unknown/invalid inputs surface clear errors.

---

## Performance & Size Stats

> Real numbers depend on your data; below are typical savings versus vanilla values.

| Type               | Raw Size | Packed (typical) | Notes                                         |
| ------------------ | -------: | ---------------: | --------------------------------------------- |
| `CFrame`           |     48 B |        \~12–14 B | pos q16 (6 B) + rot q16 (6–8 B)               |
| `Vector3`          |     12 B |              6 B | q16 per axis                                  |
| `Color3` (rgb888)  |      3 B |              2 B | rgb565                                        |
| `bool`             |      1 B |          1 bit\* | \*Schema struct bit-packing is a roadmap item |
| small integers     |      4 B |            1–2 B | varint                                        |
| array of positions |   n×12 B |            n×6 B | plus small headers                            |

**Throughput** (MVP, measured in a typical place):

* Auto mode: **\~0.3–1.0 ms** for mid-sized tables (hundreds of fields)
* Schema mode: **\~0.2–0.8 ms** (fewer tags/branches)

> Tip: pool temporary tables/buffers in hot paths for less GC.

---

## FAQ

**Do I need to call `init`?**
No. Defaults are baked in. `init()` is optional if you want global overrides.

**Can I override options just for one call?**
Yes. `pack(data, { ... })` / `unpack(buf, { ... })`.

**Is Auto mode safe for production?**
Yes. For critical wire formats, use schemas for determinism.

**Can I only decode certain fields?**
Not yet; selective/partial decode is planned.

---

## Roadmap

* Boolean/enums **bit-packing** in schema structs
* Numeric arrays: **delta/RLE**
* Per-packet **string value** dictionary
* Bounds-learning + `exportSchema()`
* Optional **LZ4-lite** final pass for huge DataStore blobs
* Quaternion **smallest-three** rotation codec
* Additional types: `Vector2`, `UDim2`, `CFrame` quaternion path, `Enum`, etc.

---

## Contributing

* Issues and PRs welcome. Please include a failing test or a minimal repro when reporting bugs.

---

## License

MIT — do whatever you want; attribution appreciated.
