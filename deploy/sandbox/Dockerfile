# vibe-sandbox: the bot's computer. bash/python/node/chromium + browser.js. No secrets, no
# setuid binaries; the entrypoint just idles so sandbox-gateway can exec into it on demand.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl ca-certificates git jq \
        python3 python3-pip python3-venv \
        nodejs npm \
        chromium fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

RUN useradd --create-home --home-dir /home/agent --uid 1000 --shell /bin/bash agent

COPY package.json /opt/vibe/package.json
COPY browser.js /opt/vibe/browser.js
RUN cd /opt/vibe && npm install --omit=dev --no-audit --no-fund \
    && chown -R agent:agent /opt/vibe

# No setuid/setgid binaries anywhere: this image should never be able to escalate privilege.
RUN find / -xdev -perm -4000 -exec chmod u-s {} + 2>/dev/null || true \
    && find / -xdev -perm -2000 -exec chmod g-s {} + 2>/dev/null || true

USER agent
WORKDIR /home/agent
ENTRYPOINT ["sleep", "infinity"]
