# The hands-free manager as Pipecat Cloud (or any host) runs it: one session per
# instance, the app on the other end of one WebSocket (wire.py).
FROM dailyco/pipecat-base:latest
COPY requirements-hosted.txt /app/requirements-hosted.txt
RUN pip install --no-cache-dir -r /app/requirements-hosted.txt
COPY *.py /app/
ENV TB_HOSTED=1
# Without this the bot gathers only the container's own address, answers with
# it, and nothing outside the cloud can reach it: two sessions in three hung
# for fifteen seconds and the third connected by luck (23 Sep). A failing
# answer was 3522 bytes, the working one 3893, and the difference was the
# candidate that STUN provides.
ENV PIPECAT_ICE_SERVERS=stun:stun.l.google.com:19302
