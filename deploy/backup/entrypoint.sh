#!/bin/sh
# Renders rclone's R2 config from env (compose can't template secrets into a
# mounted file), installs the cron schedule, then runs cron in the foreground.
set -eu

mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<-EOF
	[r2]
	type = s3
	provider = Cloudflare
	access_key_id = ${BACKUP_R2_ACCESS_KEY_ID}
	secret_access_key = ${BACKUP_R2_SECRET_ACCESS_KEY}
	endpoint = https://${BACKUP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com
	acl = private
EOF
chmod 600 /root/.config/rclone/rclone.conf

crontab /etc/crontabs/root
exec crond -f -l 2
