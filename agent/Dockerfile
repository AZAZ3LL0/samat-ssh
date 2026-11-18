# Image for integration tests: the agent in --fake mode, no root services needed.
# Build context is the repository root, so the image can carry fixtures/.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY agent/ .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -o /out/pulse-agent ./cmd/pulse-agent

FROM scratch
COPY --from=build /out/pulse-agent /usr/local/bin/pulse-agent
COPY agent/config.example.yaml /etc/pulse-agent/config.yaml
COPY fixtures/ /usr/share/pulse-agent/fixtures/
EXPOSE 7443
ENTRYPOINT ["/usr/local/bin/pulse-agent"]
CMD ["--fake", "--fixtures", "/usr/share/pulse-agent/fixtures", "serve"]
