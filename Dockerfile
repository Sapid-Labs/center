FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.9.16 /uv /usr/local/bin/uv
WORKDIR /app
COPY server/ .
RUN uv sync --no-dev --frozen
ENV CENTER_DATA=/data
VOLUME /data
EXPOSE 8110
CMD ["uv", "run", "--no-dev", "center", "serve", "--port", "8110"]
