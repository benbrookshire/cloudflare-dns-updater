ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache bash curl jq

COPY ddns.sh /usr/bin/ddns.sh
COPY run.sh /run.sh
RUN chmod a+x /usr/bin/ddns.sh /run.sh

CMD [ "/run.sh" ]
