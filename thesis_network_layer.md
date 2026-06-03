# Network Simulation Layer — Methodology

This document describes **only** the V2X network simulation/emulation layer implemented in this repository (`h3-vanet/VaN3Twin`). It explains, at the application level, how V2X messages produced by an external system enter the ns-3 simulation, traverse the 5G NR-V2X sidelink channel, and are returned to the external system.

The external gossip/decision engine (Rust) and the maps/traffic generation are **separate repositories** and are treated here strictly as external inputs/endpoints (see the final section).

---

## Files inspected before writing

| File | What was read |
|------|---------------|
| `src/traci/model/traci-client.cc` | ZMQ socket setup, main step loop, `ProcessGossipIn`, `OnGossipReceived`, `RegisterGossipApp` |
| `src/traci/model/traci-client.h` | ZMQ member sockets, gossip maps, method declarations |
| `src/traci/model/v2x-gossip-app.cc` | UDP socket creation, `Send`, `Receive` |
| `src/traci/model/v2x-gossip-app.h` | Class interface, UDP port |
| `src/automotive/helper/v2x-gossip-app-helper.cc` / `.h` | Application installation onto nodes |
| `src/automotive/examples/v2v-emergencyVehicleAlert-nrv2x.cc` | NR-V2X stack configuration, node pool, gossip-app install, scheduler |
| `Dockerfile.van3twin` | ns-3 branch, NR module branch, build/run commands |
| `entrypoint.sh` | Runtime command-line arguments |
| `docker/docker-compose.yml` | Published ZMQ ports |

---

## Terminology (defined on first use)

- **ns-3** — discrete-event network simulator used to model the wireless channel and protocol stack.
- **SUMO** — Simulation of Urban MObility; the road-traffic simulator. Provides vehicle positions only (external input).
- **TraCI** — Traffic Control Interface; SUMO's socket protocol. In this repo the `TraciClient` class is the ns-3-side TraCI client **and** the host of all the ZMQ bridging logic.
- **ZMQ (ZeroMQ)** — high-performance asynchronous messaging library used for inter-process communication between ns-3 and the external Rust engine.
- **PUSH / PULL** — ZMQ socket types forming a one-directional pipe (PUSH sends, PULL receives).
- **NR-V2X** — 5G New Radio Vehicle-to-Everything (3GPP Release 16).
- **Mode 2 (Sidelink)** — autonomous resource-selection mode: each vehicle chooses radio resources itself, **without** any base station (no infrastructure).
- **Sidelink (SL)** — the direct device-to-device radio link (PC5 interface).
- **SPS (Semi-Persistent Scheduling)** — sensing-based resource reservation used in Mode 2.
- **PSSCH / PSCCH** — Physical Sidelink Shared/Control Channel.
- **RSRP** — Reference Signal Received Power (dBm), the metric used by sensing.
- **MCS** — Modulation and Coding Scheme; index selecting modulation order + code rate.
- **BWP** — Bandwidth Part; a contiguous chunk of the carrier.
- **Numerology (µ)** — NR parameter setting subcarrier spacing (SCS = 15 kHz × 2^µ).
- **TFT (Traffic Flow Template)** — filter mapping IP flows onto a sidelink radio bearer.
- **Groupcast / dstL2Id** — sidelink multicast mode and its layer-2 destination identifier.
- **UDP** — User Datagram Protocol; connectionless transport.
- **PLR / PRR** — Packet Loss Ratio / Packet Reception Ratio.
- **CBR** — Channel Busy Ratio (channel-load metric).
- **DCC** — Decentralized Congestion Control (ETSI ITS-G5 congestion management).
- **CAM / DENM** — ETSI ITS Cooperative Awareness Message / Decentralized Environmental Notification Message.
- **BTP / GeoNetworking** — ETSI ITS transport (Basic Transport Protocol) and network (geographic routing) layers.
- **FdNetDevice** — ns-3 "file-descriptor" net device that bridges simulated packets to a real OS socket, **bypassing** the modelled radio. (Relevant because its absence is what makes the channel results meaningful — see Section C.)

---

## A. Role of this repository — the V2X network layer

This repository implements the **wireless network layer** of a larger co-simulation. Its single responsibility is to take opaque application-layer messages handed to it by an external gossip engine, transmit each one over a **physically modelled 5G NR-V2X Mode 2 sidelink** between mobile vehicle nodes, and report back **which neighbours actually received it**.

- **What enters:** JSON "gossip envelopes" from the external Rust engine over ZMQ, each tagged with the SUMO id of the transmitting vehicle (Section B).
- **What is modelled:** a real ns-3 vehicle node per vehicle, carrying a full NR-V2X protocol stack (IP → NR sidelink MAC/PHY) and a 3GPP propagation/channel model. Vehicle positions come from SUMO (external) and drive the geometry-dependent channel (Section D).
- **What leaves:** for every successful sidelink reception, a JSON message containing the receiver's id and the original payload, pushed back to the Rust engine over ZMQ (Section B).

Packet loss and latency are **not** injected synthetically; they emerge from the modelled radio (Section C/D).

---

## B. External-world ingestion and egress (ZMQ bridge)

All bridging is hosted by the `TraciClient` object. Four ZMQ sockets are bound in `SumoSetup`:

| Socket member | Type | Endpoint | Direction | Purpose |
|---------------|------|----------|-----------|---------|
| `m_zmq_pub` | PUSH | `tcp://*:5555` | ns-3 → bridge | vehicle lifecycle events (enter/exit, GPS) |
| `m_zmq_cmd` | PULL | `tcp://*:5558` | bridge → ns-3 | vehicle commands |
| `m_zmq_gossip_in` | PULL | `tcp://*:5560` | **Rust → ns-3** | **inbound gossip envelopes** |
| `m_zmq_gossip_out` | PUSH | `tcp://*:5561` | **ns-3 → Rust** | **delivered gossip receipts** |

Sources: `src/traci/model/traci-client.cc:460-484` (gossip sockets, ports 5560/5561, with `ZMQ_RCVHWM`/`ZMQ_SNDHWM` high-water marks), and `docker/docker-compose.yml:9-10` (ports published from the container).

### B.1 Inbound: receiving a message from the external system

`ProcessGossipIn()` (`src/traci/model/traci-client.cc:1084-1160`) is called once per simulation step (see Section F) and **non-blockingly** drains every datagram queued on port 5560:

1. Reads up to 65 535 bytes per message (`ZMQ_DONTWAIT`) — `traci-client.cc:1088-1094`.
2. Parses the envelope JSON for two fields with a lightweight string search: `sumo_id` (string) and `sender_id` (u64) — `traci-client.cc:1116-1117`.
3. Keeps a live `sumo_id → u64` map (`m_sumo_to_u64`) used later for egress — `traci-client.cc:1122-1123`.
4. Looks up the transmitting vehicle's send callback in `m_gossipSend[sumo_id]`. If no such vehicle exists in ns-3 (e.g., it already left the simulation), the message is **dropped and logged** — `traci-client.cc:1125-1130`.
5. Otherwise it invokes the callback with the **full raw envelope bytes** — `traci-client.cc:1132-1133`. This is the hand-off into the ns-3 radio stack (Section C).

**Fact:** the entire envelope (not just the payload) is what gets broadcast over the air — see the explicit comment at `traci-client.cc:1132` ("Forward the full envelope bytes — V2xGossipApp broadcasts them via NR-V2X").

### B.2 Outbound: returning a delivered message

When a neighbour node successfully receives a sidelink packet, `OnGossipReceived()` (`src/traci/model/traci-client.cc:1163-1245`) runs:

1. Resolves the receiver's u64 id from `m_sumo_to_u64`; if the external side never registered this vehicle the receipt is dropped (logged once) — `traci-client.cc:1168-1177`.
2. Extracts the inner `payload` object from the envelope — `traci-client.cc:1182-1197`.
3. Builds `{"receiver_id":<u64>,"payload":<payload JSON>}` — `traci-client.cc:1200-1201`.
4. Pushes it non-blockingly to the Rust engine on port 5561 — `traci-client.cc:1239`.

It also updates per-vehicle TX/RX counters and a unique-neighbour set used for the visualizer and the gossip log (`traci-client.cc:1204-1218`).

---

## C. CRITICAL — the packet injection point and the real data path

**Question:** do ingested packets descend through a real NR-V2X stack and cross the modelled channel (so that loss is physical), or do they take an `FdNetDevice → FdNetDevice` shortcut that bypasses the radio?

**Answer (verified): they traverse the full, real NR-V2X sidelink. There is no FdNetDevice shortcut anywhere in the gossip path.** A repository-wide search found no `FdNetDevice`/`EmuFdNetDevice` usage in `src/automotive` or `src/traci` except an unrelated entry in a CMake module list.

### C.1 The injection mechanism

`RegisterGossipApp()` binds each vehicle's SUMO id to a **real ns-3 application** installed on a **real ns-3 node**:

```cpp
m_gossipSend[vehicleId] = [app](const uint8_t* data, uint32_t len) {
    app->Send(data, len);                 // -> V2xGossipApp::Send
};
app->SetReceiveCallback(
    [this, vehicleId](...) { OnGossipReceived(vehicleId, data, len); });
```
`src/traci/model/traci-client.cc:1070-1081`

The `app` is a `V2xGossipApp` — an ordinary ns-3 `Application` that owns a **UDP socket** (`src/traci/model/v2x-gossip-app.cc:49`, created via `UdpSocketFactory`). Therefore the bytes coming in from ZMQ are **injected at the application layer of a genuine vehicle node**, exactly as if the node itself had generated them.

### C.2 The transmit path (per packet)

1. `V2xGossipApp::Send()` wraps the bytes in a `Packet` and calls `SendTo()` to the **multicast group 225.0.0.0**, UDP port **8001** — `src/traci/model/v2x-gossip-app.cc:70-76`.
2. The node has a full Internet stack installed (`InternetStackHelper::Install` on all vehicle nodes, `v2v-emergencyVehicleAlert-nrv2x.cc:600-601`).
3. Traffic to `225.0.0.0` is mapped onto an **NR sidelink groupcast bearer** by a TFT activated for that exact group address with `dstL2Id = 255`:
   - `tft = Create<LteSlTft>(... GroupCast, groupAddress4, dstL2Id)` and `ActivateNrSlBearer(...)` — `v2v-emergencyVehicleAlert-nrv2x.cc:602-631`.
4. The packet then descends through the NR-V2X stack on the `NrUeNetDevice` installed on every node (`nrHelper->InstallUeDevice`, `v2v-emergencyVehicleAlert-nrv2x.cc:405`) — UDP → IP → NR sidelink RLC/MAC → PHY — and is transmitted over the air using the configured 3GPP channel (Section D).

### C.3 The receive path (per packet)

Neighbour nodes receive (or, depending on SINR/interference/distance, **fail to receive**) the packet **through the modelled sidelink channel**. On a successful PHY/MAC delivery the packet rises back up the receiver's stack to **that node's** `V2xGossipApp::Receive()` (`src/traci/model/v2x-gossip-app.cc:78-92`), which invokes the registered callback → `OnGossipReceived()` → egress to Rust (Section B.2).

### C.4 Consequence for the thesis

Because (a) injection is at the application layer of a real node, (b) transport is real UDP/IP, (c) the air interface is a real NR sidelink groupcast bearer, and (d) there is no FdNetDevice bypass, the **packet loss ratio and latency observed by the external engine are physical outcomes of the NR-V2X Mode 2 model and the inter-vehicle geometry** — not artificial parameters. This is the central validity argument for any PLR/latency results.

**Assumption:** the TFT created with the group address (and no explicit port filter) maps **all** traffic to `225.0.0.0` onto the sidelink, so UDP port 8001 (gossip) is carried identically to the legacy EVA port 8000. Justification: the `LteSlTft` groupcast constructor used at `v2v-emergencyVehicleAlert-nrv2x.cc:625,629` is keyed on the destination group address `225.0.0.0`, and the gossip app sends to that same address (`v2x-gossip-app.cc:74`). The legacy CAM/EVA application (which used the same group on port 8000) is disabled (`v2v-emergencyVehicleAlert-nrv2x.cc:700-707`), so gossip is the sole user of the bearer.

---

## D. Access layer and channel model (NR-V2X Mode 2)

All values below are the defaults set in `src/automotive/examples/v2v-emergencyVehicleAlert-nrv2x.cc`. They are overridable on the command line but are **not** overridden by `entrypoint.sh`, so they are the operative values.

### D.1 Carrier and bandwidth part

| Parameter | Value | Source |
|-----------|-------|--------|
| Centre frequency | 5.89 GHz (3GPP band n47, TDD) | `:124` |
| Bandwidth | 400 (RB units as passed to the helper) | `:125` |
| Numerology µ | 2 → 60 kHz subcarrier spacing | `:129`, `:503` |
| Component carriers / BWPs | 1 CC, 1 BWP | `:326,331` |
| Channel scenario | `BandwidthPartInfo::V2V_Highway` | `:331` |

### D.2 Propagation and fading

- Channel scenario `V2V_Highway` (3GPP highway V2V model) — `:331`.
- **Fading/shadowing disabled by default**: `enableChannelRandomness = false` (`:141`); in that branch shadowing is off and the channel update period is set to 0 ms:
  - `ThreeGppChannelModel::UpdatePeriod = 0 ms`, `ShadowingEnabled = false` — `:351-353`.
- **Assumption:** with randomness disabled the channel is deterministic given geometry; loss therefore arises from path loss + interference/collisions + the link error model (Section D.4), not from random fading. Justification: the `else` branch at `:349-354` zeroes the stochastic components.

### D.3 PHY/MAC and SPS resource selection

| Parameter | Value | Source |
|-----------|-------|--------|
| Tx power | 23 dBm | `:126`, `:382` |
| Antenna | 1×2 isotropic, quasi-omni (no beamforming) | `:378-380` |
| Sensing enabled | **false** | `:137`, `:384` |
| SPS sensing window T0 | 100 ms | `:130`, `:477` |
| Selection window T1 / T2 | 2 / 81 slots | `:138-139`, `:385-386` |
| Subchannel size | 10 RB | `:132`, `:480` |
| Max resources per reserve | 3 | `:133`, `:481` |
| Reservation period | 20 ms | `:136`, `:388` |
| Sidelink processes | 4 | `:389` |
| Blind retransmission | enabled | `:390` |
| PSSCH RSRP threshold | −128 dBm | `:140`, `:391` |
| Sidelink bearer activation time | (cmd `slBearerActivationTime`) | `:171` |

### D.4 Error model, AMC and scheduler

| Parameter | Value | Source |
|-----------|-------|--------|
| SL error model | `ns3::NrLteMiErrorModel` (mutual-information BLER) | `:433-434` |
| AMC mode | `NrAmc::ErrorModel` (table-driven) | `:435` |
| Scheduler | `NrSlUeMacSchedulerSimple`, fixed MCS | `:442-443` |
| MCS index | 14 | `:143`, `:444` |

### D.5 ETSI DCC / CBR

**Not configured in this repository's gossip path.** No DCC or CBR-based congestion control is set up for the gossip application; congestion manifests only as physical-layer contention/collisions in the SPS process. (The legacy ETSI ITS stack that would carry DCC is disabled — Section E.) State this as a limitation.

---

## E. ETSI carrier / message type

- The gossip payload is **not** carried in a standard ETSI CAM or DENM and **does not** traverse the ETSI BTP/GeoNetworking stack. The ETSI application (Emergency Vehicle Alert / CAM sender) is **explicitly disabled** — `v2v-emergencyVehicleAlert-nrv2x.cc:700-707` (commented-out `CamSenderHelper`/`EmergencyVehicleAlertHelper` install, with the in-code note "EVA disabled for clean gossip PLR measurements").
- Instead the payload is the **opaque JSON gossip envelope** produced by the external engine, transported over **plain UDP** (port 8001) directly on the NR sidelink groupcast bearer — `src/traci/model/v2x-gossip-app.cc:70-76`.
- **Encapsulation:** `[NR-V2X SL] / IP (multicast 225.0.0.0) / UDP (8001) / raw JSON bytes`.
- **Message version:** not applicable — the schema is defined by the external Rust repo; this repo treats the bytes as an opaque blob (it only string-searches for `sumo_id`, `sender_id`, `payload`). No CAM/DENM v1/v2 versioning exists here.

---

## F. Emulation / real-time aspects

- **Scheduler:** the real-time scheduler (`ns3::RealtimeSimulatorImpl`) is bound **only if** the `realtime` flag is true — `v2v-emergencyVehicleAlert-nrv2x.cc:266-267`. Its default is **`false`** — `:97`. `entrypoint.sh` does **not** pass `--realtime`, so by default the simulation runs in **as-fast-as-possible discrete-event mode, not wall-clock real time**. Report this honestly: the system is a *co-simulation*, not a hard real-time emulator, unless `--realtime` is explicitly enabled.
- **Step loop / time-keeping:** `SumoSimulationStep()` is the periodic driver — each step it (1) drains commands (`ProcessCommands`), (2) **drains inbound gossip (`ProcessGossipIn`)**, (3) advances SUMO by one interval, (4) re-syncs the node map, (5) updates positions — `traci-client.cc:527-548`. The next step is rescheduled at `m_synchInterval` — `:524,539`.
- **SUMO update interval:** `SynchInterval` = `sumo_updates` seconds. The example default is small (`sumo_updates`), and `entrypoint.sh` sets `SUMO_UPDATES=0.1` → 100 ms TraCI/gossip polling cadence — `entrypoint.sh:17`, applied at `v2v-emergencyVehicleAlert-nrv2x.cc:640`. **This interval is also the polling granularity for inbound ZMQ gossip**, since `ProcessGossipIn` runs once per step.
- **FdNetDevice / promiscuous mode:** **not used.** No external OS interface is bridged; ingestion is via ZMQ into an application, not via a kernel tap. There is therefore no promiscuous-mode or root-networking requirement for the radio path.
- **Documented real-time constraint:** the gossip ZMQ sockets set high-water marks and use `ZMQ_DONTWAIT`; on overflow messages are **dropped and counted** (`[gossip-drop]`) rather than blocking the simulation — `traci-client.cc:1155-1159,1238-1244`. This bounds memory but means a too-fast external producer can lose messages at the bridge (independent of radio loss).

---

## G. Reproducibility (build + run, as read from this repo)

**ns-3 base branch:** `ns-3-dev-v2x-v0.2` from `gitlab.com/cttc-lena/ns-3-dev.git` — `Dockerfile.van3twin:35-36`.
**NR module branch:** `nr-v2x-dev` from `gitlab.com/cttc-lena/nr.git` — `Dockerfile.van3twin:39-41`.
(The vendored `src/nr` in this repo corresponds to the 5G-LENA NR module; its release-notes file is present at `src/nr/RELEASE_NOTES.md`.)

**Configure** (`Dockerfile.van3twin:115-120`):
```
./ns3 configure --build-profile=optimized --disable-tests --disable-python \
    --enable-examples \
    --disable-modules=wimax,mesh,dsr,dsdv,uan,lr-wpan,brite,click,openflow
```

**Build** (`Dockerfile.van3twin:122`):
```
./ns3 build -j"$(nproc)"
```

**Run** (`entrypoint.sh:26-36`):
```
./ns3 run "v2v-emergencyVehicleAlert-nrv2x" -- \
    --sumo-folder=${SUMO_FOLDER} --sumo-config=${SUMO_CONFIG} \
    --mob-trace=${MOB_TRACE} --vehicle-visualizer=${VEHICLE_VISUALIZER} \
    --sumo-gui=${SUMO_GUI} --sumo-updates=${SUMO_UPDATES} \
    --penetrationRate=${PENETRATION_RATE} --simTime=${SIM_TIME} \
    --csv-log=${CSV_LOG} --sumo-wait=${SUMO_WAIT}
```

---

## Parameter table (network layer)

| Name | Value | Unit | Source |
|------|-------|------|--------|
| Inbound gossip endpoint | `tcp://*:5560` (ZMQ PULL) | — | `traci-client.cc:463` |
| Outbound gossip endpoint | `tcp://*:5561` (ZMQ PUSH) | — | `traci-client.cc:476` |
| Max inbound datagram | 65 535 | bytes | `traci-client.cc:1088` |
| Gossip transport | UDP | — | `v2x-gossip-app.cc:49` |
| Gossip UDP port | 8001 | — | `v2x-gossip-app.h:32`, `v2x-gossip-app.cc:74` |
| Sidelink group address | 225.0.0.0 | — | `v2v-...-nrv2x.cc:603` |
| Sidelink dstL2Id | 255 | — | `v2v-...-nrv2x.cc:602` |
| Centre frequency | 5.89 | GHz | `v2v-...-nrv2x.cc:124` |
| Bandwidth | 400 | RB | `v2v-...-nrv2x.cc:125` |
| Numerology µ | 2 (60 kHz SCS) | — | `v2v-...-nrv2x.cc:129` |
| Channel scenario | V2V_Highway | — | `v2v-...-nrv2x.cc:331` |
| Fading/shadowing | disabled | — | `v2v-...-nrv2x.cc:141,351-353` |
| Tx power | 23 | dBm | `v2v-...-nrv2x.cc:126` |
| Sensing | disabled | — | `v2v-...-nrv2x.cc:137` |
| Sensing window T0 | 100 | ms | `v2v-...-nrv2x.cc:130` |
| T1 / T2 | 2 / 81 | slots | `v2v-...-nrv2x.cc:138-139` |
| Subchannel size | 10 | RB | `v2v-...-nrv2x.cc:132` |
| Reservation period | 20 | ms | `v2v-...-nrv2x.cc:136` |
| PSSCH RSRP threshold | −128 | dBm | `v2v-...-nrv2x.cc:140` |
| Error model | NrLteMiErrorModel | — | `v2v-...-nrv2x.cc:433` |
| AMC | ErrorModel | — | `v2v-...-nrv2x.cc:435` |
| Scheduler | NrSlUeMacSchedulerSimple (fixed MCS) | — | `v2v-...-nrv2x.cc:442-443` |
| MCS | 14 | index | `v2v-...-nrv2x.cc:143` |
| Realtime scheduler | false (default) | — | `v2v-...-nrv2x.cc:97,266-267` |
| Step / poll interval | 0.1 | s | `entrypoint.sh:17` |
| ETSI CAM/DENM/BTP/GeoNet | not used (EVA disabled) | — | `v2v-...-nrv2x.cc:700-707` |
| ETSI DCC / CBR | not configured | — | (absent) |
| ns-3 branch | ns-3-dev-v2x-v0.2 | — | `Dockerfile.van3twin:35` |
| NR module branch | nr-v2x-dev | — | `Dockerfile.van3twin:39` |

---

## External inputs / other repositories (document elsewhere)

The following are **out of scope for this layer** and must be documented in their own repositories:

1. **Gossip protocol logic (Rust engine).** Defines envelope schema (`sumo_id`, `sender_id`, `payload`), neighbour-selection / fan-out, TTL, gossip period, and the `u64` vehicle-id space. This repo treats the envelope as opaque bytes and only relays it. Endpoints: produces to `:5560`, consumes from `:5561`.
2. **Vehicle-id registration.** The external side must call the registration path that fills `m_sumo_to_u64`; without it outbound receipts are dropped (`traci-client.cc:1168-1177`). The mapping contract lives on the Rust side.
3. **Maps / parking layout.** Loaded as an external input file at startup via the SUMO config (`--sumo-config`, `--sumo-folder`, `entrypoint.sh:27-28`); its content and generation are produced by a separate repository — **external input, out of scope**.
4. **Traffic / mobility scenario.** The `.rou.xml` mobility trace (`--mob-trace`, `entrypoint.sh:29`) is an external input; vehicle generation, routes and densities are produced by a separate repository — **external input, out of scope**.
5. **Real-world coordinates.** Positions enter via SUMO/TraCI; this layer consumes them only to place ns-3 nodes for the channel geometry.
