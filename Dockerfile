FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc \
    inotify-tools \
    python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN chmod +x /app/*.sh

EXPOSE 8000

CMD ["/app/docker-entrypoint.sh"]
