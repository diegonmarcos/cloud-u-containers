#!/bin/sh
# Mattermost runs as uid 2000 inside the container
MM_UID=2000
MM_GID=2000
for dir in data/mattermost/config data/mattermost/data data/mattermost/logs data/mattermost/plugins data/mattermost/client-plugins data/postgres; do
  mkdir -p "$dir"
done
sudo chown -R $MM_UID:$MM_GID data/mattermost
