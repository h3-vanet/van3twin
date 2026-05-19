/**
 * This file contains the client JavaScript logic, in charge of receiving the coordinates of the objects
 * (i.e. the vehicles) and their heading from the server (which in turn receives them from ms-van3t via UDP).
 * This script uses the received information in order to render a Leaflet JS map showing all the moving nodes.
 * The server->client communication is realized thanks to socket.io.
 */

// Constant for an unavailable heading value (VIS_HEADING_INVALID)
const VIS_HEADING_INVALID = 361;

// Car and circle icon indeces
const CAR_ICO_IDX = 0;
const CIRCLE_ICO_IDX = 1;

// Start socket.io()
const socket = io();

var map_rx = false;

// Polygon messages received before the map was ready; flushed after map init
var pendingPolygons = [];

// Markers array (shared between vehicles and polygons, keyed by unique ID)
var markers = [];
// Markers icon array ('0' for carIcon, i.e. CAR_ICO_IDX, '1' for circleIcon, i.e. CIRCLE_ICO_IDX)
var markersicons = [];

// Per-vehicle gossip state: id → {tx, rx, neighbors}
var vehicleGossip = {};

// Map reference variable
var leafletmap = null;

// SVG DivIcon factory — replaces static triangle.png / circle.png.
// Color reflects gossip state; leaflet.rotatedMarker.js still handles rotation via CSS transform.
function makeVehicleIcon(color, hasHeading) {
	const size = 20;
	const svg = hasHeading
		? `<svg width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg">
		     <polygon points="10,1 19,19 10,15 1,19" fill="${color}" stroke="white" stroke-width="1.5"/>
		   </svg>`
		: `<svg width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg">
		     <circle cx="10" cy="10" r="8" fill="${color}" stroke="white" stroke-width="1.5"/>
		   </svg>`;
	return L.divIcon({ html: svg, className: '', iconSize: [size, size], iconAnchor: [size/2, size/2] });
}

const DEFAULT_COLOR = '#9e9e9e';


// Receive the first message from the server
socket.on('message', (msg) => {
	if (msg == null) {
		document.getElementById('statusid').innerHTML = '<p>Waiting for a connection from ms-van3t</p>';
	} else if (msg.startsWith('{')) {
		// JSON batch message path (batch_positions)
		try {
			const parsed = JSON.parse(msg);
			if (parsed.type === 'batch_positions' && Array.isArray(parsed.vehicles)) {
				parsed.vehicles.forEach(v => {
					update_marker(leafletmap, v.id, v.lat, v.lng,
						v.heading !== undefined ? v.heading : VIS_HEADING_INVALID);
				});
			}
		} catch(e) {
			console.warn("VehicleVisualizer: failed to parse JSON message:", e);
		}
	} else {
		let msg_fields = msg.split(",");

		switch (msg_fields[0]) {
			// "map draw" message: "map,<lat>,<lon>,<mapbox token>"
			case 'map':
				if (map_rx === false) {
					if (msg_fields.length !== 4) {
						console.error("VehicleVisualizer: Error: received a corrupted map draw message from the server");
					} else {
						console.info("VehicleVisualizer: The map will be drawn centered at: ", msg_fields[1], msg_fields[2]);
						document.getElementById('statusid').innerHTML = '';
						let mapbox_token;

						console.log(msg_fields[3]);

						if(msg_fields[3] != "none") {
							mapbox_token = msg_fields[3];
						} else {
							mapbox_token = null;
						}
						leafletmap = draw_map(parseFloat(msg_fields[1]), parseFloat(msg_fields[2]), mapbox_token);
						map_rx = true;
						// Flush polygons that arrived before the map was ready
						console.log("[poly] map ready, flushing " + pendingPolygons.length + " buffered polygons");
						pendingPolygons.forEach(p => update_polygon(leafletmap, p.id, p.color, p.shape));
						pendingPolygons = [];
					}
				}
				break;
			// "object update"/vehicle update message: "object,<unique object ID>,<lat>,<lon>,<heading>"
			case 'object':
				if(msg_fields.length !== 5) {
					console.error("VehicleVisualizer: Error: received a corrupted object update message from the server.");
				} else {
					update_marker(leafletmap,msg_fields[1],parseFloat(msg_fields[2]),parseFloat(msg_fields[3]),parseFloat(msg_fields[4]));
				}
				break;
			// "polygon update" message: "poly,<id>,<r>;<g>;<b>;<a>,<lon1>:<lat1>:<lon2>:<lat2>:..."
			case 'poly':
				if (msg_fields.length !== 4) {
					console.error("VehicleVisualizer: corrupted poly message (fields=" + msg_fields.length + "):", msg);
				} else if (!map_rx) {
					console.log("[poly] buffering (map not ready yet) id=" + msg_fields[1]);
					pendingPolygons.push({id: msg_fields[1], color: msg_fields[2], shape: msg_fields[3]});
				} else {
					console.log("[poly] drawing id=" + msg_fields[1]);
					update_polygon(leafletmap, msg_fields[1], msg_fields[2], msg_fields[3]);
				}
				break;

			// gossip,<id>,<tx>,<rx>,<neighbors> — per-vehicle gossip metrics
			case 'gossip': {
				if (msg_fields.length < 5) { console.warn("VehicleVisualizer: malformed gossip message"); break; }
				const id  = msg_fields[1];
				const tx  = parseInt(msg_fields[2]);
				const rx  = parseInt(msg_fields[3]);
				const nbr = parseInt(msg_fields[4]);
				const prev = vehicleGossip[id] || {tx: 0, rx: 0, neighbors: 0};
				vehicleGossip[id] = {tx, rx, neighbors: nbr};
				const color = gossipColor(tx, rx);
				if (id in markers && markers[id].setIcon) {
					markers[id].setIcon(makeVehicleIcon(color, markersicons[id] === CAR_ICO_IDX));
					const fanout = tx > 0 ? (rx / tx).toFixed(1) : '-';
					markers[id].setPopupContent(
						`<b>${id}</b><br>TX rounds: ${tx} &nbsp; RX: ${rx}<br>Neighbors: ${nbr}<br>Avg Fanout: ${fanout} rx/tx`);
				}
				if (tx > prev.tx && id in markers && markers[id].getLatLng)
					showTxRing(leafletmap, markers[id].getLatLng().lat, markers[id].getLatLng().lng);
				updateStatsPanel();
				break;
			}

			// experiment,<scenario>,<density>,<k>,<interval>,<assignments>,<won>,<double>,<handovers>,<speed>,<simtime_s>
			case 'experiment': {
				if (msg_fields.length < 10) break;
				document.getElementById('exp-scenario').textContent    = msg_fields[1]  || '-';
				document.getElementById('exp-density').textContent     = msg_fields[2]  || '-';
				document.getElementById('exp-k').textContent           = msg_fields[3]  || '-';
				document.getElementById('exp-interval').textContent    = msg_fields[4]  || '-';
				document.getElementById('exp-assignments').textContent = msg_fields[5]  || '0';
				document.getElementById('exp-won').textContent         = msg_fields[6]  || '0';
				document.getElementById('exp-double').textContent      = msg_fields[7]  || '0';
				document.getElementById('exp-handovers').textContent   = msg_fields[8]  || '0';
				document.getElementById('exp-speed').textContent       = msg_fields[9]  || '-';
				if (msg_fields[10] !== undefined)
					document.getElementById('exp-simtime').textContent = formatSimTime(msg_fields[10]);
				break;
			}

			// This 'case' is added just for additional safety. As the server is shut down every time a "terminate" message
			// is received from ms-van3t and no "terminate" message is forwarded via socket.io, this point should never be
			// reached
			case 'terminate':
				console.log("The server has been terminated.");
				break;

			default:
				console.warn("VehicleVisualizer: Warning: unknown message type received from the server");
		}
	}
});

// This function is used to update the position (and heading/rotation) of a marker/moving object on the map
function update_marker(mapref,id,lat,lon,heading)
{
	if(mapref == null) {
		console.error("VehicleVisualizer: null map reference when attempting to update an object")
	} else {
		// If the object ID has never been seen before, create a new marker
		if(!(id in markers)) {
			const hasHeading = heading < VIS_HEADING_INVALID;
			const icon_idx   = hasHeading ? CAR_ICO_IDX : CIRCLE_ICO_IDX;
			const newmarker  = L.marker([lat, lon], {icon: makeVehicleIcon(DEFAULT_COLOR, hasHeading)}).addTo(mapref);
			newmarker.setRotationAngle(heading);
			newmarker.bindPopup(`<b>${id}</b><br>Heading: ${hasHeading ? heading + ' deg' : 'unavailable'}`);
			markers[id]      = newmarker;
			markersicons[id] = icon_idx;
		// If the object ID has already been seen before, just update position and rotation
		} else {
			const marker     = markers[id];
			const hasHeading = heading < VIS_HEADING_INVALID;
			const newIdx     = hasHeading ? CAR_ICO_IDX : CIRCLE_ICO_IDX;
			marker.setLatLng([lat, lon]);
			marker.setRotationAngle(heading);
			// If heading availability changed, rebuild icon (color preserved from last gossip update)
			if (newIdx !== markersicons[id]) {
				const g = vehicleGossip[id];
				const color = g ? gossipColor(g.tx, g.rx) : DEFAULT_COLOR;
				marker.setIcon(makeVehicleIcon(color, hasHeading));
				markersicons[id] = newIdx;
			}
		}
	}
}

// Updates (or creates) a polygon overlay on the map.
// colorStr: "r;g;b;a"  (SUMO convention: a=255 fully opaque)
// shapeStr: "lon1:lat1:lon2:lat2:..."  (raw SUMO lon,lat order; swapped here for Leaflet)
function update_polygon(mapref, id, colorStr, shapeStr)
{
	if (mapref == null) {
		console.error("VehicleVisualizer: null map reference when attempting to update a polygon.");
		return;
	}

	// Parse color
	const rgba = colorStr.split(';').map(Number);
	if (rgba.length !== 4 || rgba.some(isNaN)) {
		console.error("VehicleVisualizer: malformed color in poly message:", colorStr);
		return;
	}
	const [r, g, b, a] = rgba;
	const cssColor     = `rgb(${r},${g},${b})`;
	const fillOpacity  = a / 255;
	const borderOpacity = Math.min(fillOpacity + 0.2, 1.0);

	// Parse shape: lon:lat:lon:lat:... -> [[lat,lon], ...]
	const raw = shapeStr.split(':').map(parseFloat);
	if (raw.length < 4 || raw.length % 2 !== 0 || raw.some(isNaN)) {
		console.error("VehicleVisualizer: malformed shape in poly message:", shapeStr);
		return;
	}
	const latlngs = [];
	for (let i = 0; i < raw.length; i += 2) {
		latlngs.push([raw[i + 1], raw[i]]); // swap lon,lat -> lat,lon for Leaflet
	}

	const style = {
		color:       cssColor,
		weight:      1,
		opacity:     borderOpacity,
		fillColor:   cssColor,
		fillOpacity: fillOpacity,
	};

	if (id in markers) {
		markers[id].setLatLngs(latlngs);
		markers[id].setStyle(style);
	} else {
		const poly = L.polygon(latlngs, style).addTo(mapref);
		// bindPopup does not work with Canvas renderer; use click event instead
		poly.on('click', () => poly.bindPopup("ID: " + id).openPopup());
		markers[id] = poly;
	}
}

// Format simulation seconds as M:SS (e.g. 125.3 → "2:05")
function formatSimTime(s) {
	const sec = parseFloat(s);
	if (isNaN(sec)) return '-';
	const m = Math.floor(sec / 60);
	const r = Math.floor(sec % 60);
	return `${m}:${r.toString().padStart(2, '0')}`;
}

// Returns vehicle marker color based on gossip TX/RX state
function gossipColor(tx, rx) {
	if (tx > 0 && rx > 0) return '#4caf50';  // green  — active, receiving
	if (tx > 0)           return '#ff9800';  // orange — sending, not yet receiving
	return '#9e9e9e';                         // grey   — no gossip yet
}

// Show expanding ring at (lat,lon) to visualise a gossip radio transmission (~400m NR-V2X range)
function showTxRing(mapref, lat, lon) {
	if (!mapref) return;
	const ring = L.circle([lat, lon], {
		radius: 400, color: '#4fc3f7', fillOpacity: 0, opacity: 0.7, weight: 2
	}).addTo(mapref);
	setTimeout(() => mapref.removeLayer(ring), 1500);
}

// Recompute and display aggregate gossip statistics in the stats panel
function updateStatsPanel() {
	const vals           = Object.values(vehicleGossip);
	const totalTx        = vals.reduce((s, v) => s + v.tx, 0);
	const totalRx        = vals.reduce((s, v) => s + v.rx, 0);
	const vehiclesWithTx = vals.filter(v => v.tx > 0);
	// Per-vehicle average delivery ratio: avoids >100% from broadcast fan-out
	const avgFanout = vehiclesWithTx.length > 0
		? (vehiclesWithTx.reduce((s, v) => s + (v.rx / v.tx), 0) / vehiclesWithTx.length).toFixed(1)
		: '-';
	const connected  = vals.filter(v => v.rx > 0).length;
	const connRatio  = vals.length > 0 ? Math.round(connected / vals.length * 100) : 0;
	document.getElementById('stat-vehicles').textContent        = vals.length;
	document.getElementById('stat-gossip-active').textContent   = vehiclesWithTx.length;
	document.getElementById('stat-total-tx').textContent        = totalTx;
	document.getElementById('stat-total-rx').textContent        = totalRx;
	document.getElementById('stat-delivery-ratio').textContent  = avgFanout !== '-' ? avgFanout + ' rx/tx' : '-';
	document.getElementById('stat-connected-ratio').textContent = connRatio + '%';
}

// This function is used to draw the whole map at the beginning, on which vehicles will be placed
// It expects as arguments the lat and lon value where the map should be centered
function draw_map(lat,lon,mapbox_token) {
	let standardlayer;

	// If no Mapbox token is specified, create a basic view layer based on OpenStreetMap (occasional use only! Heavy usage is forbidden!)
	if(mapbox_token == null) {
		standardlayer = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
			maxZoom: 30,
			attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors | <a href="https://www.openstreetmap.org/fixthemap">Report a problem in the map</a>',
			id: 'mapbox/streets-v11',
			// tileSize: 512,
			// zoomOffset: -1,
		});
	}

	// Create standard (street view), hybrid and satellite layers based on Mapbox
	// They are normally not enabled as you need an access token to use them
	let hybridlayer, satellitelayer;

	if(mapbox_token != null) {
		hybridlayer = L.tileLayer('https://api.mapbox.com/styles/v1/{id}/tiles/{z}/{x}/{y}?access_token=' + mapbox_token, {
			maxZoom: 30,
			attribution: '&copy; <a href="https://www.mapbox.com/about/maps/">Mapbox</a> | ms-van3t vehicle visualizer hybrid view',
			id: 'mapbox/satellite-streets-v11',
			tileSize: 512,
			zoomOffset: -1,
		});

		hybridlayer.setOpacity(0.7);

		satellitelayer = L.tileLayer('https://api.mapbox.com/styles/v1/{id}/tiles/{z}/{x}/{y}?access_token=' + mapbox_token, {
			maxZoom: 30,
			attribution: '&copy; <a href="https://www.mapbox.com/about/maps/">Mapbox</a> | ms-van3t vehicle visualizer satellite view',
			id: 'mapbox/satellite-v9',
			tileSize: 512,
			zoomOffset: -1,
		});

		satellitelayer.setOpacity(0.7);

		standardlayer = L.tileLayer('https://api.mapbox.com/styles/v1/{id}/tiles/{z}/{x}/{y}?access_token=' + mapbox_token, {
			maxZoom: 30,
			attribution: '&copy; <a href="https://www.mapbox.com/about/maps/">Mapbox</a> | ms-van3t vehicle visualizer streets view',
			id: 'mapbox/streets-v11',
			tileSize: 512,
			zoomOffset: -1,
		});
	}

	// Main map object creation (default layer: standardlayer, i.e. OpenStreetMap or Mapbox street view)
	// preferCanvas: true — use Canvas renderer instead of SVG; required for 1000+ polygon overlays
	var mymap = L.map('mapid', {
		center: [lat, lon],
		zoom: 17,
		layers: standardlayer,
		preferCanvas: true
	});

	// Add all the layers to the map, adding a control button to dynamically change the current map layer, if more than one layer can be used
	if (mapbox_token != null) {
		let basemaps = {
			"Street view": standardlayer,
			"Hybrid view": hybridlayer,
			"Satellite view": satellitelayer,
		};

		L.control.layers(basemaps).addTo(mymap);

		console.log("A Mapbox token has been specified. Multiple layers will be available.")
	}

	// Print on the console that the map has been successfully rendered
	console.log("VehicleVisualizer: Map Created!")

	return mymap;
}
