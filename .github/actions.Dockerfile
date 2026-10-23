FROM alpine:3.20
RUN apk add --no-cache bash openssh-client tar python3 py3-yaml
ARG USER_ID=1001
RUN adduser -D -u "$USER_ID" actionrunner
ENV PYTHONDONTWRITEBYTECODE=1 HOME=/home/actionrunner
USER actionrunner
ENTRYPOINT ["python3", "/action/.github/scripts/action.py"]
