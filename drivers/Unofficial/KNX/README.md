# KNX IoT Controller — SmartThings Edge driver (Approach D)

A **thin LAN Edge driver** for KNX installations, targeting the **standard KNX IoT 3rd-Party API**
(KNX Standard V3.0, ch. 3/10/4) instead of any vendor-proprietary gateway API. The KNX controller
owns the KNX stack, DPT encoding, KNX Secure and the ETS-derived catalog; this driver is a pure
outbound HTTPS client.

This is the implementation of **Approach D** from the research folder
[docs/KNX/](../../../docs/KNX/) — built to the locked decisions in
[KNX_ApproachD_Implementation_Guide.md](../../../docs/KNX/KNX_ApproachD_Implementation_Guide.md).

## How it improves on the shipping DeepSmart KNX driver

Same architecture class (thin LAN driver, controller owns KNX, catalog-driven device creation,
outbound-only), different engineering choices:

| Axis | DeepSmart (`drivers/DeepSmart/deepsmart`) | This driver |
|---|---|---|
| Backend API | Proprietary `homecontroller/api/v1` | **Open standard** KNX IoT 3rd-Party API |
| Portability | DeepSmart gateways only | **Any compliant controller** (Schneider Wiser for KNX / spaceLYnk, Gira, …) + the official PoC server |
| Auth | Mutual TLS with a bundled vendor cert | **OAuth2 client-credentials** (Basic-authenticated token exchange, proactive refresh, 401 retry) |
| Catalog semantics | PID/DPID → address-type table (`dp2knx`) | **KIM semantic functions** (`/functions` + typed datapoints with enum/unit/min/max) |
| Capability scope | HVAC-centric | Lights, dimmers, shades, thermostats, temperature sensors, scenes |
| Status | Polling every 2 s (full) | Polling with **`timeFilter` delta reads**, full-read recovery, value-diff cache |

## Architecture

```
SmartThings hub                                    KNX IoT controller
┌─────────────────────────────────────┐           ┌──────────────────────────┐
│  init.lua      lifecycle, commands  │   HTTPS   │ owns: KNX stack, DPTs,   │
│  api.lua       OAuth2 + JSON:API    ├──────────►│ Secure, ETS catalog (KIM)│
│  catalog.lua   /functions → devices │  outbound │                          │
│  poller.lua    GET /datapoints diff │   only    │ POST /oauth/access       │
│  mapping.lua   classify + coerce    │           │ GET  /functions[…]       │
│  logger.lua    prefixed + redacted  │           │ GET  /datapoints[?delta] │
└─────────────────────────────────────┘           │ PUT  /datapoints/values  │
                                                  └───────────┬──────────────┘
                                                              ▼ KNXnet/IP → KNX TP bus
```

- **Device model:** one LAN "KNX Controller" parent (Bridges card) + one `EDGE_CHILD` per KNX
  *function* (never per datapoint/group address), `parent_assigned_child_key` = the function's
  UUID. A dimmable light is **one** device with `switch` + `switchLevel`. This is what keeps a
  real installation under the 300-devices-per-location cap (creation stops at 290 with a warning).
- **Commands:** capability handler → role datapoint → `PUT /datapoints/values`
  `{data:[{id, type:"datapoint", attributes:{value:"…"}}]}`. **No optimistic tile flips** — a
  1-second-later delta poll reports the controller's truth (the sole exception: scene tiles blip
  on→off, scenes have no readable state).
- **Status:** per-controller scheduled tick — `GET /datapoints?filter[timestamp][gt]=<hwm>` where
  `<hwm>` is the newest **server-side** timestamp seen (no clock-sync issues), value-diff cache,
  events only on change. Every 20th tick and after any failure it does a full read (missed-change
  recovery, test plan TC-P7). Two consecutive failures mark the controller + children offline;
  the next good tick restores online.
- **Wire values are strings** (`"on"`, `"63"`, `"21.5"`): the controller already encodes DPTs, so
  the driver only coerces formats — enum words are picked from the **datapoint's own `enum` list**
  (handles on/off vs true/false vs up/down DPT-1.x variants), percent stays 0–100 (60 % is `"60"`,
  never 153), floats survive, KNX blind position (0 = open) is mirrored to ST shade level
  (100 = open).

## Onboarding

1. Install the driver, *Add device → Scan for nearby devices* → a **KNX Controller** shell is
   created (manual-IP-first; see Discovery status below).
2. Open the controller's **Settings** and enter: controller **IP**, **port**, OAuth2 **client ID**
   and **client secret** (for the PoC server: `ThirdPartyTestClient` / `TestClientSecret`), and
   optionally the **poll interval** (default 3 s).
3. On Save the driver authenticates, reads `/functions`, and creates a child device per mapped
   function. **Refresh** on the controller re-syncs the catalog after ETS changes.

## Function → profile mapping

Classification first tries the function's KIM `meta["@type"]` (e.g. `urn:knx:fct.dimming`), then
falls back to inspecting its datapoints:

| KNX function | Profile | Capabilities |
|---|---|---|
| `fct.switching` / `fct.switchLight` | `knx-switch` | switch |
| `fct.dimming` (or switch+scaling dps) | `knx-dimmer` | switch, switchLevel |
| `fct.sunProtection` / shutter / blind | `knx-shade` | windowShade, windowShadeLevel |
| heating / thermostat (writable temp dp) | `knx-thermostat` | temperatureMeasurement, thermostatHeatingSetpoint |
| read-only temperature dp | `knx-temperature` | temperatureMeasurement |
| `fct.scene*` | `knx-scene` | switch (momentary) |

Unmapped functions are skipped with an INFO log stating why.

## Testing

**Offline (no hub, no network)** — from this directory, with Lua 5.3:

```
lua5.3 src/test/offline_mapping_test.lua   # TC-U1/U2: classification + value coercion
lua5.3 src/test/offline_poller_test.lua    # TC-U4 + TC-P6/P7/P9 logic: diff, delta, recovery
lua5.3 src/test/offline_api_test.lua       # TC-P1/P8 logic: OAuth2, 401 retry, pagination, PUT shape
```

**Against the official PoC mock controller** (Method 1 of
[KNX_Driver_Test_Plan_v3.md](../../../docs/KNX/KNX_Driver_Test_Plan_v3.md)):

```
docker compose up        # image: itgesellschaft/thirdpartyapidemo (public)
```

Point the controller Settings at the Docker **host's LAN IP** (never `localhost`), port and the
test client credentials. Then run the **second-client test**: change a datapoint from the PoC UI
or Postman — the tile must update on the next poll cycle (~poll interval), *not* instantly.

**Deploy to a hub:**

```
smartthings edge:drivers:package . --install -C <channelId> -H <hubId>
smartthings edge:drivers:logcat --hub-address <hub-ip>     # all lines tagged [KNX]
```

## Deviations from the implementation guide (verified against the OAS)

- **Writes go to `PUT /datapoints/values`** — the guide's endpoint table says `PUT /datapoints`,
  but the OAS defines the write operation on `/datapoints/values` (`updateDatapoints`).
- **The OAS *does* define a WebSocket endpoint** (`/messaging/ws`, subprotocol `gw.knx.org`,
  scope `manage`) — the guide's "no streaming endpoint exists" note is stale. It is an *outbound*
  connection, so client-side TLS would work on Edge. Still not used here: the WS message format is
  explicitly not defined in the OAS (paper standard only) and the PoC server doesn't implement WS
  subscriptions, so it isn't testable. Documented as the future push upgrade; polling remains the
  shipped mechanism.

## Known limitations (v1)

- **TLS `verify="none"`** to accept the self-signed controller/PoC certs — lab default; cert
  pinning via a settings field is future work. Credentials/tokens are never logged
  (`src/logger.lua` redacts).
- **No curation UI** — all mappable functions are imported (up to the cap). The guide recommends
  letting the installer pick; future work.
- **Discovery is manual-IP only.** The mDNS service type for KNX IoT controllers is not defined in
  the OAS (guide §12) and the PoC doesn't advertise. Newer hub firmware exposes native `st.mdns`,
  so phase-2 discovery is a small addition once the service-type string is confirmed.
- Array-valued datapoints (`valueType:"object"`), HVAC modes, and multi-gang → component packing
  are out of scope for v1.
