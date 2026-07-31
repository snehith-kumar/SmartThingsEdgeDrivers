# CLAUDE.md — KNX IoT Controller driver

Working notes for this directory. Read this first; research docs are in `../../../docs/KNX/`
(read that folder's CLAUDE.md for the A–E vocabulary — this driver is **Approach D**).

## What this is
SmartThings **Edge** (hub-local, Lua) driver for KNX via a controller implementing the
**standard KNX IoT 3rd-Party API** (KNX Standard V3.0). Pure outbound HTTPS client: OAuth2
client-credentials, JSON:API payloads, **polling-only status** (Edge `cosock` has no server-side
TLS → no HTTP callbacks; the spike proving this is `../knx-tls-spike/`). Package key
`knx-iot-controller`; permissions `lan` + `discovery`.

## Mental model
- **One LAN parent** ("KNX Controller", profile `knx-controller`, Bridges card, dni
  `knx-iot-controller-<ts>`) + **one `EDGE_CHILD` per KNX function** with
  `parent_assigned_child_key = <function uuid>`. Manual-IP onboarding: user enters
  host/port/clientId/clientSecret in parent Settings → `infoChanged` → `connect()`.
- `connect()` = authenticate → `catalog.sync` (GET /functions + per-function datapoints →
  `mapping.classify` → `try_create_device`) → persist `fn_roles` on the parent → `poller.start`.
- `fn_roles` (parent datastore field) is the **single source of mapping truth**:
  `{[fn_id] = {kind, profile, title, roles = {role → dp descriptor}}}`. Children carry no state;
  restarts rebuild the poll index from `fn_roles` without touching the network (`device_init`).
- Command path: handler → `resolve()` (fn_roles entry) → `mapping.*_wire()` →
  `api:put_value` (`PUT /datapoints/values`) → schedule a 1 s delta tick. **Never emit
  optimistically** (exception: scene blip, scenes have no state).
- Status path: `poller.tick` → `GET /datapoints` (delta via `filter[timestamp][gt]=<hwm>`,
  hwm = newest **server** timestamp) → diff `state.values` cache → `mapping.events_for` →
  emit on the child. Full read on: first tick, every 20th, after any failure, refresh.

## File map
```
src/init.lua      driver table, lifecycle, capability handlers, discovery, connect()
src/api.lua       KnxApi: OAuth2 (Basic + form, scope-variant fallback), request w/ 401-retry,
                  JSON:API pagination (page[number]/meta.collection.total), put_value
src/catalog.lua   sync (functions → children, 290 cap-guard), rebuild_index, fn_roles field
src/poller.lua    per-controller scheduled tick, delta/full logic, health (offline after 2 fails)
src/mapping.lua   classify (fn @type keywords → dp-based fallback), role extraction,
                  wire coercion (enum_pick honors dp.enum), events_for, STATUS_ROLES
src/logger.lua    log.*_with(hub_logs), "[KNX] ctx: op: msg", token/secret redaction
profiles/         knx-controller (+prefs), knx-{switch,dimmer,shade,thermostat,temperature,scene}
src/test/         offline suites — run from driver root with lua5.3 (see README Testing)
```

## Invariants — do not break these
1. **No optimistic tile flips.** Command handlers write and wait for the poll; the second-client
   test (test plan TC-P4) must show the ~poll-interval delay. Scene on→off blip is the one
   documented exception.
2. **Wire values are strings** and already in engineering units. Percent stays 0–100 — the
   "60 % must never become 153" rule (TC-U1). Enum writes must go through `mapping.enum_pick`
   so the datapoint's own enum casing/vocabulary wins.
3. **KNX shade position is inverted** vs ST: knx 0 = open = ST shadeLevel 100. Both directions
   go through `mapping.shade_position_wire` / `events_for("position_status")`.
4. **hwm comes from server timestamps only** (never `os.time()`) and any failed tick forces the
   next one full — that's the TC-P7 missed-change guarantee. Don't "optimize" either away.
5. **`fn_roles` must stay JSON-serializable** (plain tables; dp descriptors from
   `mapping.describe_datapoint`) — it goes through the datastore.
6. **Never log secrets/tokens** — everything user-visible goes through `logger.*` (redacts
   `client_secret`, `access_token`, `Bearer …`).
7. **Stable identity = function UUID** in `parent_assigned_child_key`; never an array index.
   `catalog.sync` must stay idempotent (existing keys skipped → no duplicates, TC-U5).

## Verified-against-OAS facts (don't re-litigate from the older docs)
- Writes: **`PUT /datapoints/values`** (guide's table saying `PUT /datapoints` is wrong).
- Token: `POST /oauth/access`, **HTTP Basic** client auth, `application/x-www-form-urlencoded`
  body `grant_type=client_credentials&scope=…`; OAS scopes are lowercase `read write manage`
  (PoC historically capitalized → `api.lua` tries both, remembers the winner).
- Delta: `filter[timestamp][gt]=<RFC3339>`; pagination `page[number]`/`page[size]`,
  totals in `meta.collection.total`.
- Function type lives in `meta["@type"]` (`urn:knx:fct.*`); datapoint typing in
  `attributes.datapointType` + `enum`/`unit`/`minimum`/`maximum`; values/timestamps in attributes.
- `/messaging/ws` **exists** in the OAS (outbound WS, subprotocol `gw.knx.org`) but its message
  format is not in the OAS and the PoC doesn't implement it → future push upgrade, not v1.

## Local verification (no hub)
Lua 5.3 + repo `lua_libs/` (paths are set inside the tests):
```
cd drivers/Unofficial/KNX
lua5.3 src/test/offline_mapping_test.lua
lua5.3 src/test/offline_poller_test.lua
lua5.3 src/test/offline_api_test.lua
luac5.3 -p src/*.lua            # parse check (init.lua can't be required offline: cosock)
```
On-hub: `smartthings edge:drivers:package . --install -C <channel> -H <hub>`, watch
`… logcat` for `[KNX]` lines. PoC mock: `itgesellschaft/thirdpartyapidemo` (README §Testing).

## Conventions
- All logs `logger.<level>(ctx, op, fmt, …)` — ctx is a device or string; shows as
  `[KNX] <label>: <op>: …` with `hub_logs=true`.
- Module requires are bare names (`require "mapping"`); `catalog` requires `poller` lazily
  inside functions to avoid a require cycle.
- When you change behavior, update README.md + this file in the same pass.
