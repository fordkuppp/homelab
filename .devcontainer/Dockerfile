FROM mcr.microsoft.com/devcontainers/python:3.14

# Install OpenTofu
RUN curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh \
    && chmod +x install-opentofu.sh \
    && ./install-opentofu.sh --install-method deb \
    && rm -f install-opentofu.sh

# Install uv and ty
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
RUN uv tool install ty@latest

