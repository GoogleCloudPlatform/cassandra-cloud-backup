#!/bin/bash
#
# Copyright 2016 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
# Description :  Take snapshot and incremental backups of Cassandra and copy them to Google Cloud Storage
#                Optionally restore full system from snapshot
# This is not an official Google product.
#
VERSION='1.0'
SCRIPT_NAME="cassandra-cloud-backup.sh"
#exit on any error
set -e
# Prints the usage for this script
function print_usage() {
  echo "Cassandra Backup to Google Cloud Storage Version: ${VERSION}"
  cat <<'EOF'
Usage: ./cassandra-cloud-backup.sh [ options ] <command>
Description:
  Utility for creating and managing Cassandra Backups with Google Cloud Storage.
  Run with admin level privileges.

  The backup command can use gzip or bzip2 for compression, and split large files
  into multiple smaller files. If incremental backups are enabled in
  Cassandra, this script can incrementally copy them as they are created, saving
  time and space. Additionally, this script can be used to cleanup old SnapShot
  and Incremental files locally.

  The restore command is designed to perform a simple restore of a full snapshot.
  In the event that you want to restore incremental backups you should start by
  restoring the last full snapshot prior to your target incremental backup file
  and manually move the files from each incremental backup in chronological order
  leading up to the target incremental backup file.  The schema dump and token ring
  are included in the snapshot backups, but if necessary they must also be restored
  manually.

Flags:
  -a, --alt-hostname
    Specify an alternate server name to be used in the bucket path construction. Used
    to create or retrieve backups from different servers

  -B, backup
    Default action is to take a backup

  -b, --gcsbucket
   Google Cloud Storage bucket used in deployment and by the cluster.

  -c, --clear-old-ss
    Clear any old SnapShots taken prior to this backup run to save space
    additionally will clear any old incremental backup files taken immediately
    following a successful snapshot. this option does nothing with the -i flag

  -C, --clear-old-inc
    Clear any old incremental backups taken prior to the the current snapshot

  -d, --backupdir
    The directory in which to store the backup files, be sure that this directory
    has enough space and the appropriate permissions

  -D, --download-only
    During a restore this will only download the target files from GCS

  -f, --force
    Used to force the restore without confirmation prompt

  -h, --help
    Print this help message.

  -H, --home-dir
    This is the $CASSANDRA_HOME directory and is only used if the data_directories,
    commitlog_directory, or the saved_caches_directory values cannot be parsed out of the
    yaml file.

  -i, --incremental
    Copy the incremental backup files and do not take a snapshot. Can only
    be run when compression is enabled with -z or -j

  -j, --bzip
    Compresses the backup files with bzip2 prior to pushing to Google Cloud Storage
    This option will use additional local disk space set the --target-gz-dir
    to use an alternate disk location if free space is an issue

  -k, --keep-old
    Set this flag on restore to keep a local copy of the old data files
    Set this flag on backup to keep a local copy of the compressed backup, schema dump,
    and token ring

  -l, --log-dir
    Activate logging to file 'CassandraBackup${DATE}.log' from stdout
    Include an optional directory path to write the file
    Default path is /var/log/cassandra

  -L, --inc-commit-logs
    Add commit logs to the backup archive. WARNING: This option can cause the script to
    fail an active server as the files roll over

  -n, --noop
    Will attempt a dry run and verify all the settings are correct

  -N, --nice
    Set the process priority, default 10

  -p
    The Cassandra User Password if required for security

  -r,  restore
    Restore a backup, requires a --gcsbucket path and optional --backupdir

  -s, --split-size
    Split the resulting tar archive into the configured size in Megabytes, default 100M

  -S, --service-name
    Specify the service name for cassandra, default is cassandra use to stop and start service

  -T, --target-gz-dir
    Override the directory to save compressed files in case compression is used
    default is --backupdir/compressed, also used to decompress for restore

  -u
    The Cassandra User account if required for security

  -U, --auth-file
    A file that contains authentication credentials for cqlsh and nodetool consisting of
    two lines:
      CASSANDRA_USER=username
      CASSANDRA_PASS=password

  -v, --verbose
    When provided will print additional information to log file

  -w, --with-caches
    For posterity's sake, to save the read caches in a backup use this flag, although it
    likely represents a waste of space

  -y, --yaml
    Path to the Cassandra yaml configuration file
    default: /etc/cassandra/cassandra.yaml

  -z, --zip
    Compresses the backup files with gzip prior to pushing to Google Cloud Storage
    This option will use additional local disk space set the --target-gz-dir
    to use an alternate disk location if free space is an issue

Commands:
  backup, restore, inventory, commands, options

backup                Backup the Cassandra Node based on passed in options

restore               Restore the Cassandra Node from a specific snapshot backup
                      or download an incremental backup locally and extract

inventory             List available backups

commands              List available commands

options               list available options

Examples:
  Take a full snapshot, gzip compress it with nice=15,
  upload into the GCS Bucket, and clear old incremental and snapshot files
  ./cassandra-cloud-backup.sh -b gs://cassandra-backups123/ -zCc -N 15 backup

  Do a dry run of a full snapshot with verbose output and
  create list of files that would have been copied
  ./cassandra-cloud-backup.sh -b gs://cassandra-backups123/ -vn backup

  Backup and bzip2 compress copies of the most recent incremental
  backup files since the last incremental backup
  ./cassandra-cloud-backup.sh -b gs://cassandra-backups123/ -ji backup

  Restore a backup without prompting from specified bucket path and keep the old files locally
  ./cassandra-cloud-backup.sh -b gs://cass-bk123/backups/host01/snpsht/2016-01-20_18-57/ -fk restore

  Restore a specific backup to a custom CASSANDRA_HOME directory with secure credentials in
  password.txt file with Cassandra running as a Linux service name cass
  ./cassandra-cloud-backup.sh -b gs://cass-bk123/backups/host01/snpsht/2016-01-20_18-57/ \
   -y /opt/cass/conf/cassandra.yaml -H /opt/cass -U password.txt -S cass restore

  List inventory of available backups stored in Google Cloud Store
  ./cassandra-cloud-backup.sh -b gs://cass-bk123 inventory

EOF
}

# List all commands for command completion.
function commands() {
  print_usage | sed -n -e '/^Commands:/,/^$/p' | tail -n +2 | head -n -1 | tr -d ','
}

# List all options for command completion.
function options() {
  print_usage | grep -E '^ *-' | tr -d ','
}

# Override the date function
function prepare_date() {
  date "$@"
}

# Prefix a date prior to echo output
function loginfo() {

  if  ${LOG_OUTPUT}; then
     echo "$(prepare_date +%F_%H:%M:%S): ${*}" >> "${LOG_FILE}"
  else
     echo "$(prepare_date +%F_%H:%M:%S): ${*}"
  fi
}

# Only used if -v --verbose is passed in
function logverbose() {
  if ${VERBOSE}; then
    loginfo "VERBOSE: ${*}"
  fi
}

# Pass errors to stderr.
function logerror() {
  loginfo "ERROR: ${*}" >&2
  let ERROR_COUNT++
}

# Bad option was found.
function print_help() {
  logerror "Unknown Option Encountered. For help run '${SCRIPT_NAME} --help'"
  print_usage
  exit 1
}

# Validate that all configuration options are correct and no conflicting options are set
function validate() {
  touch_logfile
  single_script_check
  set_auth_string
  verbose_vars
  loginfo "***************VALIDATING INPUT******************"
  if [ -z ${GSUTIL} ]; then
    logerror "Cannot find gsutil utility please make sure it is in the PATH"
    exit 1
  fi
  if [ -z ${GCS_BUCKET} ]; then
      logerror "Please pass in the GCS Bucket to use with this script"
      exit 1
  else
      if ! ${GSUTIL} ls ${GCS_BUCKET} &> /dev/null; then
        logerror "Cannot access Google Cloud Storage bucket ${GCS_BUCKET} make sure" \
        " it exists"
        exit 1
      fi
  fi
  if [ ${ACTION} != "inventory" ]; then
    if [ -z ${NODETOOL} ]; then
      logerror "Cannot find nodetool utility please make sure it is in the PATH"
    fi
    if [ -z ${CQLSH} ]; then
      logerror "Cannot find cqlsh utility please make sure it is in the PATH"
    fi
    if [ ! -f ${YAML_FILE} ]; then
      logerror "Yaml File ${YAML_FILE} does not exist and --yaml argument is missing"
    else
      #different values are needed for backup and for restore
      eval "parse_yaml_${ACTION}"
    fi

    if [ -z ${data_file_directories} ]; then
      if [ -z ${CASS_HOME} ]; then
        logerror "Cannot parse data_directories from ${YAML_FILE} and --home-dir argument" \
        " is missing, which should be the \$CASSANDRA_HOME path"
      else
        data_file_directories="${CASS_HOME}/data/data"
      fi
    fi
    if ${INCLUDE_COMMIT_LOGS}; then
      loginfo "WARNING: Backing up Commit Logs can cause script to fail if server is under load"
    fi
    if [ -z ${commitlog_directory} ]; then
      if [ -z ${CASS_HOME} ]; then
        logerror "Cannot parse commitlog_directory from ${YAML_FILE} and --home-dir argument" \
        " is missing, which should be the \$CASSANDRA_HOME path"
      else
        commitlog_directory="${CASS_HOME}/data/commitlog"
      fi
    fi
    if [ ! -d ${commitlog_directory} ]; then
      logerror "no diretory commitlog_directory: ${commitlog_directory} "
    fi
    if ${INCLUDE_CACHES}; then
      loginfo "Backing up saved caches can waste space and time, but it is happening anyway"
    fi
    if [ -z ${saved_caches_directory} ]; then
      if [ -z ${CASS_HOME} ]; then
        logerror "Cannot parse saved_caches_directory from ${YAML_FILE} and --home-dir argument" \
        " is missing, which should be the \$CASSANDRA_HOME path"
      else
        saved_caches_directory="${CASS_HOME}/data/saved_caches"
      fi
    fi
    if [ ! -d ${saved_caches_directory} ]; then
      logerror "saved_caches_directory does not exist: ${saved_caches_directory} "
    fi
    if [ ! -d ${data_file_directories} ]; then
      logerror "data_file_directories does not exist : ${data_file_directories} "
    fi
    #BACKUP_DIR is used to stage backups and stage restores, so create it either way
    if [ ! -d ${BACKUP_DIR} ]; then
        loginfo "Creating backup directory ${BACKUP_DIR}"
        mkdir -p ${BACKUP_DIR}
    fi
    if ${SPLIT_FILE}; then
      SPLIT_FILE_SUFFIX="${TAR_EXT}-${SPLIT_FILE_SUFFIX}"
    fi
    if [ ! -d ${COMPRESS_DIR} ]; then
      loginfo "Creating compression target directory"
      mkdir -p ${COMPRESS_DIR}
    fi
    if [ -z ${TAR} ] || [ -z ${NICE} ]; then
      logerror "The tar and nice utilities must be present to win."
    fi
    if [ ${ACTION} = "restore" ]; then
      GCS_LS=$(${GSUTIL} ls ${GCS_BUCKET} | head -n1)
      loginfo "GCS first file listed: ${GCS_LS}"
      if  grep -q 'incr' <<< "${GCS_LS}"; then
        loginfo "Detected incremental backup requested for restore. This script " \
        "will only download the files locally"
        DOWNLOAD_ONLY=true
        INCREMENTAL=true
        SUFFIX="incr"
      else
        if grep -q 'snpsht' <<< "${GCS_LS}"; then
          loginfo "Detected full snapshot backup requested for restore."
        else
          logerror "Detected a Google Cloud Storage bucket path that is not a backup" \
          " location. Make sure the --gcsbucket e is the full path to a specific backup"
        fi
      fi
      if grep -q "tgz" <<< "${GCS_LS}"; then
        loginfo "Detected compressed .tgz file for restore"
        COMPRESSION=true
        TAR_EXT="tgz"
        TAR_CFLAG="-z"
      fi
      if  grep -q "tbz" <<< "${GCS_LS}"; then
        loginfo "Detected compressed .tbz file for restore"
        COMPRESSION=true
        TAR_EXT="tbz"
        TAR_CFLAG="-j"
      fi
      if  grep -q "tar" <<< "${GCS_LS}"; then
        loginfo "Detected uncompressed .tar file for restore"
        COMPRESSION=false
        TAR_EXT="tar"
        TAR_CFLAG=""
      fi
      RESTORE_FILE=$(awk -F"/" '{print $NF}' <<< "${GCS_LS}")
      if [[ "${RESTORE_FILE}" != *.${TAR_EXT} ]] ; then
          #Detect Split Files${TAR_EXT}-
          if [[ "${RESTORE_FILE}" ==  ${TAR_EXT}-* ]]; then
            SPLIT_FILE=true
            loginfo "Split file restore detected"
          else
            logerror "Restore is not a tar file  ${GCS_BUCKET}"
          fi
      fi
      if [[ ! ${GCS_BUCKET} =~ ^.*\.${TAR_EXT}$ ]]; then
        if ${SPLIT_FILE}; then
          #remove the trailing digits and replace the suffix
          RESTORE_FILE="${RESTORE_FILE%${SUFFIX}*}${SUFFIX}*"
          GCS_BUCKET="${GCS_BUCKET%/}/${RESTORE_FILE}"
        else
          GCS_BUCKET="${GCS_BUCKET%/}/${RESTORE_FILE}"
          loginfo "Fixed up restore bucket path: ${GCS_BUCKET}"
        fi
      fi

      if grep -q "," <<< "${seed_provider_class_name_parameters_seeds}"; then
        loginfo "Restore target node is likely part of a cluster. Restore script" \
        " will not start node automatically"
        AUTO_RESTART=false
      fi
      loginfo "creating staging directory for restore: ${BACKUP_DIR}/restore"
      mkdir -p "${BACKUP_DIR}/restore"
    else
      if ${INCREMENTAL}; then
        if ${CLEAR_INCREMENTALS}; then
          logerror "--clear-old-inc option is not compatible with --incremental option"
        fi
        if ${CLEAR_SNAPSHOTS}; then
          logerror "--incremental option is not compatible with --clear-old-ss option"
        fi
        if [ -z ${incremental_backups} ] || [  ${incremental_backups} = false  ]; then
          logerror "Cannot copy incremental backups until 'incremental_backups' is true " \
          "in ${YAML_FILE} "
        fi
        if [ ! -f "${BACKUP_DIR}/last_inc_backup_time" ]; then
          touch "${BACKUP_DIR}/last_inc_backup_time"
        fi
      else
          if [ ${CLEAR_INCREMENTALS} = true ] && [ ${incremental_backups} != true ]; then
              logerror "Cannot clear incremental backups because 'incremental_backups' is " \
              "false in ${YAML_FILE} "
          fi
          if [ ! -d "${SCHEMA_DIR}" ]; then
            loginfo "Creating schema dump directory: ${SCHEMA_DIR}"
            mkdir -p "${SCHEMA_DIR}"
          fi
          if [ ! -d "${TOKEN_RING_DIR}" ]; then
            loginfo "Creating token ring dump directory: ${TOKEN_RING_DIR}"
            mkdir -p "${TOKEN_RING_DIR}"
          fi
      fi
    fi
  else
    # ${ACTION} = "inventory"
    parse_yaml_inventory
  fi

  logverbose "ERROR_COUNT: ${ERROR_COUNT}"

  if [ ${ERROR_COUNT} -gt 0 ]; then
    loginfo "*************ERRORS WHILE VALIDATING INPUT*************"
    exit 1
  fi
  loginfo "*************SUCCESSFULLY VALIDATED INPUT**************"
}

# Print out all the important variables if -v is set
function verbose_vars() {
  logverbose "************* PRINTING VARIABLES ****************\n"
  logverbose "ACTION: ${ACTION}"
  logverbose "AUTO_RESTART: ${AUTO_RESTART}"
  logverbose "BACKUP_DIR: ${BACKUP_DIR}"
  logverbose "CASSANDRA_PASS: ${CASSANDRA_PASS}"
  logverbose "CASSANDRA_USER: ${CASSANDRA_USER}"
  logverbose "CASSANDRA_OG: ${CASSANDRA_OG}"
  logverbose "CLEAR_INCREMENTALS: ${CLEAR_INCREMENTALS}"
  logverbose "CLEAR_SNAPSHOTS: ${CLEAR_SNAPSHOTS}"
  logverbose "COMPRESS_DIR: ${COMPRESS_DIR}"
  logverbose "COMPRESSION: ${COMPRESSION}"
  logverbose "CQLSH: ${CQLSH}"
  logverbose "CQLSH_DEFAULT_HOST: ${CQLSH_DEFAULT_HOST}"
  logverbose "DATE: ${DATE}"
  logverbose "DOWNLOAD_ONLY: ${DOWNLOAD_ONLY}"
  logverbose "DRY_RUN: ${DRY_RUN}"
  logverbose "FORCE_RESTORE: ${FORCE_RESTORE}"
  logverbose "GCS_BUCKET: ${GCS_BUCKET}"
  logverbose "GCS_TMPDIR: ${GCS_TMPDIR}"
  logverbose "GSUTIL: ${GSUTIL}"
  logverbose "HOSTNAME: ${HOSTNAME}"
  logverbose "INCREMENTAL: ${INCREMENTAL}"
  logverbose "INCLUDE_CACHES: ${INCLUDE_CACHES}"
  logverbose "INCLUDE_COMMIT_LOGS: ${INCLUDE_COMMIT_LOGS}"
  logverbose "KEEP_OLD_FILES: ${KEEP_OLD_FILES}"
  logverbose "LOG_DIR: ${LOG_DIR}"
  logverbose "LOG_FILE: ${LOG_FILE}"
  logverbose "LOG_OUTPUT: ${LOG_OUTPUT}"
  logverbose "NICE: ${NICE}"
  logverbose "NICE_LEVEL: ${NICE_LEVEL}"
  logverbose "NODETOOL: ${NODETOOL}"
  logverbose "SCHEMA_DIR: ${SCHEMA_DIR}"
  logverbose "TOKEN_RING_DIR: ${TOKEN_RING_DIR}"
  logverbose "SERVICE_NAME: ${SERVICE_NAME}"
  logverbose "SNAPSHOT_NAME: ${SNAPSHOT_NAME}"
  logverbose "SPLIT_FILE: ${SPLIT_FILE}"
  logverbose "SPLIT_SIZE: ${SPLIT_SIZE}"
  logverbose "SUFFIX: ${SUFFIX}"
  logverbose "TARGET_LIST_FILE: ${TARGET_LIST_FILE}"
  logverbose "USER_OPTIONS: ${USER_OPTIONS}"
  logverbose "USER_FILE: ${USER_FILE}"
  logverbose "YAML_FILE: ${YAML_FILE}"
  logverbose "************* DONE PRINTING VARIABLES ************\n"
}

# Check that script is not running more than once
function single_script_check() {
  local grep_script
  #wraps a [] around the first letter to trick the grep statement into ignoring itself
  grep_script="$(echo ${SCRIPT_NAME} | sed 's/^/\[/' | sed 's/^\(.\{2\}\)/\1\]/')"
  logverbose "checking that script isn't already running"
  logverbose "grep_script: ${grep_script}"
  status="$(ps -feww | grep -w \"${grep_script}\" \
    | awk -v pid="$(echo $$)" '$2 != pid { print $2 }')"
  if [ ! -z "${status}" ]; then
    logerror " ${SCRIPT_NAME} : Process is already running. Aborting"
    exit 1;
  fi
}

# Create the log file if requested
function touch_logfile() {
  if [ "${LOG_OUTPUT}" = true ] && [ ! -f "${LOG_FILE}" ]; then
    touch "${LOG_FILE}"
  fi
}

# List available backups in GCS
function inventory() {
  loginfo "Available Snapshots:"
  ${GSUTIL} ls -d "${GCS_BUCKET}/backups/${HOSTNAME}/snpsht/*"
  if [ -z $incremental_backups ] || [ $incremental_backups = false ]; then
    loginfo "Incremental Backups are not enabled for Cassandra"
  fi
  loginfo "Available Incremental Backups:"
  ${GSUTIL} ls -d "${GCS_BUCKET}/backups/${HOSTNAME}/incr/*"
}

# This is the main backup function that orchestrates all the options
# to create the backup set and then push it to GCS
function backup() {
  create_gcs_backup_path
  clear_backup_file_list
  if ${CLEAR_SNAPSHOTS}; then
    clear_snapshots
  fi
  if ${INCREMENTAL}; then
    find_incrementals
  else
    export_schema
    export_token_ring
    take_snapshot
    find_snapshots
  fi
  copy_other_files
  if ${SPLIT_FILE}; then
    split_archive
  else
    archive_compress
  fi
  copy_to_gcs
  save_last_inc_backup_time
  backup_cleanup
  if ${CLEAR_INCREMENTALS}; then
    clear_incrementals
  fi
}

#specific variables are needed for backup
function parse_yaml_backup() {
  loginfo "Parsing Cassandra Yaml Config Values"
  fields=('data_file_directories' \
          'commitlog_directory' \
          'saved_caches_directory' \
          'incremental_backups' \
          'native_transport_port' \
          'rpc_address')
  parse_yaml ${YAML_FILE}
}

#specific variables are needed for restore
function parse_yaml_restore() {
  loginfo "Parsing Cassandra Yaml Config Values"
  fields=('data_file_directories' \
          'commitlog_directory' \
          'saved_caches_directory' \
          'incremental_backups' \
          'seed_provider_class_name_parameters_seeds')

  parse_yaml ${YAML_FILE}
}

function parse_yaml_inventory() {
  fields=('incremental_backups')
  parse_yaml ${YAML_FILE}
}

# Based on https://gist.github.com/pkuczynski/8665367
#
# Works for arrays of hashes, and some hashes with arrays
# Variable names will be underscore delimitted based on nested parent names
# Send in yaml file as first argument and create a global array named $fields
# with necessary yaml field names fully underscore delimitted to match nesting
# then this will register those variables into the shell's scope if they exist in Yaml
# $VERBOSE=1 will also print the full values
# Defaults to indent of 4 so d=4
# To use with indent of 2 change d to 2
function parse_yaml() {
    local s
    local w
    local fs
    local d
    s='[[:space:]]*'
    w='[a-zA-Z0-9_]*'
    fs="$(echo @|tr @ '\034')"
    d=4
    eval $(
      sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
            -e "s|^\($s\)-\?$s\($w\)$s[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" $1 |
      awk -F"$fs"  -v names="${fields[*]}" '
      BEGIN { split(names,n," ") }
      { sc=length($1) % "'$d'";
        if ( sc == 0 ) {
          indent = length($1)/"'$d'"
        } else {
          indent = (length($1)+("'$d'"-sc))/"'$d'"
        }
        vname[indent] = $2;
        for (i in vname) {if (i > indent){ delete vname[i];}}
        if (length($3) > 0 ) {
          vn="";
          for (i=0; i<indent; i++) {
            if (length(vname[i]) > 0) {vn=(vn)(vname[i])("_");}
          }
          ap="";
          if($2 ~ /^ *$/ && vn ~ /_$/) { vn=substr(vn,1,length(vn)-1);ap="+" }
          for ( name in  n ) {
            if ( $2 == n[name] || vn == n[name] || (vn)($2) == n[name]) {
              printf("%s%s%s=(\"%s\")\n", vn, $2, ap, $3);
              if ("'"$VERBOSE"'" == "true"){
                printf(";logverbose %s%s%s=\\(\\\"%s\\\"\\);", vn, $2, ap, $3);
              }
            }
          }
        }
      }'
    )
}

# If a username and password is required for cqlsh and nodetool
function set_auth_string() {
  if ${USE_AUTH}; then
    if [ -n "${USER_FILE}" ] && [ -f "${USER_FILE}" ]; then
      source "${USER_FILE}"
    fi
    if [ -z "${CASSANDRA_USER}" ] || [ -z "${CASSANDRA_PASS}" ]; then
      logerror "Cassandra authentication values are missing or empty CASSANDRA_USER or CASSANDRA_PASS"
    fi
    USER_OPTIONS=" -u ${CASSANDRA_USER} --password ${CASSANDRA_PASS} "
  fi
}

# Set the backup path bucket URL
function create_gcs_backup_path() {
  GCS_BACKUP_PATH="${GCS_BUCKET}/backups/${HOSTNAME}/${SUFFIX}/${DATE}/"
  loginfo "Will use target backup directory: ${GCS_BACKUP_PATH}"
}

# In case there is an existing backup file list, clear it out
function clear_backup_file_list() {
  loginfo "Clearing target list file: ${TARGET_LIST_FILE}"
   > "${TARGET_LIST_FILE}"
}

# Use nodetool to take a snapshot with a specific name
function take_snapshot() {
  loginfo "Taking Snapshot ${SNAPSHOT_NAME}"
  #later used to remove older incrementals
  SNAPSHOT_TIME=$(prepare_date "+%F %H:%M:%S")
  if ${DRY_RUN}; then
    loginfo "DRY RUN: ${NODETOOL} ${USER_OPTIONS} snapshot -t ${SNAPSHOT_NAME} "
  else
    ${NODETOOL} ${USER_OPTIONS} snapshot -t "${SNAPSHOT_NAME}" #2>&1 > ${LOG_FILE}
    loginfo "Completed Snapshot ${SNAPSHOT_NAME}"
  fi
}

# Export the whole schema for safety
function export_schema() {
  loginfo "Exporting Schema to ${SCHEMA_DIR}/${DATE}-schema.cql"
  local cqlsh_host=${rpc_address:-$CQLSH_DEFAULT_HOST}
  local cmd
  cmd="${CQLSH} ${cqlsh_host} ${native_transport_port} ${USER_OPTIONS} -e 'DESC SCHEMA;'"
  if ${DRY_RUN}; then
    loginfo "DRY RUN:  ${cmd}  > ${SCHEMA_DIR}/${DATE}-schema.cql"
  else
    #cqlsh does not behave consistently when executed directly from inside a script
    bash -c "${cmd} > ${SCHEMA_DIR}/${DATE}-schema.cql"
  fi
  echo "${SCHEMA_DIR}/${DATE}-schema.cql" >> "${TARGET_LIST_FILE}"
}

# Export the whole token ring for safety
function export_token_ring() {
  loginfo "Exporting Token Ring to ${TOKEN_RING_DIR}/${DATE}-token-ring"
  local cmd
  cmd="${NODETOOL} ${USER_OPTIONS} ring"
  if ${DRY_RUN}; then
    loginfo "DRY RUN:  ${cmd}  > ${TOKEN_RING_DIR}/${DATE}-token-ring"
  else
    bash -c "${cmd} > ${TOKEN_RING_DIR}/${DATE}-token-ring"
  fi
  echo "${TOKEN_RING_DIR}/${DATE}-token-ring" >> "${TARGET_LIST_FILE}"
}


# Copy the commit logs, saved caches directoy and the yaml config file
function copy_other_files() {
  loginfo "Copying caches, commitlogs and config file paths to backup list"
  #resolves issue #2
  if ${INCLUDE_COMMIT_LOGS}; then
    find "${commitlog_directory}" -type f >> "${TARGET_LIST_FILE}"
  fi
  #resolves issue #3
  if ${INCLUDE_CACHES}; then
    find "${saved_caches_directory}" -type f >> "${TARGET_LIST_FILE}"
  fi
  echo "${YAML_FILE}" >> "${TARGET_LIST_FILE}"
}

# Since incrementals are automatically created as needed
# this script has to find them for each keyspace and then
# compare against a timestamp file to copy only the newest files
function find_incrementals() {
  loginfo "Locating Incremental backup files"
  LAST_INC_BACKUP_TIME="$(head -n 1 ${BACKUP_DIR}/last_inc_backup_time)"
  #take time before list to backup is compiled
  local time_before_find=$(prepare_date "+%F %H:%M:%S")
  for i in "${data_file_directories[@]}"
  do
    if [ -n "${LAST_INC_BACKUP_TIME}" ]; then
      find ${i} -mindepth 4 -maxdepth 4 -path '*/backups/*' -type f \
        \( -name "*.db" -o -name "*.crc32" -o -name "*.txt" \) \
        -newermt "${LAST_INC_BACKUP_TIME}" >> "${TARGET_LIST_FILE}"
    else
      find ${i} -mindepth 4 -maxdepth 4 -path '*/backups/*' -type f \
        \( -name "*.db" -o -name "*.crc32" -o -name "*.txt" \) \
        >> "${TARGET_LIST_FILE}"
    fi
  done
  #if there is only one line in the file then no files were found
  if [ $(cat "${TARGET_LIST_FILE}" | wc -l) -lt 1 ]; then
    loginfo "No new incremental files detected, aborting backup"
    exit 0
  fi
  #store time right before backup list creation to update after successful backup
  LAST_INC_BACKUP_TIME=${time_before_find}
}

# After successful backup, update last_inc_backup_time file
function save_last_inc_backup_time() {
  if ! ${DRY_RUN}; then
    echo "${LAST_INC_BACKUP_TIME}" > ${BACKUP_DIR}/last_inc_backup_time
  fi
}

# Find snapshots to include in backup
function find_snapshots() {
  loginfo "Locating Snapshot ${SNAPSHOT_NAME}"
  for i in "${data_file_directories[@]}"
  do
    find ${i} -path "*/snapshots/${SNAPSHOT_NAME}/*" -type f >> "${TARGET_LIST_FILE}"
  done
}

# Compress contents of backup directory
function archive_compress() {
  loginfo "Creating Archive file: ${COMPRESS_DIR}/${ARCHIVE_FILE}"
  local cmd
  cmd="${NICE} -n${NICE_LEVEL} ${TAR} -pc ${TAR_CFLAG} -f "
  cmd+="${COMPRESS_DIR}/${ARCHIVE_FILE} --files-from=${TARGET_LIST_FILE}"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: ${cmd}"
  else
    eval "${cmd}"
  fi
}

#For large backup files, this will split the file into multiple smaller files
#which allows for more efficient upload / download from Google Cloud Storage
function split_archive() {
  loginfo "Compressing And splitting backup"
  local cmd
  cmd="(cd ${COMPRESS_DIR} && ${NICE} -n${NICE_LEVEL} ${TAR} -pc ${TAR_CFLAG} -f - "
  cmd+="--files-from=${TARGET_LIST_FILE} "
  cmd+=" | split -d -b${SPLIT_SIZE} - ${SPLIT_FILE_SUFFIX})"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: ${cmd}"
  else
    eval "${cmd}"
  fi
}

# Remove old snapshots to free space
function clear_snapshots() {
  loginfo "Clearing old Snapshots"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: did not clear snapshots"
  else
    $NODETOOL ${USER_OPTIONS} clearsnapshot
  fi
}

# If requested the old incremental backup files will be pruned following the fresh snapshot
#$AGE is set to 5 minutes assuming this script takes no more than 5 minutes to run
function clear_incrementals() {
  loginfo "Clearing old incremental backups"
  for i in "${data_file_directories[@]}"
  do
    if ${DRY_RUN}; then
      loginfo "DRY RUN: did not clear old incremental backups"
    else
      find ${i} -mindepth 4 -maxdepth 4 -path '*/backups/*' -type f \
        \( -name "*.db" -o -name "*.crc32" -o -name "*.txt" \) \
        \! -newermt "${SNAPSHOT_TIME}" -exec rm -f ${VERBOSE_RM} {} \;
    fi
  done
}

# Copy the backup files up to the GCS bucket
function copy_to_gcs() {
  loginfo "Copying files to ${GCS_BACKUP_PATH}"
  if ${DRY_RUN}; then
    if ${SPLIT_FILE}; then
      loginfo "DRY RUN: ${GSUTIL} -m cp ${COMPRESS_DIR}/${SPLIT_FILE_SUFFIX}* ${GCS_BACKUP_PATH}"
    else
      loginfo "DRY RUN: ${GSUTIL} cp ${COMPRESS_DIR}/${ARCHIVE_FILE} ${GCS_BACKUP_PATH}"
    fi
  else
    if ${SPLIT_FILE}; then
      ${GSUTIL} -m cp "${COMPRESS_DIR}/${SPLIT_FILE_SUFFIX}*" "${GCS_BACKUP_PATH}"
    else
      ${GSUTIL} cp "${COMPRESS_DIR}/${ARCHIVE_FILE}" "${GCS_BACKUP_PATH}"
    fi
  fi
}

# This will optionally go through and delete files generated by the backup
# if the -k --keep-old flag is set then it will not delete these files
function backup_cleanup() {
  if ${DRY_RUN}; then
    loginfo "DRY RUN: Would have deleted old backup files"
  else
    if ${KEEP_OLD_FILES}; then
      loginfo "Keeping backup files:"
      loginfo "  ${COMPRESS_DIR}/*"
      loginfo "  ${SCHEMA_DIR}/${DATE}-schema.cql"
      loginfo "  ${TOKEN_RING_DIR}/${DATE}-token-ring"
    else
      loginfo "Deleting backup files"
      find "${COMPRESS_DIR}/" -type f -exec rm -f ${VERBOSE_RM} {} \;
      find "${SCHEMA_DIR}/" -type f -exec rm -f ${VERBOSE_RM} {} \;
      find "${TOKEN_RING_DIR}/" -type f -exec rm -f ${VERBOSE_RM} {} \;
      rm -f ${VERBOSE_RM} ${TARGET_LIST_FILE}
    fi
  fi
}

# This restore function is designed to perform a simple restore of a full snapshot
# In the event that you want to restore incremental backups you should start by
# restoring the last full snapshot prior to your target incremental backup file
# and manually move the files from each incremental file in chronological order
# leading up to the target incremental backup file
function restore() {
  loginfo "****NOTE: Simple restore procedure activated*****************"
  loginfo "****NOTE: Restore requires a full snapshot backup************"
  loginfo "****NOTE: Incremental backups must be manually restored******\n"
  restore_get_files
  if ${DOWNLOAD_ONLY} ; then
    loginfo "Backup file downloaded to ${BACKUP_DIR}/restore, this script will only" \
    " restore a full snapshot"
    loginfo "You must manually restore incremental files in sequence after first" \
    "restoring the last full snapshot taken prior to your incremental file's creation date"
    exit 0
  else
    restore_confirm
    restore_stop_cassandra
    restore_files
    restore_start_cassandra
    restore_cleanup
  fi
}

# Orchestrate the retrieval and extraction of the files to recover
function restore_get_files() {
  loginfo "Starting file retrieval process"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: Would have cleared restore dir ${BACKUP_DIR}/restore/*"
  else
    rm -rf ${VERBOSE_RM} ${BACKUP_DIR}/restore/*
  fi
  if ${SPLIT_FILE}; then
    restore_split_from_gcs
  else
    restore_compressed_from_gcs
  fi

}

# Download uncompressed backup files from GCS
function restore_split_from_gcs() {
  loginfo "Downloading restore files from GCS"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: ${GSUTIL} -m -r cp ${GCS_BUCKET} ${COMPRESS_DIR}"
  else
    ${GSUTIL} -m cp -r  "${GCS_BUCKET}" "${COMPRESS_DIR}"
  fi
  restore_split
}

# Retrieve the compressed backup file
function restore_compressed_from_gcs() {
    if ${DRY_RUN}; then
      loginfo "DRY RUN: ${GSUTIL} cp ${GCS_BUCKET} ${COMPRESS_DIR}"
    else
       #copy the tar.gz file
      ${GSUTIL} cp "${GCS_BUCKET}" "${COMPRESS_DIR}"
    fi
    restore_decompress
}

# Extract the compressed backup file
function restore_decompress() {
  loginfo "Decompressing restore files"
  local cmd
  cmd="${NICE} -n${NICE_LEVEL} ${TAR} -x ${TAR_CFLAG} "
  cmd+="-f ${COMPRESS_DIR}/${RESTORE_FILE} -C ${BACKUP_DIR}/restore/"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: ${cmd}"
  else
    eval "${cmd}"
  fi
}

# Concatenate the split backup files and extract them
function restore_split() {
  loginfo "Concatening split archive and extracting files"
  local cmd
  cmd="(cd ${BACKUP_DIR}/restore/ && ${NICE} -n${NICE_LEVEL} "
  cmd+="cat ${COMPRESS_DIR}/${RESTORE_FILE} | ${TAR} -x ${TAR_CFLAG} "
  cmd+="-f - -C ${BACKUP_DIR}/restore/ )"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: ${cmd}"
  else
    eval "${cmd}"
  fi
}

# The archive commands save permissions but the new directories need this
# @param directory path to chown
function restore_fix_perms() {
  loginfo "Fixing file ownership"
  if ${DRY_RUN}; then
    loginfo "DRY RUN: chown -R ${CASSANDRA_OG} ${1} "
  else
    chown -R ${CASSANDRA_OG} ${1}
  fi
}

# Do the heavy lifting of moving the files from the restore directory back to the
# correct target directories. This will also rename the current important directories
# in order to keep a local copy to roll back. This will then take the snapshot
function restore_files() {
  loginfo "Attempting to restore files"
  #temporarily move current files
  if ${DRY_RUN}; then
      loginfo "DRY RUN: Copying files from ${BACKUP_DIR}/restore/"
  else
    for i in "${data_file_directories[@]}"
    do
       loginfo "Renaming ${i} to ${i}_old_${DATE} if anything fails, manually rename it"
       mv "${i}" "${i}_old_${DATE}"
    done

    loginfo "Renaming ${commitlog_directory} to ${commitlog_directory}_old_${DATE} "\
      "if anything fails, manually rename it"
    mv "${commitlog_directory}" "${commitlog_directory}_old_${DATE}"

    loginfo "Renaming ${saved_caches_directory} to ${saved_caches_directory}_old_${DATE}"\
      " if anything fails, manually rename it"
    mv "${saved_caches_directory}" "${saved_caches_directory}_old_${DATE}"

    #copy the full paths back to the root directory exlude the Yaml File
    mkdir -p "${commitlog_directory}"
    restore_fix_perms "${commitlog_directory}"
    mkdir -p "${saved_caches_directory}"
    restore_fix_perms "${saved_caches_directory}"
    loginfo "Performing rsync commitlogs and caches from restore directory to full path"
    if [ -d "${BACKUP_DIR}/restore${commitlog_directory}" ]; then
      rsync -aH ${VERBOSE_RSYNC} ${BACKUP_DIR}/restore${commitlog_directory}/* ${commitlog_directory}/
    fi
    if [ -d "${BACKUP_DIR}/restore${saved_caches_directory}" ]; then
      rsync -aH ${VERBOSE_RSYNC} ${BACKUP_DIR}/restore${saved_caches_directory}/* ${saved_caches_directory}/
    fi

    for i in "${data_file_directories[@]}"
    do
      #have to recreate it since we moved the old one for safety
      mkdir -p ${i} && restore_fix_perms ${i}
      loginfo "Performing rsync data files from restore directory to full path ${i}"
      rsync -aH ${VERBOSE_RSYNC}  ${BACKUP_DIR}/restore${i}/*  ${i}/
      loginfo "Moving snapshot files up two directories to their keyspace base directories"
      #assume the snap* pattern is safe since no other
      # snapshots should have been copied in the backup process
      find ${i} -mindepth 2 -path '*/snapshots/snap*/*' -type f \
        -exec bash -c 'dir={}&& cd ${dir%/*} && mv {} ../..' \;
      restore_fix_perms ${i}
    done
  fi
}

# Stop the Cassandra service after flushing the transaction logs
# since we're doing a full restore in this case flushing is irrelevant
# but in future versions of this script there should be the option
# to restore a specific keyspace and stopping would require a flush first
function restore_stop_cassandra() {
  if ${DRY_RUN}; then
    loginfo "DRY RUN: Flushing and Stopping Cassandra"
    loginfo "DRY RUN: $NODETOOL ${USER_OPTIONS} " \
    "flush; service $SERVICE_NAME stop"
  else
    set +e
    #the following status script often throws an error, ignore it
    if $NODETOOL ${USER_OPTIONS}  status | grep -q "Connection refused"; then
      loginfo "Attempted to Stop Cassandra service but it seems to already be stopped"
    else
      $NODETOOL ${USER_OPTIONS} flush
      loginfo "Stopping Cassandra Service ${SERVICE_NAME} and sleep for 10 seconds"
      service ${SERVICE_NAME} stop
      sleep 10
    fi
    set -e
  fi
}

# If Cassandra is not part of a cluster then restart it. If it is part of a cluster,
# the restore must be completed for every node before restarting them, or the newer
# data on the other nodes will overwrite the old data that was just restored
function restore_start_cassandra() {
  if ${DRY_RUN}; then
      loginfo "DRY RUN: Starting Cassandra"
  else
    if "${AUTO_RESTART}"; then
      service ${SERVICE_NAME} start
    fi
  fi
}

# This will optionally go through and delete any copies of old data files
#if the -k --keep-old flag is set then it will not delete these files
function restore_cleanup() {
  if ${DRY_RUN}; then
    loginfo "DRY RUN: Would have deleted old data files"
  else
    if ${KEEP_OLD_FILES}; then
      loginfo "Keeping old files:"
      loginfo "  ${commitlog_directory}_old_${DATE}"
      loginfo "  ${saved_caches_directory}_old_${DATE}"
      loginfo "  ${BACKUP_DIR}/restore/"
    else
      loginfo "Deleting old files"
      rm -rf ${VERBOSE_RM} "${commitlog_directory}_old_${DATE}"
      rm -rf ${VERBOSE_RM} "${saved_caches_directory}_old_${DATE}"
      rm -rf ${VERBOSE_RM} "${BACKUP_DIR}/restore/"
    fi

    for i in "${data_file_directories[@]}"
    do
      if ${KEEP_OLD_FILES}; then
        loginfo "keeping old data: ${i}_old_${DATE}"
      else
        loginfo "deleting old data: ${i}_old_${DATE}"
        rm -rf ${VERBOSE_RM} "${i}_old_${DATE}"
     fi
    done
    rm -rf ${VERBOSE_RM} ${BACKUP_DIR}/restore
    rm -rf ${VERBOSE_RM} ${COMPRESS_DIR:?"aborting bad compress_dir"}/*
  fi
}

#restore should be performed by a person
#the -f option will force restore without confirmation
function restore_confirm() {

    if ${FORCE_RESTORE}; then
      return
    fi
    while true
    do
      read -p "Confirm: Stop Cassandra and restore the files \
      from ${BACKUP_DIR}/restore? Y or N" ans
      case $ans in
        [yY]* )
                echo "Okay, commencing restore";
                break
                ;;
        [nN]* )
                loginfo "Exiting restore"
                exit 0
                break
                ;;

            * )
                echo "Enter Y or N, please.";
                ;;
      esac
    done
}

# Transform long options to short ones
for arg in "$@"; do
  shift
  case "$arg" in

    "backup")   set -- "$@" "-B" ;;
    "restore")   set -- "$@" "-r" ;;
    "commands")
                    commands
                    exit 0
                    ;;
    "options")
                    options
                    exit 0
                    ;;
    "inventory") set -- "$@" "-I" ;;
    "--alt-hostname")   set -- "$@" "-a" ;;
    "--auth-file") set -- "$@" "-U" ;;
    "--gcsbucket") set -- "$@" "-b" ;;
    "--backupdir")   set -- "$@" "-d" ;;
    "--bzip")    set -- "$@" "-j" ;;
    "--clear-old-ss")   set -- "$@" "-c" ;;
    "--clear-old-inc")   set -- "$@" "-C" ;;
    "--download-only")   set -- "$@" "-D" ;;
    "--force")   set -- "$@" "-f" ;;
    "--help") set -- "$@" "-h" ;;
    "--home-dir") set -- "$@" "-H" ;;
    "--inc-commit-logs") set -- "$@" "-L" ;;
    "--incremental") set -- "$@" "-i" ;;
    "--log-dir")   set -- "$@" "-l" ;;
    "--keep-old")   set -- "$@" "-k" ;;
    "--noop")   set -- "$@" "-n" ;;
    "--nice")   set -- "$@" "-N" ;;
    "--service-name")   set -- "$@" "-S" ;;
    "--split-size")   set -- "$@" "-s" ;;
    "--target-gz-dir")   set -- "$@" "-T" ;;
    "--verbose")   set -- "$@" "-v" ;;
    "--with-caches")   set -- "$@" "-w" ;;
    "--yaml")   set -- "$@" "-y" ;;
    "--zip")   set -- "$@" "-z" ;;
    *)        set -- "$@" "$arg"
  esac
done

while getopts 'a:b:BcCd:DfhH:iIjkl:LnN:p:rs:S:T:u:U:vwy:z' OPTION
do
  case $OPTION in
      a)
          HOSTNAME=${OPTARG}
          ;;
      b)
          GCS_BUCKET=${OPTARG%/}
          ;;
      B)
          ACTION="backup"
          ;;
      c)
          CLEAR_SNAPSHOTS=true
          ;;
      C)
          CLEAR_INCREMENTALS=true
          ;;
      d)
          BACKUP_DIR=${OPTARG}
          ;;
      D)
          DOWNLOAD_ONLY=true
          ;;
      f)
          FORCE_RESTORE=true
          ;;
      h)
          print_usage
          exit 0
          ;;
      H)
          CASS_HOME=${OPTARG%/}
          ;;
      i)
          INCREMENTAL=true
          ;;
      I)
          ACTION="inventory"
          ;;
      j)
          BZIP=true
          COMPRESSION=true
          TAR_CFLAG="-j"
          TAR_EXT="tbz"
          ;;
      k)
          KEEP_OLD_FILES=true
          ;;
      l)
          LOG_OUTPUT=true
          [ -d ${OPTARG} ] && LOG_DIR=${OPTARG%/}
          ;;
      L)
          INCLUDE_COMMIT_LOGS=true
	        ;;
      n)
          DRY_RUN=true
          ;;
      N)
          NICE_LEVEL=${OPTARG}
          ;;
      p)
          CASSANDRA_PASS=${OPTARG}
          ;;
      r)
          ACTION="restore"
          ;;
      s)
          SPLIT_SIZE="${OPTARG/[a-z]*[A-Z]*}M" #replace letters with M
          SPLIT_FILE=true
          ;;
      S)
          SERVICE_NAME=${OPTARG}
          ;;
      T)
          COMPRESS_DIR=${OPTARG%/}
          ;;
      u)
          CASSANDRA_USER=${OPTARG}
          USE_AUTH=true
          ;;
      U)
          USER_FILE=${OPTARG}
          USE_AUTH=true
          ;;
      v)
          VERBOSE=true
          ;;
      w)
          INCLUDE_CACHES=true
          ;;
      y)
          YAML_FILE=${OPTARG}
          ;;
      z)
          COMPRESSION=true
          TAR_CFLAG="-z"
          TAR_EXT="tgz"
          ;;
      ?)
          print_help
          ;;
  esac
done

ACTION=${ACTION:-backup} # either backup or restore
AGE=5 #five minutes ago the last modified date of incremental backups to prune
AUTO_RESTART=true #flag set to false if Cassandra is part of a cluster
BACKUP_DIR=${BACKUP_DIR:-/cassandra/backups} # Backups base directory
BZIP=${BZIP:-false} #use bzip2 compression
CASSANDRA_PASS=${CASSANDRA_PASS:-''} #Password for Cassandra CQLSH account
CASSANDRA_USER=${CASSANDRA_USER:-''} #Username for Cassandra CQLSH account
CASSANDRA_OG="cassandra:cassandra" #modify this if you changed the system cassandra user and group
CLEAR_INCREMENTALS=${CLEAR_INCREMENTALS:-false} #flag to delete incrementals post snapshot
CLEAR_SNAPSHOTS=${CLEAR_SNAPSHOTS:-false} #clear old snapshots pre-snapshot
COMPRESS_DIR=${COMPRESS_DIR:-${BACKUP_DIR}/compressed} #directory to house backup archive
COMPRESSION=${COMPRESSION:-false} #flag to use tar+gz
CQLSH="$(which cqlsh)" #which cqlsh command
CQLSH_DEFAULT_HOST="127.0.0.1" #cqlsh host - currently hard coded
DATE="$(prepare_date +%F_%H-%M )" #nicely formatted date string for files
DOWNLOAD_ONLY=${DOWNLOAD_ONLY:-false} #user flag or used if incremental restore is requested
DRY_RUN=${DRY_RUN:-false} #flag to only print what would have executed
ERROR_COUNT=0 #used in validation step will exit if > 0
FORCE_RESTORE=${FORCE_RESTORE:-false} #flag to bypass restore confirmation prompt
GSUTIL="$(which gsutil)" #which gsutil script
HOSTNAME=${HOSTNAME:-"$(hostname)"} #used for gcs backup location
INCLUDE_CACHES=${INCLUDE_CACHES:-false} #include the saved caches for posterity
INCLUDE_COMMIT_LOGS=${INCLUDE_COMMIT_LOGS:-false} #include the commit logs for extra safety
INCREMENTAL=${INCREMENTAL:-false}  # flag to indicate only incremental files
KEEP_OLD_FILES=${KEEP_OLD_FILES:-false}
LOG_DIR=${LOG_DIR:-/var/log/cassandra} #where to write the log files
LOG_FILE="${LOG_DIR}/CassandraBackup${DATE}.log" #script log file
LOG_OUTPUT=${LOG_OUTPUT:-false} #flag to output to log file instead of stdout
NICE="$(which nice)" #which nice for low impact tar
NICE_LEVEL=${NICE_LEVEL:-10} ##10 is default nice level
NODETOOL="$(which nodetool)" #which nodetool
USER_OPTIONS="" #nodetool and cqlsh options
SCHEMA_DIR="${BACKUP_DIR}/schema" # schema backups directory
TOKEN_RING_DIR="${BACKUP_DIR}/token_ring" # token ring backups directory
SERVICE_NAME=${SERVICE_NAME:-cassandra} # sometimes the service name is different
SNAPSHOT_NAME=snap-${DATE} #name of new snapshot to take
SNAPSHOT_TIME="" #used to keep track of when the snapshot was taken
SPLIT_SIZE=${SPLIT_SIZE:-"100M"} #size of files if split command is used
SPLIT_FILE=${SPLIT_FILE:-false}  #whether or not to use the split command on backup archive
SUFFIX="snpsht" #Differentiates the two types of backup files
${INCREMENTAL} && SUFFIX="incr"  #If incremental mode change the file suffix
TAR="$(which tar)" #which tar command
TAR_EXT=${TAR_EXT:-tar} #default tar gzip file extension
TAR_CFLAG=${TAR_CFLAG:-""} #flag for tar to use gzip, if bzip is requested then -j
#TARGET_SCHEMA=${TARGET_SCHEMA:-schema} #Restore a specific Schema, not implemented yet
USE_AUTH=${USE_AUTH:-false} #flag to use cqlsh authentication
VERBOSE=${VERBOSE:-false} #prints detailed information
VERBOSE_RSYNC="" # add more detail to rsync when verbose mode is active
${VERBOSE} && VERBOSE_RSYNC="-v --progress"
VERBOSE_RM="" # add more detail to remove when verbose mode is active
${VERBOSE} && VERBOSE_RM="-v"
YAML_FILE=${YAML_FILE:-/etc/cassandra/cassandra.yaml} #Cassandra config file
ARCHIVE_FILE="cass-${DATE}-${SUFFIX}.${TAR_EXT}"
SPLIT_FILE_SUFFIX="cass-${DATE}-${SUFFIX}"
TARGET_LIST_FILE="${BACKUP_DIR}/${SUFFIX}_backup_files-${DATE}"
LAST_INC_BACKUP_TIME="" #used to keep track of the incremental backup time

# Validate input
validate
# Execute the requested action
eval $ACTION
