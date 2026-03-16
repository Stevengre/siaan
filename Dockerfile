FROM hexpm/elixir:1.19.5-erlang-28.3-debian-bookworm-20260202-slim AS base

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      make \
      ruby \
      ca-certificates \
      curl \
      gpg \
      openssh-client \
      nodejs \
      npm && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI from the official apt repository.
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Install mise for repo-local toolchain workflows.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Install codex CLI
RUN npm install -g @openai/codex@latest

WORKDIR /app

# ---------- deps stage (cached) ----------
FROM base AS deps

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get

# ---------- build stage ----------
FROM deps AS build

COPY elixir/ ./
RUN mix setup && mix build

# ---------- runtime stage ----------
FROM base AS runtime

WORKDIR /app
COPY --from=build /app/bin/siaan ./bin/siaan
COPY --from=build /app/_build ./_build
COPY --from=build /app/deps ./deps
COPY --from=build /app/lib ./lib
COPY --from=build /app/mix.exs ./mix.exs
COPY --from=build /root/.mix /root/.mix
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/workspaces"]
EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--help"]
