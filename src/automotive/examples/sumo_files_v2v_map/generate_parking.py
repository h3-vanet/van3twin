"""
Synthetic parking slot generator from SUMO map.net.xml.
Saves each slot's bearing for visualization as oriented rectangles.
"""
import xml.etree.ElementTree as ET
from xml.dom import minidom
from pathlib import Path
import h3, math
import sumolib

SLOT_SPACING_M  = 12.0
MIN_LANE_LENGTH = 20.0
SLOT_LENGTH     = 5.0
SLOT_WIDTH      = 2.5
H3_RESOLUTION   = 14

INCLUDED_EDGE_TYPES = {
    "highway.residential", "highway.living_street",
    "highway.secondary",   "highway.secondary_link",
    "highway.tertiary",    "highway.tertiary_link",
    "highway.primary",     "highway.unclassified",
}


def haversine(lat1, lon1, lat2, lon2):
    R = 6371000.0
    r1, r2 = math.radians(lat1), math.radians(lat2)
    dr = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dr / 2) ** 2 + math.cos(r1) * math.cos(r2) * math.sin(dl / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def bearing_deg(lat1, lon1, lat2, lon2):
    r1 = math.radians(lat1)
    r2 = math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(r2)
    y = math.cos(r1) * math.sin(r2) - math.sin(r1) * math.cos(r2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def interpolate_lane(points, dist_m):
    """Interpolate along a sequence of (lat, lon) waypoints to reach dist_m.
    Returns (lat, lon, bearing_degrees)."""
    acc = 0.0
    for i in range(len(points) - 1):
        lat1, lon1 = points[i]
        lat2, lon2 = points[i + 1]
        seg = haversine(lat1, lon1, lat2, lon2)
        if acc + seg >= dist_m:
            t = (dist_m - acc) / seg if seg > 0 else 0.0
            return (lat1 + (lat2 - lat1) * t,
                    lon1 + (lon2 - lon1) * t,
                    bearing_deg(lat1, lon1, lat2, lon2))
        acc += seg
    lat1, lon1 = points[-2]
    lat2, lon2 = points[-1]
    return lat2, lon2, bearing_deg(lat1, lon1, lat2, lon2)


def sumo_to_latlon(sumo_x, sumo_y, net):
    """Convert SUMO XY → (lat, lon) using sumolib's exact UTM projection.
    sumolib.convertXY2LonLat returns (lon, lat); we swap to (lat, lon)."""
    lon, lat = net.convertXY2LonLat(sumo_x, sumo_y)
    return lat, lon


def parse_net(net_path, net):
    """Parse map.net.xml and return lane descriptors with geographic waypoints.
    net_path: str path for ET.parse (reads edge types and lane shapes)
    net:      sumolib.Net object for coordinate conversion
    """
    tree = ET.parse(net_path)
    root = tree.getroot()

    # Build edge-type lookup (internal edges start with ':' and are skipped below)
    etypes = {e.get("id", ""): e.get("type", "") for e in root.findall("edge")}

    lanes = []
    for edge in root.findall("edge"):
        eid = edge.get("id", "")
        if eid.startswith(":"):
            continue
        if etypes.get(eid, "") not in INCLUDED_EDGE_TYPES:
            continue
        for lane in edge.findall("lane"):
            length = float(lane.get("length", 0))
            shape  = lane.get("shape", "")
            if length < MIN_LANE_LENGTH or not shape:
                continue
            pts = []
            for token in shape.split():
                if "," not in token:
                    continue
                sx, sy = token.split(",", 1)
                # Store points as (lat, lon) — the convention used by haversine/bearing
                pts.append(sumo_to_latlon(float(sx), float(sy), net))
            if len(pts) >= 2:
                lanes.append({"id": lane.get("id"), "length": length, "points": pts})
    return lanes


def generate_slots(lanes):
    """Place one parking slot per H3 cell along each lane."""
    seen  = set()
    slots = []
    for lane in lanes:
        L   = lane["length"]
        pts = lane["points"]
        pos = SLOT_LENGTH / 2.0
        while pos + SLOT_LENGTH / 2.0 <= L:
            lat, lon, brg = interpolate_lane(pts, pos)
            cid = h3.latlng_to_cell(lat, lon, H3_RESOLUTION)
            if cid not in seen:
                seen.add(cid)
                slots.append({
                    "id":        cid,
                    "lane":      lane["id"],
                    "start_pos": max(0.0, pos - SLOT_LENGTH / 2.0),
                    "end_pos":   min(L,   pos + SLOT_LENGTH / 2.0),
                    "lat":       lat,
                    "lon":       lon,
                    "bearing":   brg,
                    "length":    SLOT_LENGTH,
                    "width":     SLOT_WIDTH,
                })
            pos += SLOT_SPACING_M
    return slots


def export_xml(slots, output_path):
    additional = ET.Element("additional")
    for s in slots:
        ET.SubElement(additional, "parkingArea", {
            "id":              s["id"],
            "lane":            s["lane"],
            "startPos":        f"{s['start_pos']:.2f}",
            "endPos":          f"{s['end_pos']:.2f}",
            "roadsideCapacity": "1",
            "angle":           "0",
            "length":          str(s["length"]),
            "width":           str(s["width"]),
            "lat":             f"{s['lat']:.7f}",
            "lon":             f"{s['lon']:.7f}",
            "bearing":         f"{s['bearing']:.1f}",
        })
    xmlstr = minidom.parseString(ET.tostring(additional, encoding="utf-8")).toprettyxml(indent="    ")
    lines = [l for l in xmlstr.split("\n") if l.strip()]
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"Written {len(slots)} slots to {output_path}")


def main():
    net_path = "./mappa/map.net.xml"
    out_path = Path("./mappa/parking2.add.xml")

    if not Path(net_path).exists():
        print(f"Error: {net_path} not found")
        return

    print("Loading map with sumolib...")
    net = sumolib.net.readNet(net_path)

    print("Parsing lanes...")
    lanes = parse_net(net_path, net)
    print(f"Lanes found: {len(lanes)}")

    slots = generate_slots(lanes)
    print(f"Slots generated: {len(slots)}")

    export_xml(slots, out_path)


if __name__ == "__main__":
    main()
