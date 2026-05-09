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
# sandbox_builder.sh uses the CTTC GitLab fork (not github.com/h3-vanet), so
# we clone it directly here.  Using --depth=1 on the target branch avoids
# pulling the full history.
WORKDIR /build
RUN git clone --depth=1 -b ns-3-dev-v2x-v0.2 \
        https://gitlab.com/cttc-lena/ns-3-dev.git

# Add the NR V2X module (sandbox_builder.sh lines 118-127)
RUN git clone --depth=1 -b nr-v2x-dev \
        https://gitlab.com/cttc-lena/nr.git \
        /build/ns-3-dev/src/nr \
    && find /build/ns-3-dev/src/nr -name '.git*' -exec rm -rf {} + 2>/dev/null \
    || true

# ── Merge VaN3Twin custom modules ─────────────────────────────────────────────
# Clone VaN3Twin so the Dockerfile is self-contained and works regardless of
# where "docker build" is invoked.  Override VAN3TWIN_REF to pin a specific
# branch or tag (e.g. --build-arg VAN3TWIN_REF=my-branch).
# Default to the fix branch until this PR is merged into master.
# After merge, change back to: ARG VAN3TWIN_REF=master
ARG VAN3TWIN_REF=master
RUN git clone --depth=1 -b ${VAN3TWIN_REF} \
        https://github.com/h3-vanet/VaN3Twin.git /van3twin \
    && cp -rf /van3twin/src/. /build/ns-3-dev/src/ \
    && rm -rf /van3twin

WORKDIR /build/ns-3-dev

# ── Apply patches from sandbox_builder.sh ────────────────────────────────────

# Patch CMakeLists.txt: add C language support alongside C++ (line 152)
RUN sed -i -E 's#^([[:blank:]]*)project\(NS3 CXX\)#\1project\(NS3 C CXX\)#' \
        CMakeLists.txt

# Propagation-extended models (lines 166-168, fixing the corrupted path in
# the original script where a URL was accidentally embedded in the cp target)
RUN cp src/automotive/propagation-extended/cni-urbanmicrocell-propagation-loss-model.cc \
          src/propagation/model/ \
    && cp src/automotive/propagation-extended/cni-urbanmicrocell-propagation-loss-model.h \
          src/propagation/model/ \
    && cp src/automotive/propagation-extended/CMakeLists.txt \
          src/propagation/

# TxTracker: patched WiFi PHY header (line 182)
RUN cp src/automotive/model/TxTracker/channel_files/modified/yans-wifi-phy.h \
          src/wifi/model/

# SignalInfo tags for all four radio stacks (lines 186-225)
RUN for tag in rssi-tag sinr-tag rsrp-tag timestamp-tag size-tag; do \
        for stack in wifi/model cv2x/model nr/model lte/model; do \
            cp src/automotive/model/SignalInfo/${tag}.cc src/${stack}/ && \
            cp src/automotive/model/SignalInfo/${tag}.h  src/${stack}/; \
        done; \
    done

# WiFi SignalInfo overrides (lines 227-231)
RUN cp src/automotive/model/SignalInfo/WiFi/wifi-mac-queue-item.h      src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/ocb-wifi-mac.cc         src/wave/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/frame-exchange-manager.cc    src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/qos-frame-exchange-manager.cc src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/CMakeLists.txt          src/wifi/

# CV2X SignalInfo overrides (lines 233-237)
RUN cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-spectrum-phy.cc src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-spectrum-phy.h  src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-ue-mac.h        src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-ue-mac.cc       src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/CMakeLists.txt           src/cv2x/

# NR SignalInfo overrides (lines 239-242)
RUN cp src/automotive/model/SignalInfo/NR/nr-spectrum-phy.cc src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/nr-spectrum-phy.h  src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/nr-ue-phy.cc       src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/CMakeLists.txt     src/nr/

# LTE SignalInfo overrides (lines 244-247)
RUN cp src/automotive/model/SignalInfo/LTE/lte-spectrum-phy.cc src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/lte-ue-phy.cc    src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/lte-ue-phy.h     src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/CMakeLists.txt   src/lte/

# ── Configure & build ─────────────────────────────────────────────────────────
# --disable-tests and --disable-python trim a large portion of the build.
# carla/sionna modules are not present in this tree so no need to list them.
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
# "./ns3 run" always calls "cmake -S . -B cmake-cache" before running, which
# requires VERSION, build-support/ and all CMakeLists.txt / *.cmake files.
# We tar only those files (no .cc/.h) to keep the runtime image small.
RUN find /build/ns-3-dev \
        \( -name "CMakeLists.txt" -o -name "*.cmake" \) \
        -not -path "*/cmake-cache/*" \
    | tar cf /cmake-source.tar -T - \
    && tar rf /cmake-source.tar \
        -C /build/ns-3-dev VERSION build-support

# ── Runtime ───────────────────────────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs + cmake/ninja so that "./ns3 run" can locate the build
# and execute pre-built scenarios without recompiling.
# gcc/g++ are required because cmake runs compiler feature tests during the
# reconfigure that "./ns3 run" always triggers before executing a scenario.
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

# Compiled artifacts: keep the same /build/ns-3-dev path as the builder so
# all hardcoded paths inside CMakeCache.txt remain valid.
COPY --from=builder /build/ns-3-dev/build        /build/ns-3-dev/build
COPY --from=builder /build/ns-3-dev/cmake-cache  /build/ns-3-dev/cmake-cache
COPY --from=builder /build/ns-3-dev/ns3          /build/ns-3-dev/ns3
# cmake source structure: VERSION + build-support/ + all CMakeLists.txt/.cmake
# files needed for the reconfigure step that "./ns3 run" always performs.
COPY --from=builder /cmake-source.tar /
RUN tar xf /cmake-source.tar -C /build/ns-3-dev && rm /cmake-source.tar

WORKDIR /build/ns-3-dev

ENV LD_LIBRARY_PATH=/build/ns-3-dev/build/lib
