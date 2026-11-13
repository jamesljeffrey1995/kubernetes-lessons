# syntax=docker/dockerfile:1
# ---- build stage: compile a static Go binary ----
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
COPY static ./static
ARG VERSION=dev
# CGO off = fully static binary that runs on a minimal base image
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /pulse .

# ---- run stage: distroless = no shell, no package manager, runs as non-root ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /pulse /pulse
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/pulse"]
