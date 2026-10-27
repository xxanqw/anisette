# Linux-only Swift + macOS CoreADI emulation. No Android runtime or code.
FROM rust:1-bookworm AS adi-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang cmake libclang-dev pkg-config make build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG ADI_REF=374d83854f657a7fdca45f813387d99d491db0e2
RUN git clone https://github.com/sacca97/os-findmy-e.git /opt/os-findmy-e \
    && cd /opt/os-findmy-e && git checkout "$ADI_REF"
WORKDIR /opt/os-findmy-e/native
RUN cargo build --release -p adi-core --lib

FROM swift:6.4.1-resolute AS swift-builder
COPY --from=adi-builder /opt/os-findmy-e/native/target/release/libadi_core.so /usr/local/lib/libadi_core.so
RUN ldconfig
WORKDIR /source
COPY Package.swift ./
COPY Sources Sources
COPY Tests Tests
RUN swift test -c release
RUN swift build -c release --product AnisetteServer

FROM swift:6.4.1-resolute
COPY --from=adi-builder /opt/os-findmy-e/native/target/release/libadi_core.so /usr/local/lib/libadi_core.so
COPY --from=swift-builder /source/.build/release/AnisetteServer /usr/local/bin/anisette-server
RUN ldconfig
USER 65532:65532
ENV PORT=6969 ANISETTE_COREADI_PATH=/data/CoreADI.x86_64
EXPOSE 6969
CMD ["/usr/local/bin/anisette-server"]
