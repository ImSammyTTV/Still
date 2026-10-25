FROM python:3.13-slim
WORKDIR /app
COPY server.py ./
COPY static ./static
RUN useradd --system --uid 10001 still && mkdir /data && chown still /data
USER still
VOLUME /data
EXPOSE 7843
CMD ["python3", "server.py", "--host", "0.0.0.0", "--port", "7843", "--data", "/data"]
