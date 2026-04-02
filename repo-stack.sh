#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/install.yml"
VARS_FILE="${SCRIPT_DIR}/vars.yaml"
INVENTORY="localhost,"
CONNECTION="local"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  install       Install the offline-repo-stack
  uninstall     Tear down containers, config, and service accounts
  start         Start the docker compose stack
  stop          Stop the docker compose stack
  restart       Restart the docker compose stack
  status        Show container status
  provision     Re-run the Nexus repository provisioner
  logs          Tail container logs (pass container name to filter)

Options:
  -i INVENTORY  Ansible inventory (default: localhost)
  -c CONNECTION Ansible connection type (default: local)
  -v            Verbose ansible output
  -h            Show this help

Examples:
  $(basename "$0") install
  $(basename "$0") install -v
  $(basename "$0") install -i hosts.ini -c ssh
  $(basename "$0") uninstall
  $(basename "$0") logs nginx-proxy
EOF
    exit "${1:-0}"
}

# -- Parse global options after the command --
ANSIBLE_EXTRA_ARGS=()

parse_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) INVENTORY="$2"; shift 2 ;;
            -c) CONNECTION="$2"; shift 2 ;;
            -v) ANSIBLE_EXTRA_ARGS+=("-v"); shift ;;
            -h) usage 0 ;;
            *)  EXTRA_ARGS+=("$1"); shift ;;
        esac
    done
}

run_playbook() {
    local extra_vars="${1:-}"
    local cmd=(
        ansible-playbook "$PLAYBOOK"
        -i "$INVENTORY"
        -c "$CONNECTION"
        -e "@${VARS_FILE}"
    )
    [[ -n "$extra_vars" ]] && cmd+=(-e "$extra_vars")
    cmd+=("${ANSIBLE_EXTRA_ARGS[@]}")
    "${cmd[@]}"
}

get_install_base() {
    python3 -c "import yaml; print(yaml.safe_load(open('${VARS_FILE}'))['paths']['install_base'])"
}

# -- Commands --

cmd_install() {
    run_playbook
}

cmd_uninstall() {
    run_playbook "uninstall=true"
}

cmd_start() {
    local base
    base="$(get_install_base)"
    sudo docker compose -f "${base}/docker-compose.yml" up -d
}

cmd_stop() {
    local base
    base="$(get_install_base)"
    sudo docker compose -f "${base}/docker-compose.yml" down
}

cmd_restart() {
    local base
    base="$(get_install_base)"
    sudo docker compose -f "${base}/docker-compose.yml" restart
}

cmd_status() {
    local base
    base="$(get_install_base)"
    sudo docker compose -f "${base}/docker-compose.yml" ps
}

cmd_provision() {
    local base
    base="$(get_install_base)"
    sudo docker compose -f "${base}/docker-compose.yml" up nexus-provision
}

cmd_logs() {
    local base
    base="$(get_install_base)"
    sudo docker compose -f "${base}/docker-compose.yml" logs -f "${EXTRA_ARGS[@]}"
}

# -- Main --

EXTRA_ARGS=()

[[ $# -lt 1 ]] && usage 1

COMMAND="$1"; shift
parse_opts "$@"

case "$COMMAND" in
    install)    cmd_install ;;
    uninstall)  cmd_uninstall ;;
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart ;;
    status)     cmd_status ;;
    provision)  cmd_provision ;;
    logs)       cmd_logs ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unknown command: $COMMAND" >&2; usage 1 ;;
esac
