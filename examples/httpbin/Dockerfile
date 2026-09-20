FROM scratch

LABEL org.opencontainers.image.title="Dusty httpbin"
LABEL org.opencontainers.image.description="HTTP-only httpbin-compatible service built with Dusty"
LABEL org.opencontainers.image.source="https://github.com/lalinsky/dusty"
LABEL org.opencontainers.image.licenses="MIT"

COPY zig-out/container/bin/server /httpbin

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/httpbin"]
CMD ["-l", "0.0.0.0:8080"]
