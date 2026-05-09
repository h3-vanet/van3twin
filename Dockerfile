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
ARG VAN3TWIN_REF=claude/docker-build-fix
RUN git clone --depth=1 -b ${VAN3TWIN_REF} \
        https://github.com/h3-vanet/VaN3Twin.git /van3twin \
    && cp -rf /van3twin/src/. /build/ns-3-dev/src/ \
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

# Pack the cmake source structure needed by "./ns3 run" at runtime.
# "./ns3 run" always calls "cmake --build cmake-cache" which checks whether
# CMakeLists.txt files changed; without them cmake aborts.
# We tar only cmake files (no .cc/.h) to keep the runtime image small.
RUN cd /build/ns-3-dev && \
    find . \( -name "CMakeLists.txt" -o -name "*.cmake" \) \
        -not -path "*/cmake-cache/*" \
    | tar cf /cmake-source.tar -T - && \
    tar rf /cmake-source.tar VERSION build-support

# ── Runtime ───────────────────────────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs + cmake/ninja/gcc/g++ so that "./ns3 run" can invoke cmake
# --build without recompiling (binaries already exist, ninja is a no-op).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgsl27 \
        libgslcblas0 \
        libssl3 \
        libsqlite3-0 \
        libxml2 \
        python3 \
        cmake \
        ninja-build \
        gcc \
        g++ \
        sumo \
    && rm -rf /var/lib/apt/lists/*

# Compiled artifacts at the same path used during build so LD_LIBRARY_PATH
# and any hardcoded RPATH entries remain valid.
COPY --from=builder /build/ns-3-dev/build        /build/ns-3-dev/build
COPY --from=builder /build/ns-3-dev/cmake-cache  /build/ns-3-dev/cmake-cache

# The lock file is what tells ./ns3 run that a build already exists and where
# to find the binaries. Without it, ns3 refuses to run and asks to configure.
COPY --from=builder /build/ns-3-dev/.lock-ns3_linux_build /build/ns-3-dev/.lock-ns3_linux_build

# SUMO scenario data files referenced with relative paths from /build/ns-3-dev.
COPY --from=builder /build/ns-3-dev/src/automotive/examples /build/ns-3-dev/src/automotive/examples

# ns3 Python script.
COPY --from=builder /build/ns-3-dev/ns3 /build/ns-3-dev/ns3

# cmake source files (CMakeLists.txt / *.cmake / VERSION / build-support/).
# Timestamps are set to a fixed past date so cmake --build never sees them
# as newer than the cmake-cache and skips reconfiguration entirely.
COPY --from=builder /cmake-source.tar /
RUN tar xf /cmake-source.tar -C /build/ns-3-dev && rm /cmake-source.tar \
    && find /build/ns-3-dev \( -name "CMakeLists.txt" -o -name "*.cmake" -o -name "VERSION" \) \
        -not -path "*/cmake-cache/*" -exec touch -t 200001010000 {} +

# FindBoost.cmake reads boost/version.hpp to detect the version.
COPY --from=builder /usr/include/boost/version.hpp /usr/include/boost/version.hpp

WORKDIR /build/ns-3-dev

ENV LD_LIBRARY_PATH=/build/ns-3-dev/build/lib
