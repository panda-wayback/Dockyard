FROM python:3.12-alpine

RUN sed -i 's#https\?://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories \
    && apk add --no-cache docker-cli

COPY server.py /app/server.py

EXPOSE 8080

CMD ["python", "/app/server.py"]
