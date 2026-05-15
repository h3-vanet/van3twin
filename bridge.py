import zmq
import json
import os
from scipy.spatial import KDTree
from modules.utils import convert_vin_to_vehicle_id, load_parking_data, root_setter

root_setter(__file__)

class Bridge:
    def __init__(self, zmq_sub_port, zmq_push_port, zmq_cmd_port):
        print(f"[bridge] init — sub={zmq_sub_port} push={zmq_push_port} cmd={zmq_cmd_port}")
        self.ctx = zmq.Context()

        self.sub = self.ctx.socket(zmq.PULL)
        self.sub.connect(f"tcp://{zmq_sub_port}")
        print(f"[bridge] SUB connesso a tcp://{zmq_sub_port}")

        self.cmd = self.ctx.socket(zmq.PUSH)
        self.cmd.connect(f"tcp://{zmq_cmd_port}")
        print(f"[bridge] CMD connesso a tcp://{zmq_cmd_port}")

        self.push = self.ctx.socket(zmq.PUB)
        self.push.bind(f"tcp://*:{zmq_push_port}")
        print(f"[bridge] PUSH bound su tcp://*:{zmq_push_port}")

        self.pull = self.ctx.socket(zmq.PULL)
        self.pull.bind("tcp://*:5556")
        self.pull.setsockopt(zmq.RCVTIMEO, 0)
        print(f"[bridge] PULL bound su tcp://*:5556")

        self.parking_data = load_parking_data("./mappa/parking.add.xml")
        self.parking_kdtree = KDTree([
            (float(s["lat"]), float(s["lon"])) for s in self.parking_data
        ])
        self.vehicle_id_map: dict[int, str] = {}
        self.slot_occupancy: dict[str, str] = {}
        print(f"[bridge] Caricati {len(self.parking_data)} parcheggi.")
        print(f"[bridge] pronto — in attesa di messaggi")

    def get_nearby_slots(self, lat, lng):
        indexes = self.parking_kdtree.query_ball_point((lat, lng), r=0.0001)
        slots = []
        for i in indexes:
            p = self.parking_data[i]
            capacity = int(p.get("capacity", p.get("roadsideCapacity", "1")))
            is_free = (p["id"] not in self.slot_occupancy) and capacity > 0
            slots.append({
                "type": "ParkingSpotObserved",
                "vehicle_id": None,
                "slot_lat": float(p["lat"]),
                "slot_lng": float(p["lon"]),
                "is_free": is_free
            })
        return slots

    def handle_assignment(self):
        try:
            cmd = self.pull.recv_json(flags=zmq.NOBLOCK)
            print(f"[bridge] AssignmentWon ricevuto: {cmd}")
            if cmd.get("type") == "AssignmentWon":
                vehicle_id = cmd.get("vehicle_id")
                slot_id = cmd.get("slot_id")
                vin = self.vehicle_id_map.get(vehicle_id)
                if vin is None:
                    print(f"[bridge] WARN — vehicle_id {vehicle_id} non trovato in vehicle_id_map")
                    return
                slot = next((s for s in self.parking_data if s["id"] == slot_id), None)
                if slot is None:
                    print(f"[bridge] WARN — slot_id {slot_id} non trovato in parking_data")
                    return
                self.slot_occupancy[slot_id] = vin
                lane = slot["lane"]
                edge = lane.rsplit("_", 1)[0]
                print(f"[bridge] comando ChangeTarget → vin={vin} edge={edge}")
                self.cmd.send_json({"type": "ChangeTarget", "vehicle_id": vin, "edge_id": edge})
                print(f"[bridge] comando SetStop → vin={vin} lane={lane}")
                self.cmd.send_json({
                    "type": "SetStop",
                    "vehicle_id": vin,
                    "lane_id": lane,
                    "end_pos": float(slot["startPos"]),
                    "duration": 86400.0
                })
        except zmq.Again:
            pass

    def run(self):
        msg_count = 0
        print("[bridge] loop avviato")
        while True:
            self.handle_assignment()
            try:
                raw = self.sub.recv_string(flags=zmq.NOBLOCK)
                msg = json.loads(raw)
                t = msg.get("type")
                vid_str = msg.get("vehicle_id")
                vid_u64 = convert_vin_to_vehicle_id(vid_str)
                msg_count += 1
                if msg_count % 100 == 0:
                    print(f"[bridge] {msg_count} messaggi ricevuti — ultimo: {t} vid={vid_str}")

                if t == "VehicleEntered":
                    self.vehicle_id_map[vid_u64] = vid_str
                    print(f"[bridge] VehicleEntered — vin={vid_str} u64={vid_u64} lat={msg['lat']:.5f} lng={msg['lng']:.5f}")
                    self.push.send_json({
                        "type": "VehicleEntered",
                        "vehicle_id": vid_u64,
                        "sumo_id": vid_str,
                        "lat": msg["lat"],
                        "lng": msg["lng"]
                    })

                elif t == "VehicleExited":
                    self.vehicle_id_map.pop(vid_u64, None)
                    self.slot_occupancy = {
                        k: v for k, v in self.slot_occupancy.items() if v != vid_str
                    }
                    print(f"[bridge] VehicleExited — vin={vid_str} u64={vid_u64}")
                    self.push.send_json({
                        "type": "VehicleExited",
                        "vehicle_id": vid_u64
                    })

                elif t == "GpsUpdate":
                    self.push.send_json({
                        "type": "GpsUpdate",
                        "vehicle_id": vid_u64,
                        "lat": msg["lat"],
                        "lng": msg["lng"],
                        "speed_ms": msg["speed_ms"]
                    })
                    slots = self.get_nearby_slots(msg["lat"], msg["lng"])
                    for slot in slots:
                        slot["vehicle_id"] = vid_u64
                        self.push.send_json(slot)

            except zmq.Again:
                pass

if __name__ == "__main__":
    print("[bridge] avvio")
    bridge = Bridge(
        zmq_sub_port=f"van3twin:{os.environ.get('ZMQ_VAN3TWIN_PORT', '5555')}",
        zmq_push_port=os.environ.get('ZMQ_PUSH_PORT', '5557'),
        zmq_cmd_port=f"van3twin:{os.environ.get('ZMQ_CMD_PORT', '5558')}",
    )
    print("[bridge] inizializzato, avvio loop")
    bridge.run()
