# Build Ship Run

Explore [Dockerfile](./Dockerfile)

## Build Container

```bash
podman build -t quay.io/jwerak/hello-web .
```

## Push Container

```bash
podman push quay.io/jwerak/hello-web
```

## Run Container Anywhere

```bash
podman run --name hello-web -d -p 8080:80 quay.io/jwerak/hello-web
```

visit http://localhost:8080
