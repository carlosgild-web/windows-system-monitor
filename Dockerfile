# Windows System Monitor: demo container.
#
# The real monitors are Windows PowerShell scripts and cannot run in a Linux container
# (see docs/docker.md). This image runs the real web console and settings editor with
# simulated monitors, so the project can be tried on any OS:
#
#   docker compose up --build        then open http://localhost:5758
#
# Standard library only: no pip install. Runs as a non-root user.
FROM python:3.15.0-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BIND_HOST=0.0.0.0 \
    NO_BROWSER=1 \
    DEMO_MODE=1

WORKDIR /app
RUN useradd --create-home --uid 10001 demo && mkdir -p /app/logs && chown demo:demo /app /app/logs

COPY --chown=demo:demo monitoring_settings.json server.py monitoring_editor.html ./
COPY --chown=demo:demo MonitoringConsole/monitoring_console.py MonitoringConsole/
COPY --chown=demo:demo web/ web/
COPY --chown=demo:demo sample_data/monthly_budget_sample.csv sample_data/
COPY --chown=demo:demo docker/simulator.py docker/run_demo.py docker/

USER demo
EXPOSE 5757 5758
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5758/api/status', timeout=2)"
CMD ["python", "docker/run_demo.py"]
