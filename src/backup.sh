# This file deals with backing up and restoring kw data files stored under the
# the KW_DATA_DIR directory. These files are configs, pomodoro reports and
# kw usage statistics.

include "$KW_LIB_DIR/kwlib.sh"
include "$KW_LIB_DIR/kw_string.sh"
include "$KW_LIB_DIR/kwio.sh"
include "$KW_LIB_DIR/kw_time_and_date.sh"

declare -gA options_values
decompress_path="$KW_CACHE_DIR/tmp-kw-backup"

# This is the main function that deals with the operations related to backup. It
# recieves an argument and call other functions based on that.
function backup()
{
  parse_backup_options "$@"
  if [[ "$?" -gt 0 ]]; then
    complain "${options_values['ERROR']}"
    return 22 # EINVAL
  fi

  if [[ -n "${options_values['BACKUP_PATH']}" ]]; then
    create_backup "${options_values['BACKUP_PATH']}"
    return
  fi

  if [[ -n "${options_values['RESTORE_PATH']}" ]]; then
    restore_backup "${options_values['RESTORE_PATH']}"
    return
  fi
}

# This function creates a .tar.gz file containing all the data found in
# KW_DATA_DIR
#
# @path Path to the directory in which the compressed file should be stored.
function create_backup()
{
  local path="$1"
  local flag="$2"
  local file_name
  local current_time
  local ret

  flag=${flag:-'SILENT'}

  if [[ ! -d "$path" ]]; then
    complain 'We could not find the path'
    exit 2 # ENOENT
  fi

  current_time=$(date +%Y-%m-%d_%H-%M-%S)
  file_name="kw-backup-$current_time.tar.gz"
  generate_tarball "$KW_DATA_DIR" "$path/$file_name" 'gzip' '' "$flag"

  ret="$?"
  if [[ "$ret" != 0 ]]; then
    complain 'We could not create the tar file'
    exit "$ret"
  fi

  success 'Backup successfully created at' "$path/$file_name"
}

# This function restores a previous backup by extracting it back into
# KW_DATA_DIR.
#
# #path Path to the .tar.gz containing kw data
function restore_backup()
{
  local path="$1"
  local flag="$2"
  local ret
  local config_file
  local difference

  flag=${flag:-'SILENT'}

  if [[ ! -f "$path" ]]; then
    complain 'We could not find this file'
    exit 2 # ENOENT
  fi

  if [[ -n "${options_values['FORCE']}" ]]; then
    decompress_path="$KW_DATA_DIR"
  else
    mkdir -p "$decompress_path"
  fi
  extract_tarball "$path" "$decompress_path" 'gzip' "$flag"

  ret="$?"
  if [[ "$ret" != 0 ]]; then
    complain 'We could not extract the tar file'
    exit "$ret"
  fi

  if [[ -z "${options_values['FORCE']}" ]]; then
    restore_config
    restore_pomodoro
    restore_statistics
  fi

  success "Backup restored at $KW_DATA_DIR"
}

# This function restores the config folder from KW_DATA_DIR
#
function restore_config()
{
  local config_file

  if [[ -d "$decompress_path/"configs ]]; then
    mkdir -p "$KW_DATA_DIR/configs/configs"
    mkdir -p "$KW_DATA_DIR/configs/metadata"

    for file in "$decompress_path/"configs/configs/*; do
      config_file="$(get_file_name_from_path "$file")"
      if [[ -f "$KW_DATA_DIR/configs/configs/$config_file" ]] &&
        ! cmp -s "$KW_DATA_DIR/configs/configs/$config_file" "$file"; then
        complain "It looks like that the file $config_file differs from the backup version."
        diff -u --color=always "$KW_DATA_DIR/configs/configs/$config_file" "$file"
        if [[ $(ask_yN 'Do you want to replace it and its metadata?') =~ "0" ]]; then
          continue
        fi
      fi
      cp -r "$decompress_path/configs/configs/$config_file" "$KW_DATA_DIR/configs/configs"
      cp -r "$decompress_path/configs/metadata/$config_file" "$KW_DATA_DIR/configs/metadata"
    done
  fi
}

function restore_data_from_dir()
{
  local dir="$1"
  local decision
  local year
  local month
  local day
  local difference

  for year_dir in "$decompress_path/$dir/"*/; do
    year="$(str_remove_prefix "$year_dir" "$decompress_path/$dir/")"
    mkdir -p "$KW_DATA_DIR/$dir/$year"
    for month_dir in "$year_dir"*; do
      month="$(str_remove_prefix "$month_dir" "$decompress_path/$dir/$year")"
      mkdir -p "$KW_DATA_DIR/$dir/$year$month"
      for day_file in "$month_dir"/*; do
        day="$(str_remove_prefix "$day_file" "$decompress_path/$dir/$year$month/")"
        if [[ -f "$KW_DATA_DIR/$dir/$year$month/$day" ]] &&
          ! cmp -s "$KW_DATA_DIR/$dir/$year$month/$day" "$day_file"; then
          if [[ -z "$decision" ]]; then
            complain "It looks like that the file $year$month/$day differs from the backup version."
            complain "Do you want to:"
            say "(1) Replace all duplicate files with backup"
            say "(2) Keep all the old files"
            say "(3) Aggregate all old and backup files"
            read -r decision
          fi

          case "$decision" in
            1)
              cp "$day_file" "$KW_DATA_DIR/$dir/$year$month/$day"
              continue
              ;;
            2)
              continue
              ;;
            3)
              difference=$(diff -u "$KW_DATA_DIR/$dir/$year$month/$day" "$day_file")
              patch "$KW_DATA_DIR/$dir/$year$month/$day" <<< "$difference"
              continue
              ;;
          esac
        fi
        cp "$day_file" "$KW_DATA_DIR/$dir/$year$month/$day"
      done
    done
  done
}

function restore_pomodoro()
{
  local decision
  local difference

  if [[ -d "$decompress_path/pomodoro" ]]; then
    restore_data_from_dir 'pomodoro'

    if [[ -f "$decompress_path/pomodoro/tags" ]]; then
      if [[ -f "$KW_DATA_DIR/pomodoro/tags" ]] &&
        ! cmp -s "$KW_DATA_DIR/pomodoro/tags" "$decompress_path/pomodoro/tags"; then
        if [[ -z "$decision" ]]; then
          complain 'pomodoro/tags already exists'
          complain 'Do you want to:'
          say "(1) Replace it"
          say "(2) Keep it"
          say "(3) Aggregate it"
          read -r decision
        fi
        case "$decision" in
          1)
            cp "$decompress_path/pomodoro/tags" "$KW_DATA_DIR/pomodoro/tags"
            ;;
          2)
            return
            ;;
          3)
            difference=$(diff -u "$KW_DATA_DIR/pomodoro/tags" "$decompress_path/pomodoro/tags")
            patch "$KW_DATA_DIR/pomodoro/tags" <<< "$difference"
            ;;
        esac
        return
      fi
      cp "$decompress_path/pomodoro/tags" "$KW_DATA_DIR/pomodoro/tags"
    fi
  fi
}

function restore_statistics()
{
  if [[ -d "$decompress_path/statistics" ]]; then
    restore_data_from_dir 'statistics'
  fi
}

# This function parses the arguments provided to 'kw backup', validates them,
# and populates the options_values variable accordingly.
function parse_backup_options()
{
  local long_options='help,restore:,force'
  local short_options='h,r:,f'

  options="$(kw_parse "$short_options" "$long_options" "$@")"

  if [[ "$?" != 0 ]]; then
    options_values['ERROR']="$(kw_parse_get_errors 'kw backup' "$short_options" \
      "$long_options" "$@")"
    return 22 # EINVAL
  fi

  # Default values
  options_values['RESTORE_PATH']=''
  options_values['BACKUP_PATH']=''
  options_values['FORCE']=''

  eval "set -- $options"

  if [[ "$#" == 1 ]]; then
    options_values['BACKUP_PATH']="$PWD"
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --help | -h)
        backup_help "$1"
        exit
        ;;
      --restore | -r)
        options_values['RESTORE_PATH']+="$2"
        shift 2
        ;;
      --force | -f)
        options_values['FORCE']=1
        shift
        ;;
      --)
        shift
        ;;
      *)
        options_values['BACKUP_PATH']="$1"
        shift
        ;;
    esac
  done
}

function backup_help()
{
  if [[ "$1" == --help ]]; then
    include "$KW_LIB_DIR/help.sh"
    kworkflow_man 'backup'
    return
  fi
  printf '%s\n' 'kw backup:' \
    '  backup (<path>) - Create a compressed file containing kw data' \
    '  backup (-r | --restore) <path> [(-f | --force)] - Extract a tar.gz file into kw data directory'
}
