#!/usr/bin/env bash
# =============================================================================
# MAILSERVER SETUP UTILITY
# Purpose: Wrapper for docker-mailserver setup.sh command.
# Run this inside the mailserver/ directory.
# =============================================================================

if [ ! -f "docker-compose.yml" ]; then
    echo "[ERR] Run this script from inside the mailserver/ directory."
    exit 1
fi

COMMAND=$1
if [ -z "$COMMAND" ]; then
    echo "Usage: ./02_mailserver_setup.sh [command]"
    echo ""
    echo "Commands:"
    echo "  start       - Start the mailserver"
    echo "  stop        - Stop the mailserver"
    echo "  add_user    - Add a new email account"
    echo "  generate_dkim - Generate DKIM keys for your domain"
    echo "  setup_cli   - Run arbitrary docker-mailserver setup commands"
    exit 0
fi

case "$COMMAND" in
    start)
        docker compose up -d
        echo "Mailserver starting..."
        ;;
    stop)
        docker compose down
        echo "Mailserver stopped."
        ;;
    add_user)
        read -p "Email address: " EMAIL
        docker compose exec mailserver setup email add "$EMAIL"
        ;;
    generate_dkim)
        docker compose exec mailserver setup config dkim
        echo "DKIM generated. Check ./docker-data/dms/config/opendkim/keys/"
        ;;
    setup_cli)
        shift
        docker compose exec mailserver setup "$@"
        ;;
    *)
        echo "Unknown command: $COMMAND"
        ;;
esac
