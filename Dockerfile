FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

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
        sumo \
    && rm -rf /var/lib/apt/lists/*

# ── Clone upstream ns-3 ───────────────────────────────────────────────────────
WORKDIR /build
RUN git clone --depth=1 -b ns-3-dev-v2x-v0.2 \
        https://gitlab.com/cttc-lena/ns-3-dev.git

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

# ── Apply patches ─────────────────────────────────────────────────────────────
RUN sed -i -E 's#^([[:blank:]]*)project\(NS3 CXX\)#\1project\(NS3 C CXX\)#' \
        CMakeLists.txt

RUN cp src/automotive/propagation-extended/cni-urbanmicrocell-propagation-loss-model.cc \
          src/propagation/model/ \
    && cp src/automotive/propagation-extended/cni-urbanmicrocell-propagation-loss-model.h \
          src/propagation/model/ \
    && cp src/automotive/propagation-extended/CMakeLists.txt \
          src/propagation/

RUN cp src/automotive/model/TxTracker/channel_files/modified/yans-wifi-phy.h \
          src/wifi/model/

RUN for tag in rssi-tag sinr-tag rsrp-tag timestamp-tag size-tag; do \
        for stack in wifi/model cv2x/model nr/model lte/model; do \
            cp src/automotive/model/SignalInfo/${tag}.cc src/${stack}/ && \
            cp src/automotive/model/SignalInfo/${tag}.h  src/${stack}/; \
        done; \
    done

RUN cp src/automotive/model/SignalInfo/WiFi/wifi-mac-queue-item.h      src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/ocb-wifi-mac.cc         src/wave/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/frame-exchange-manager.cc    src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/qos-frame-exchange-manager.cc src/wifi/model/ \
    && cp src/automotive/model/SignalInfo/WiFi/CMakeLists.txt          src/wifi/

RUN cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-spectrum-phy.cc src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-spectrum-phy.h  src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-ue-mac.h        src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/cv2x_lte-ue-mac.cc       src/cv2x/model/ \
    && cp src/automotive/model/SignalInfo/CV2X/CMakeLists.txt           src/cv2x/

RUN cp src/automotive/model/SignalInfo/NR/nr-spectrum-phy.cc src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/nr-spectrum-phy.h  src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/nr-ue-phy.cc       src/nr/model/ \
    && cp src/automotive/model/SignalInfo/NR/CMakeLists.txt     src/nr/

RUN cp src/automotive/model/SignalInfo/LTE/lte-spectrum-phy.cc src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/lte-ue-phy.cc    src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/lte-ue-phy.h     src/lte/model/ \
    && cp src/automotive/model/SignalInfo/LTE/CMakeLists.txt   src/lte/

# ── Configure & build ─────────────────────────────────────────────────────────
RUN ./ns3 configure \
        --build-profile=optimized \
        --disable-tests \
        --disable-python \
        --enable-examples \
        --disable-modules=wimax,mesh,dsr,dsdv,uan,lr-wpan,brite,click,openflow

RUN ./ns3 build -j"$(nproc)"

RUN find build -type f \( -name "*.so" -o -executable \) ! -name "*.py" \
        -exec strip --strip-unneeded {} \; 2>/dev/null || true

# ── Runner: builder image is the final image ──────────────────────────────────
FROM builder AS runner

WORKDIR /build/ns-3-dev
ENV LD_LIBRARY_PATH=/build/ns-3-dev/build/lib
