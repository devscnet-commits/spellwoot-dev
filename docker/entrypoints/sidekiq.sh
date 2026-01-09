#!/bin/sh

set -x

# Clear Bootsnap cache to ensure fresh code is loaded
rm -rf /app/tmp/pids/server.pid
rm -rf /app/tmp/cache/*

echo "Waiting for redis to become ready...."
# Wait a bit for Redis to be ready (depends_on should handle this, but we wait a bit more)
echo "Waiting 20 seconds for Redis to be fully ready..."
sleep 20

echo "Installing gems..."

# Install missing gems for local dev as we are using base image compiled for production
bundle install

BUNDLE="bundle check"

until $BUNDLE
do
  sleep 2;
done

echo "Gems installed successfully!"
echo "Starting Sidekiq..."

# Execute the main process of the container
exec "$@"

