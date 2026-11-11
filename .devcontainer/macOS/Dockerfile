FROM mcr.microsoft.com/vscode/devcontainers/typescript-node:20
RUN arch=$(uname -m) && \
    if [ "$arch" != "x86_64" ]; then \
        arch="aarch64"; \
    fi && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "aws-cli.zip" && \
    unzip aws-cli.zip && \
    sudo ./aws/install && \
    rm -rf aws aws-cli.zip
USER node