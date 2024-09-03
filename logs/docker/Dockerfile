# Use a Debian base image
FROM debian:latest

# Install necessary tools 
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    dnsutils \
    mariadb-client \
    apt-transport-https \
    gnupg2 \
    lsb-release 

# Install Kubectl 
RUN curl -kLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" 
RUN  chmod +x kubectl 
RUN  mkdir -p ~/.local/bin \
&& mv ./kubectl ~/.local/bin/kubectl 
# Adding to my env variable
ENV PATH="$HOME/.local/bin:$PATH" 


RUN kubectl version --client

# Copy the script into the container
COPY gather-logs.sh /usr/local/bin/gather-logs.sh

# Make the script executable
RUN chmod +x /usr/local/bin/gather-logs.sh

# Set the entrypoint to the script
ENTRYPOINT ["/usr/local/bin/gather-logs.sh"]
