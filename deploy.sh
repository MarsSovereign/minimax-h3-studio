#!/usr/bin/env bash
# Deploy the MiniMax-H3 Studio server and/or web UI to a GPU machine over SSH.
#
#   ./deploy.sh          frontend + server (restarts the service)
#   ./deploy.sh web      frontend only (no restart; loaded weights stay warm)
#   ./deploy.sh server   server only (restarts the service)
#   ./deploy.sh models   download the checkpoints into $H3_COMFYUI/models on the GPU machine
#                        (extra arguments go to scripts/prepare_models.py, e.g. --skip ref2va)
#
# Settings come from .env (see .env.example); variables already set in the
# environment win over .env. A restart is refused while a job is running or
# queued; FORCE=1 overrides.
set -euo pipefail
cd "$(dirname "$0")"

TARGET=${1:-all}
case "$TARGET" in all|web|server|models) ;; *) echo "usage: $0 [all|web|server|models]" >&2; exit 2 ;; esac
[ $# -gt 0 ] && shift

if [ -f .env ]; then
  # Keep values that were set explicitly for this run.
  preset=$(env | grep -E '^H3_' || true)
  set -a; . ./.env; set +a
  while IFS= read -r line; do [ -n "$line" ] && export "$line"; done <<< "$preset"
fi

need() { [ -n "${!1:-}" ] || { echo "!! $1 is not set; copy .env.example to .env and fill it in" >&2; exit 2; }; }
need H3_DEPLOY_HOST

HOST=$H3_DEPLOY_HOST
PORT=${H3_PORT:-8190}
SERVICE=${H3_SERVICE:-h3-server}

remote() { ssh -o BatchMode=yes "$HOST" "$@"; }
health() { remote "curl -fsS --max-time 5 http://127.0.0.1:$PORT/api/health" 2>/dev/null || true; }

# Remote defaults depend on the SSH user's home directory.
REMOTE_HOME=$(remote 'printf %s "$HOME"')
REMOTE=${H3_DEPLOY_DIR:-$REMOTE_HOME/minimax-h3-studio}
# Jobs database and generated files; may live on another disk than the code.
DATA=${H3_DATA_DIR:-$REMOTE/data}

deploy_web() {
  echo "==> building web"
  (cd web && { [ -d node_modules ] || npm install --no-audit --no-fund; } && npm run build)
  echo "==> uploading web/dist"
  remote "rm -rf '$REMOTE/web_dist.new' && mkdir -p '$REMOTE'"
  scp -q -r web/dist "$HOST:$REMOTE/web_dist.new"
  # Swap in one step so the running server never serves a half-copied build.
  remote "cd '$REMOTE' && rm -rf web_dist.old && { [ ! -d web_dist ] || mv web_dist web_dist.old; } && mv web_dist.new web_dist && rm -rf web_dist.old"
}

render_unit() {
  local user=${H3_SERVICE_USER:-$(remote whoami)} activate python unit
  # Unset means the default flags; set-but-empty means none.
  local comfy_args=${H3_COMFY_ARGS-"--enable-triton-backend --use-sage-attention"}
  if [ -n "${H3_PYTHON:-}" ]; then
    activate="" python=$H3_PYTHON
  else
    activate="source ${H3_CONDA_SH:-$REMOTE_HOME/miniconda3/etc/profile.d/conda.sh} && conda activate ${H3_CONDA_ENV:-comfyui} && "
    python=python
  fi
  unit=$(<server/h3-server.service.in)
  unit=${unit//@USER@/$user}
  unit=${unit//@DIR@/$REMOTE}
  unit=${unit//@DATA@/$DATA}
  unit=${unit//@COMFYUI@/$H3_COMFYUI}
  unit=${unit//@AUDIOCPP_DIR@/${H3_AUDIOCPP_DIR:-}}
  unit=${unit//@AUDIOCPP_PORT@/${H3_AUDIOCPP_PORT:-8191}}
  unit=${unit//@AUDIOCPP_THREADS@/${H3_AUDIOCPP_THREADS:-8}}
  unit=${unit//@AUDIOCPP_INSTANCES@/${H3_AUDIOCPP_INSTANCES:-1}}
  unit=${unit//@AUDIOCPP_TIMEOUT@/${H3_AUDIOCPP_TIMEOUT:-1800}}
  unit=${unit//@STRATA_DIR@/${H3_STRATA_DIR:-}}
  unit=${unit//@STRATA_CONFIG@/${H3_STRATA_CONFIG:-}}
  unit=${unit//@STRATA_PORT@/${H3_STRATA_PORT:-8192}}
  unit=${unit//@STRATA_PARALLEL@/${H3_STRATA_PARALLEL:-8}}
  unit=${unit//@STRATA_CONCURRENCY@/${H3_STRATA_CONCURRENCY:-16}}
  unit=${unit//@STRATA_TIMEOUT@/${H3_STRATA_TIMEOUT:-1800}}
  unit=${unit//@HOST@/${H3_HOST:-0.0.0.0}}
  unit=${unit//@PORT@/$PORT}
  unit=${unit//@COMFY_ARGS@/$comfy_args}
  unit=${unit//@ACTIVATE@/$activate}
  unit=${unit//@PYTHON@/$python}
  printf '%s\n' "$unit"
}

deploy_server() {
  need H3_COMFYUI
  local status
  status=$(health)
  if [ -n "$status" ] && [ "${FORCE:-0}" != 1 ] && echo "$status" | grep -qE '"running": "[0-9a-f]+"|"queued": [1-9]'; then
    echo "!! jobs are running or queued: $status" >&2
    echo "!! a restart would drop them; rerun with FORCE=1 to restart anyway" >&2
    exit 1
  fi
  echo "==> syncing server code to $HOST:$REMOTE"
  remote "mkdir -p '$REMOTE/server' '$REMOTE/comfy_launcher' '$DATA'"
  rsync -az --delete --exclude __pycache__ --exclude .DS_Store server/ "$HOST:$REMOTE/server/"
  rsync -az comfy_launcher/run_h3.py "$HOST:$REMOTE/comfy_launcher/"
  rsync -az --delete --exclude .DS_Store scripts/ "$HOST:$REMOTE/scripts/"
  # Secrets stay out of the world-readable unit; systemd reads this file as root before dropping privileges.
  printf 'H3_API_TOKEN=%s\nH3_CORS_ORIGINS=%s\n' "${H3_API_TOKEN:-}" "${H3_CORS_ORIGINS:-}" \
    | remote "umask 077 && cat > '$REMOTE/server.env'"
  echo "==> installing systemd unit $SERVICE and restarting"
  render_unit | remote "sudo tee /etc/systemd/system/$SERVICE.service > /dev/null \
    && sudo systemctl daemon-reload && sudo systemctl enable --quiet $SERVICE && sudo systemctl restart $SERVICE"
  echo "==> waiting for the server"
  for _ in $(seq 1 90); do
    status=$(health)
    if echo "$status" | grep -q '"state": "ready"'; then echo "    ready: $status"; return; fi
    if echo "$status" | grep -q '"state": "error"'; then echo "!! engine failed to load: $status" >&2; exit 1; fi
    sleep 2
  done
  echo "!! server did not become ready; see: ssh $HOST journalctl -u $SERVICE -n 100" >&2
  exit 1
}

deploy_models() {
  need H3_COMFYUI
  echo "==> syncing the model list to $HOST:$REMOTE"
  remote "mkdir -p '$REMOTE/server' '$REMOTE/comfy_launcher' '$REMOTE/scripts'"
  rsync -az server/model_catalog.py server/image_models.py server/audio_catalog.py "$HOST:$REMOTE/server/"
  rsync -az scripts/prepare_models.py scripts/model_download.py scripts/prepare_audio_runtime.py "$HOST:$REMOTE/scripts/"
  echo "==> downloading into $H3_COMFYUI/models (rerun to resume if interrupted)"
  local args="" envs=""
  [ $# -eq 0 ] || args=$(printf ' %q' "$@")
  [ -z "${HF_ENDPOINT:-}" ] || envs+="HF_ENDPOINT=$(printf %q "$HF_ENDPOINT") "
  [ -z "${H3_AUDIOCPP_DIR:-}" ] || envs+="H3_AUDIOCPP_DIR=$(printf %q "$H3_AUDIOCPP_DIR") "
  [ -z "${HF_TOKEN:-}" ] || envs+="HF_TOKEN=$(printf %q "$HF_TOKEN") "
  ssh -t "$HOST" "${envs}python3 '$REMOTE/scripts/prepare_models.py' --comfyui '$H3_COMFYUI'$args"
}

if [ "$TARGET" = models ]; then deploy_models "$@"; exit; fi
[ "$TARGET" = server ] || deploy_web
[ "$TARGET" = web ] || deploy_server
echo "==> done: http://${HOST#*@}:$PORT"
