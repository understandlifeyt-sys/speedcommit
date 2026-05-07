FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Allow git operations in /tmp clones
RUN git config --global --add safe.directory '*'

WORKDIR /app
COPY speedcommit.sh .
RUN chmod +x speedcommit.sh

CMD ["./speedcommit.sh"]
