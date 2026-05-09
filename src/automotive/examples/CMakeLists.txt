build_lib_example(
    NAME v2v-emergencyVehicleAlert-nrv2x
    SOURCE_FILES v2v-emergencyVehicleAlert-nrv2x.cc
    LIBRARIES_TO_LINK
    ${libautomotive}
    ${libnr}
    ${libtraci}
)
