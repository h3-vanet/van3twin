#!/bin/bash
set -e

SUMO_FOLDER=${SUMO_FOLDER:-/sim/mappa}
SUMO_CONFIG=${SUMO_CONFIG:-/sim/mappa/sumo_cfg/combination_normale_50.sumo.cfg}
VEHICLE_VISUALIZER=${VEHICLE_VISUALIZER:-true}
SUMO_GUI=${SUMO_GUI:-false}
SUMO_UPDATES=${SUMO_UPDATES:-0.1}
PENETRATION_RATE=${PENETRATION_RATE:-1.0}
SIM_TIME=${SIM_TIME:-300}
CSV_LOG=${CSV_LOG:-/sim/logs/results}
MOB_TRACE=${MOB_TRACE:-normale.rou.xml}

ls /sim/mappa/sumo_cfg/

exec ./ns3 run "v2v-emergencyVehicleAlert-nrv2x" -- \
    --sumo-folder=${SUMO_FOLDER} \
    --sumo-config=${SUMO_CONFIG} \
    --mob-trace=${MOB_TRACE} \
    --vehicle-visualizer=${VEHICLE_VISUALIZER} \
    --sumo-gui=${SUMO_GUI} \
    --sumo-updates=${SUMO_UPDATES} \
    --penetrationRate=${PENETRATION_RATE} \
    --simTime=${SIM_TIME} \
    --csv-log=${CSV_LOG}
