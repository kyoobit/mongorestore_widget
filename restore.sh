#!/usr/bin/env bash

# -e: exit on error
# -u: error on undefined variables
# -o pipefail: fail pipeline if any command fails
set -euo pipefail

# Make word splitting predictable
IFS=$'\n\t';

# Required environment variables
readonly required_vars=(
    RCLONE_CONF
    OSS
    OSS_BUCKET
    OSS_PATH
    MONGO_DB
    MONGO_COL
    MONGO_URI
    MONGO_RW_USERNAME
    MONGO_RW_PASSWORD
    ENCRYPTION_KEY
)

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Check that the rclone configuration file is available and not empty
check_dependencies() {
    log "Checking dependencies";

    # Check required environment variables are available
    for var in "${required_vars[@]}"; do
        log "Checking required environment variable: '${var}'";
        check_env_var "$var";
    done

    # Check if rclone is installed
    command -v rclone >/dev/null 2>&1 || {
        fail "rclone is not installed. Aborting.";
    }

    # Check if mongorestore is installed
    command -v mongorestore >/dev/null 2>&1 || {
        fail "mongorestore is not installed. Aborting.";
    }

    # Check if age is installed
    command -v age >/dev/null 2>&1 || {
        fail "age is not installed. Aborting.";
    }
}


# Check that an environment variable name is set
check_env_var() {
    local varname="$1"
    if [[ -z "${!varname}" ]]; then
        fail "Missing environment variable: ${varname}";
    fi
}


# Fetch a list of the available database dump files, ass-u-me the last file is the latest
get_latest_filename() {
    log "Fetching the latest available database dump file from: ${OSS}:${OSS_BUCKET}${OSS_PATH}";
    _latest_dump_file=$(rclone --config "$RCLONE_CONF" ls "${OSS}:${OSS_BUCKET}${OSS_PATH}" \
        | sort -k2 \
        | tail -n 1 \
        | awk '{print $2}');

    _latest_dump_dt=$(date -d @$(echo "${_latest_dump_file}" | sed -E 's|dump-([0-9]+)\.tgz.*|\1|'));
    log "Latest available database dump file is: ${_latest_dump_file} (${_latest_dump_dt})";

    LATEST_DUMP_FILE="${_latest_dump_file}";
}


# Download the database dump file from remote storage into a temp directory
download_dump() {
    log "Downloading latest database dump file: ${OSS}:${OSS_BUCKET}${OSS_PATH}/${LATEST_DUMP_FILE}";
    rclone --config "${RCLONE_CONF}" copy "${OSS}:${OSS_BUCKET}${OSS_PATH}/${LATEST_DUMP_FILE}" "${LATEST_DUMP_DIR}";

    log "Latest database dump file downloaded: $(stat --format='%F %s bytes %n' "${LATEST_DUMP_DIR}/${LATEST_DUMP_FILE}")";
}


# Decrypt the database dump file
decrypt_dump() {
    if [[ "${LATEST_DUMP_FILE}" != *.enc ]]; then
        return
    fi

    _latest_dump_unencrypted=$(echo "${LATEST_DUMP_FILE}" | sed 's|.enc||');

    log "Decrypting the database dump file: ${LATEST_DUMP_DIR}/${LATEST_DUMP_FILE}";
    age --decrypt --identity <(echo "${ENCRYPTION_KEY}") \
    --output="${LATEST_DUMP_DIR}/${_latest_dump_unencrypted}" \
    "${LATEST_DUMP_DIR}/${LATEST_DUMP_FILE}";

    LATEST_DUMP_FILE="${_latest_dump_unencrypted}";
}


# Decompress the database dump file
decompress_dump() {
    if [[ "${LATEST_DUMP_FILE}" != *.tgz ]]; then
        return
    fi

    log "Decompress and unpack the database dump file: ${LATEST_DUMP_DIR}/${LATEST_DUMP_FILE}";
    tar --extract --file="${LATEST_DUMP_DIR}/${LATEST_DUMP_FILE}" --directory="${LATEST_DUMP_DIR}";

    log "Database dump files extracted to: ${LATEST_DUMP_DIR}";
}


# Restore the database from a database dump file
restore_database() {
    log "Restoring the database: '${MONGO_DB}.${MONGO_COL}'";

    log "Find the '${MONGO_DB}' database dump files at: ${LATEST_DUMP_DIR}";
    _database=$(find "${LATEST_DUMP_DIR}" -type d -name "$MONGO_DB" -print -quit);
    _database_dir=$(dirname "${_database}");

    if [[ -z "${_database_dir}" ]]; then
        fail "Did not locate database files for '${MONGO_DB}' in: ${LATEST_DUMP_DIR}";
    fi

    log "Restoring '${MONGO_DB}.${MONGO_COL}' from: ${_database_dir}";
    mongorestore --uri="${MONGO_URI}" \
    --authenticationDatabase=admin \
    --drop --nsInclude="${MONGO_DB}.${MONGO_COL}" \
    --username="${MONGO_RW_USERNAME}" \
    --password="${MONGO_RW_PASSWORD}" \
    "${_database_dir}";

    log "Database '${MONGO_DB}.${MONGO_COL}' restored";
    exit 0;
}


# main
RCLONE_CONF="/etc/rclone/rclone.conf";
LATEST_DUMP_DIR="$(mktemp -d)";
trap 'rm -rf "${LATEST_DUMP_DIR}"' EXIT;
LATEST_DUMP_FILE="";
check_dependencies;
get_latest_filename;
download_dump;
decrypt_dump;
decompress_dump;
restore_database;
