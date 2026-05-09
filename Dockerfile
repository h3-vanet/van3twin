# ── Builder ───────────────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Minimal build deps.
# Removed vs the original Dockerfile: conan, pip, gRPC dev libs, Qt5, valgrind,
#   clang-format, doxygen, graphviz, gir/gtk, mercurial, lsb-release.
# Added vs the original: libgsl-dev, libsqlite3-dev, libxml2-dev, libssl-dev
#   (all required by ns-3 core and the automotive module).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        git \
        ccache \
        python3 \
        pkg-config \
        ca-certificates \
        libgsl-dev \
        libgslcblas0 \
        libsqlite3-dev \
        libxml2-dev \
        libssl-dev \
        libboost-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Clone upstream ns-3 ───────────────────────────────────────────────────────
WORKDIR /build
RUN git clone --depth=1 -b ns-3-dev-v2x-v0.2 \
        https://gitlab.com/cttc-lena/ns-3-dev.git

# Add the NR V2X module
RUN git clone --depth=1 -b nr-v2x-dev \
        https://gitlab.com/cttc-lena/nr.git \
        /build/ns-3-dev/src/nr \
    && find /build/ns-3-dev/src/nr -name '.git*' -exec rm -rf {} + 2>/dev/null \
    || true

# ── Merge VaN3Twin custom modules ─────────────────────────────────────────────
ARG VAN3TWIN_REF=master
RUN git clone --depth=1 -b ${VAN3TWIN_REF} \
        https://github.com/h3-vanet/VaN3Twin.git /van3twin \
    && cp -rf /van3twin/src/. /build/ns-3-dev/src/ \
    && cp /van3twin/docker/ns3-wrapper /ns3-wrapper \
    && rm -rf /van3twin

WORKDIR /build/ns-3-dev

# ── Apply patches from sandbox_builder.sh ────────────────────────────────────

# Patch CMakeLists.txt: add C language support alongside C++
RUN sed -i -E 's#^([[:blank:]]*)project\(NS3 CXX\)#\1project\(NS3 C CXX\)#' \
        CMakeLists.txt

# Propagation-extended models
RUN cp src/automotive/propagation-extended/cni-urbanmicrocell-propagation-loss-model.cc \
          src/propagation/model/ \
    && cp src/automotive/propagation-extended/cni-urbanmicrocell-propagation-loss-model.h \
          src/propagation/model/ \
    && cp src/automotive/propagation-extended/CMakeLists.txt \
          src/propagation/

# TxTracker: patched WiFi PHY header
RUN cp src/automotive/model/TxTracker/channel_files/modified/yans-wifi-phy.h \
          src/wifi/model/

# SignalInfo tags for all four radio stacks
RUN for tag in rssi-tag sinr-tag rsrp-tag timestamp-tag size-tag; do \
        for stack in wifi/model cv2x/model nr/model lte/model; do \
            cp src/automotive/model/SignalInfo/${tag}.cc src/${stack}/ && \
            cp src/automotive/model/SignalInfo/${tag}.h  src/${stack}/; \
        done; \
    done

# WiFi SignalInfo overrides
RUN cp src/automotive/model/SignalInfo/WiFi/wifi-mac-queue-item.h      src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/ocb-wifi-mac.cc         src/wave/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/frame-exchange-manager.cc    src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/qos-frame-exchange-manager.cc src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/CMakeLists.txt          src/wifi/

# CV2X SignalInfo overrides
RUN cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-spectrum-phy.cc src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-spectrum-phy.h  src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-ue-mac.h        src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-ue-mac.cc       src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/CMakeLists.txt           src/cv2x/

# NR SignalInfo overrides
RUN cp src/automotive/model/SignalInfo/NR/nr-spectrum-phy.cc src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/nr-spectrum-phy.h  src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/nr-ue-phy.cc       src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/CMakeLists.txt     src/nr/

# LTE SignalInfo overrides
RUN cp src/automotive/model/SignalInfo/LTE/lte-spectrum-phy.cc src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/lte-ue-phy.cc    src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/lte-ue-phy.h     src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/CMakeLists.txt   src/lte/

# Fix ns3 script bug: args.run_verbose was renamed to args.orig_verbose
RUN sed -i 's/args\.run_verbose/args.orig_verbose/g' ns3

# ── Configure & build ─────────────────────────────────────────────────────────
RUN ./ns3 configure \
        --build-profile=optimized \
        --disable-tests \
        --disable-python \
        --enable-examples

RUN ./ns3 build -j"$(nproc)"

# Strip debug symbols to reduce image size
RUN find build -type f \( -name "*.so" -o -executable \) ! -name "*.py" \
        -exec strip --strip-unneeded {} \; 2>/dev/null || true

# ── Runtime ───────────────────────────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs only — no compiler needed because ./ns3 run is wrapped to
# execute pre-built binaries directly without invoking cmake.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgsl27 \
        libgslcblas0 \
        libssl3 \
        libsqlite3-0 \
        libxml2 \
        python3 \
        sumo \
    && rm -rf /var/lib/apt/lists/*

# Compiled artifacts at the same path used during build so LD_LIBRARY_PATH
# and any hardcoded RPATH entries remain valid.
COPY --from=builder /build/ns-3-dev/build /build/ns-3-dev/build

# SUMO scenario data files (XML route/network/config files).
# ns-3 examples reference these with relative paths from /build/ns-3-dev,
# e.g. "src/automotive/examples/sumo_files_v2v_map/cars_7.rou.xml".
COPY --from=builder /build/ns-3-dev/src/automotive/examples /build/ns-3-dev/src/automotive/examples

# The lock file maps short scenario names to full binary paths.
# With --no-build the original ns3 script reads only this file — no cmake.
COPY --from=builder /build/ns-3-dev/.lock-ns3_linux_build /build/ns-3-dev/.lock-ns3_linux_build

# Wrapper: injects --no-build into "run" so the original ns3 script skips
# cmake entirely.  All other subcommands and flags pass through unchanged.
COPY --from=builder /build/ns-3-dev/ns3  /build/ns-3-dev/ns3.orig
COPY --from=builder /ns3-wrapper          /build/ns-3-dev/ns3
RUN chmod +x /build/ns-3-dev/ns3

WORKDIR /build/ns-3-dev

ENV LD_LIBRARY_PATH=/build/ns-3-dev/build/lib
