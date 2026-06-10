# ---- build stage ----
FROM golang:1.25-alpine AS build

WORKDIR /src

# Cache deps first: only re-runs if go.mod/go.sum change
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o /bin/backend .

# ---- run stage ----
FROM gcr.io/distroless/static-debian12

COPY --from=build /bin/backend /backend

EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/backend"]
