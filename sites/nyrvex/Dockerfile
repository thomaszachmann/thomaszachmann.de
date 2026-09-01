# syntax=docker/dockerfile:1

# nginx-unprivileged statt nginx: laeuft durchgehend als UID 101 und startet
# nie als root. Erst das macht runAsNonRoot + readOnlyRootFilesystem moeglich.
# Der Master-Prozess dieses Images legt seine PID unter /tmp ab, nicht /run.
FROM nginxinc/nginx-unprivileged:1.31.4-alpine

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 public/ /usr/share/nginx/html/

EXPOSE 8080
