#!/bin/bash

# Maps the three reviewed root names to fixed repository paths.

set -e

resolve_root() {
    if [ "$#" -ne 2 ]; then
        printf "resolve_root requires <repository-root> <root-name>\n" >&2
        return 64
    fi

    case "$2" in
        bootstrap)
            printf "%s/bootstrap\n" "$1"
            ;;
        foundation)
            printf "%s/environments/production/foundation\n" "$1"
            ;;
        release)
            printf "%s/environments/production/release\n" "$1"
            ;;
        *)
            printf "Unknown root. Expected bootstrap, foundation, or release.\n" >&2
            return 64
            ;;
    esac
}
