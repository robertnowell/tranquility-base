# The hands-free manager as Pipecat Cloud (or any host) runs it: one session per
# instance, the app on the other end of one WebSocket (wire.py).
FROM dailyco/pipecat-base:latest
COPY requirements-hosted.txt /app/requirements-hosted.txt
RUN pip install --no-cache-dir -r /app/requirements-hosted.txt
COPY *.py /app/
ENV TB_HOSTED=1
