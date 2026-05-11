# syntax=docker/dockerfile:1.6
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/keda-deprecation-webhook ./cmd/keda-deprecation-webhook

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/keda-deprecation-webhook /keda-deprecation-webhook
USER 65532:65532
ENTRYPOINT ["/keda-deprecation-webhook"]
