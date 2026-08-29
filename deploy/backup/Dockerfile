# Encrypted off-site backups: pg_dump -> age -> rclone to R2, every 6h via cron.
FROM alpine:3.19

# postgresql16-client must match the postgres:16-alpine server version used in
# compose.yml (pg_dump/pg_restore version skew is best avoided).
RUN apk add --no-cache postgresql16-client rclone age ca-certificates tzdata

WORKDIR /app
COPY backup.sh entrypoint.sh ./
COPY crontab /etc/crontabs/root
RUN chmod +x backup.sh entrypoint.sh && chmod 600 /etc/crontabs/root

ENTRYPOINT ["/app/entrypoint.sh"]
