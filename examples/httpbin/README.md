# Dusty httpbin

This example is an HTTP-only, httpbin-compatible service intended to run behind a TLS-terminating reverse proxy.

## Build the image

Build a static release binary for the architecture on which the container will run, then build the runtime-only image:

```sh
cd examples/httpbin
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl -Duse_tls=false --prefix zig-out/container
docker build -t dusty-httpbin:0.3.1 .
```

Use `aarch64-linux-musl` instead of `x86_64-linux-musl` for a 64-bit ARM host. The resulting image contains only the static executable, runs as user/group `65532`, listens on port 8080, and has no shell or TLS stack.

CI publishes the tested `linux/amd64` image from `main` as:

```sh
docker pull ghcr.io/lalinsky/dusty-httpbin:latest
```

Release tags also produce full and major/minor version tags, such as `0.4.0` and `0.4`.

## Run behind a proxy

When the reverse proxy runs directly on the Docker host, publish the service only on loopback:

```sh
docker run -d \
  --name dusty-httpbin \
  --restart unless-stopped \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --memory 256m \
  --cpus 1 \
  -p 127.0.0.1:8080:8080 \
  dusty-httpbin:0.3.1 \
  -l 0.0.0.0:8080 --trusted-proxy-hops 1
```

Use `GET /status/204` as a health check. A minimal nginx upstream configuration is:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Connection "";
}
```

If the proxy is another container, attach both containers to a private Docker network and do not publish port 8080 on the host.

`--trusted-proxy-hops 1` tells Dusty that the directly connected nginx is trusted, so `/ip` and the reflected `origin` use the rightmost address in `X-Forwarded-For`. Set it to `2` when two trusted proxies sit in front of the application, and so on; Dusty selects the corresponding address from the right, ignoring any extra values a client prepended. A missing, too-short, or malformed chain falls back to the socket peer.

Do not enable proxy trust if clients can reach the application port directly. The hop count is safe only when every path to the application passes through exactly that many trusted proxies. Add rate limits and request-size limits at the proxy before exposing a public instance.
