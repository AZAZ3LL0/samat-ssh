# Image for integration tests: the agent in --fake mode, no root services needed.
# Build context is the agent/ directory.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -o /out/pulse-agent ./cmd/pulse-agent

FROM scratch
COPY --from=build /out/pulse-agent /usr/local/bin/pulse-agent
COPY config.example.yaml /etc/pulse-agent/config.yaml
EXPOSE 7443
ENTRYPOINT ["/usr/local/bin/pulse-agent"]
CMD ["--fake", "serve"]
