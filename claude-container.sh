#!/bin/bash

set -ex

DIR="$(dirname "$0")"
cd "$DIR"

TAG="rv-tests-claude-container"
CONTAINER_NAME="rv-tests-claude-container"

if docker container inspect "$CONTAINER_NAME" &> /dev/null; then
    docker start -ti "$CONTAINER_NAME"
else
  docker build \
    --progress=plain \
    --build-arg "USERNAME=$(whoami)" \
    --build-arg "UID=$(id -u)" \
    --build-arg "GID=$(id -g)" \
    -f claude-container.Dockerfile \
    . \
    -t "$TAG"

  docker run -ti -v "$DIR:/src" --name "$CONTAINER_NAME" "$CONTAINER_NAME"
fi
