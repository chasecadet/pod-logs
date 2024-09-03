# Use a Debian base image
FROM debian:latest

# Install necessary tools and kubectl
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    dnsutils \
    mariadb-client \
    apt-transport-https \
    gnupg2 \
    lsb-release \
    && curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - \
    && echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y kubectl \
    && rm -rf /var/lib/apt/lists/*

# Copy the script into the container
COPY gather-logs.sh /usr/local/bin/gather-logs.sh

# Make the script executable
RUN chmod +x /usr/local/bin/gather-logs.sh

# Set the entrypoint to the script
ENTRYPOINT ["/usr/local/bin/gather-logs.sh"]
