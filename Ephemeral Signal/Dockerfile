# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ---- Base + GUI + TigerVNC + noVNC + Electron deps + notifications ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    gnupg \
    dbus \
    dbus-x11 \
    dunst \
    openbox \
    wmctrl \
    novnc \
    websockify \
    python3 \
    tigervnc-standalone-server \
    tigervnc-common \
    xfonts-base \
    xauth \
    x11-xserver-utils \
    libasound2t64 \
    libnss3 \
    libxss1 \
    libatk-bridge2.0-0 \
    libgtk-3-0 \
    libdrm2 \
    libgbm1 \
    libx11-xcb1 \
    libxcb-dri3-0 \
    iproute2 \
    inotify-tools \
 && rm -rf /var/lib/apt/lists/*

# ---- Signal official APT repo (keyring + signed-by) ----
RUN mkdir -p /etc/apt/keyrings \
 && wget -qO- https://updates.signal.org/desktop/apt/keys.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/signal-desktop-keyring.gpg > /dev/null \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main" \
    > /etc/apt/sources.list.d/signal-xenial.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends signal-desktop \
 && rm -rf /var/lib/apt/lists/*

# ---- Non-root user ----
RUN useradd -m -s /bin/bash signal
USER signal
WORKDIR /home/signal

# ---- Runtime env ----
ENV DISPLAY=:1
ENV QT_X11_NO_MITSHM=1
ENV XDG_RUNTIME_DIR=/tmp/runtime-signal

EXPOSE 6080

# ---- Entrypoint ----
# - TigerVNC display :1 => TCP 5901
# - openbox with no decorations + maximize Signal
# - noVNC served on :6080
# - emits:
#     [activity] signal   (WAL burst heuristic)
#     [notify] signal     (Signal tries to send a desktop notification via org.freedesktop.Notifications.Notify)
CMD ["bash", "-lc", "\
  set -euo pipefail; \
  mkdir -p /tmp/runtime-signal /home/signal/.vnc; \
  : > /home/signal/.Xauthority; \
  \
  cat > /home/signal/.vnc/xstartup <<'EOF'\n\
#!/bin/sh\n\
unset SESSION_MANAGER\n\
unset DBUS_SESSION_BUS_ADDRESS\n\
\n\
# ---- Openbox config: no decorations for Signal ----\n\
mkdir -p \"$HOME/.config/openbox\"\n\
cat > \"$HOME/.config/openbox/rc.xml\" <<'XML'\n\
<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<openbox_config xmlns=\"http://openbox.org/3.4/rc\">\n\
  <applications>\n\
    <!-- Signal WM_CLASS tends to be \"signal.Signal\"; match common variants -->\n\
    <application class=\"signal.Signal\">\n\
      <decor>no</decor>\n\
      <maximized>true</maximized>\n\
    </application>\n\
    <application class=\"Signal\">\n\
      <decor>no</decor>\n\
      <maximized>true</maximized>\n\
    </application>\n\
    <application name=\"Signal\">\n\
      <decor>no</decor>\n\
      <maximized>true</maximized>\n\
    </application>\n\
  </applications>\n\
</openbox_config>\n\
XML\n\
\n\
openbox-session &\n\
\n\
# Fallback maximize (harmless if already maximized)\n\
(\n\
  for i in $(seq 1 120); do\n\
    if wmctrl -lx | grep -qi 'signal'; then\n\
      wid=\"$(wmctrl -lx | awk 'tolower($0) ~ /signal/ {print $1; exit}')\"\n\
      [ -n \"$wid\" ] && wmctrl -ir \"$wid\" -b add,maximized_vert,maximized_horz && exit 0\n\
    fi\n\
    sleep 0.25\n\
  done\n\
) &\n\
\n\
wait\n\
EOF\n\
  chmod +x /home/signal/.vnc/xstartup; \
  \
  vncserver -kill :1 >/dev/null 2>&1 || true; \
  rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; \
  \
  vncserver :1 -geometry 1280x800 -depth 24 -localhost no -SecurityTypes None --I-KNOW-THIS-IS-INSECURE; \
  \
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/ws-key.pem -out /tmp/ws-cert.pem \
    -days 1 -nodes -subj '/CN=localhost' 2>/dev/null; \
  websockify --cert=/tmp/ws-cert.pem --key=/tmp/ws-key.pem \
    --web=/usr/share/novnc/ 6080 localhost:5901 & \
  WSPID=$!; \
  \
  # ---- Shared DBus session for Signal + dunst + dbus-monitor ----\n\
  eval \"$(dbus-launch --sh-syntax)\"; \
  export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID; \
  \
  # Notification daemon (provides org.freedesktop.Notifications)\n\
  dunst >/dev/null 2>&1 & \
  DUNSTPID=$!; \
  \
  # Emit a marker whenever a notification is sent over DBus\n\
  ( \
    dbus-monitor --address \"$DBUS_SESSION_BUS_ADDRESS\" \
      \"type='method_call',interface='org.freedesktop.Notifications',member='Notify'\" 2>/dev/null \
    | grep --line-buffered \"member=Notify\" \
    | sed -u 's/.*/[notify] signal/' \
  ) & \
  MONPID=$!; \
  \
  # Start Signal (inherits DBus session)\n\
  signal-desktop --no-sandbox & \
  SIGPID=$!; \
  \
  # ---- Activity marker: WAL burst detector ----\n\
  # Emits a single line \"[activity] signal\" when db.sqlite-wal grows by >= MIN_GROW over a debounced burst.\n\
  # Tune MIN_GROW higher to reduce false positives.\n\
  ( \
    set -euo pipefail; \
    SQLDIR=\"$HOME/.config/Signal/sql\"; \
    WAL=\"$SQLDIR/db.sqlite-wal\"; \
    MIN_GROW=65536; \
    last_size=0; \
    [ -f \"$WAL\" ] && last_size=$(stat -c %s \"$WAL\" 2>/dev/null || echo 0); \
    while true; do \
      [ -f \"$WAL\" ] || { sleep 1; continue; }; \
      inotifywait -q -e modify \"$WAL\" >/dev/null 2>&1 || { sleep 1; continue; }; \
      # debounce: wait for burst to settle\n\
      sleep 1; \
      while inotifywait -q -t 1 -e modify \"$WAL\" >/dev/null 2>&1; do :; done; \
      size=$(stat -c %s \"$WAL\" 2>/dev/null || echo \"$last_size\"); \
      grow=$((size - last_size)); \
      last_size=\"$size\"; \
      if [ \"$grow\" -ge \"$MIN_GROW\" ]; then \
        echo \"[activity] signal\"; \
      fi; \
    done \
  ) & \
  ACTPID=$!; \
  \
  # ---- Watchdog: exit when noVNC has no clients for 10s ----\n\
  idle=0; \
  while kill -0 \"$SIGPID\" 2>/dev/null; do \
    conns=$(ss -Htn state established '( sport = :6080 )' 2>/dev/null | wc -l | tr -d ' '); \
    if [ \"${conns:-0}\" -gt 0 ]; then \
      idle=0; \
    else \
      idle=$((idle+1)); \
    fi; \
    if [ \"$idle\" -ge 10 ]; then \
      echo '[signal] no noVNC clients for 10s; shutting down'; \
      break; \
    fi; \
    sleep 1; \
  done; \
  \
  # Cleanup\n\
  kill \"$SIGPID\" 2>/dev/null || true; \
  kill \"$WSPID\" 2>/dev/null || true; \
  kill \"$ACTPID\" 2>/dev/null || true; \
  kill \"$MONPID\" 2>/dev/null || true; \
  kill \"$DUNSTPID\" 2>/dev/null || true; \
  vncserver -kill :1 >/dev/null 2>&1 || true; \
  exit 0 \
"]
