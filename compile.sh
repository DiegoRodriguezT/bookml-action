#!/usr/bin/env bash

# input validation
if ! [[ $TIMEOUT_MINUTES =~ ^[0-9]+$ ]] ; then
  workflow="${GITHUB_WORKFLOW_REF%@*}"
  workflow=".github/workflows/${workflow#*/.github/workflows/}"
  workflow_lineno="$(sed -n '/timeout-minutes:/{=;q;}' < "$workflow")"
  echo "::error file=$workflow,line=${workflow_lineno:-1},title=Invalid timeout-minutes value::The value '$TIMEOUT_MINUTES' of timeout-minutes is not a positive integer."
  echo 'outcome=invalid' >> "$GITHUB_OUTPUT"
  exit 1
fi

### Download BookML image
case $SCHEME in
  full) scheme= ;;
  *) scheme="-$SCHEME" ;;
esac
IMAGE="ghcr.io/vlmantova/bookml$scheme:$VERSION"

echo "::group::Downloading BookML image \`$IMAGE\`"
docker pull "$IMAGE"
ret="$?"
if [[ $ret != 0 ]] ; then
  workflow="${GITHUB_WORKFLOW_REF%@*}"
  workflow=".github/workflows/${workflow#*/.github/workflows/}"
  workflow_lineno="$(sed -n '/scheme:/{=;q;}' < "$workflow")"
  workflow_lineno="${workflow_lineno:-$(sed -n '/version:/{=;q;}' < "$workflow")}"
  echo "::error file=$workflow,line=${workflow_lineno:-1},title=Could not download Docker image::Could not download Docker image $IMAGE. Check if version '$VERSION' and scheme '$SCHEME' are valid."
  echo 'outcome=invalid' >> "$GITHUB_OUTPUT"
  exit "$ret"
fi
echo "::endgroup::"
### end Download BookML image

### Compile with BookML image
echo "::add-matcher::$GITHUB_ACTION_PATH/bookml.json"
restartToken="restart-commands-$RANDOM$RANDOM"
echo "::stop-commands::$restartToken"

# TODO: parallel build
docker run --rm --interactive=true --volume="$GITHUB_WORKSPACE":/source \
  --volume="$RUNNER_TEMP/auxdir":/auxdir --volume="$GITHUB_OUTPUT":/github-output\
  --env=REPLACE_BOOKML="$REPLACE_BOOKML" --env=TIMEOUT_MINUTES="$TIMEOUT_MINUTES" \
  --entrypoint /bin/bash "$IMAGE" -s <<'EOF' \
  --env=FOLDERS="$FOLDERS" --env=FORMATS="$FORMATS"
cd /source

if [[ $REPLACE_BOOKML == true ]] ; then
  /run-bookml update || echo '::error title=Could not replace the bookml/ folder::Could not replace the bookml/ folder.'
fi

export max_print_line=10000

combined_log=/auxdir/bookml-report.log
: > "$combined_log"

mapfile -t tex_files < <(grep -rl --include='*.tex' --exclude-dir=.git --exclude-dir=bookml '\\documentclass' . || :)

if [[ ${#tex_files[@]} -eq 0 ]] ; then
  outcome=success
  targets=
  outputs=
else
  declare -A seen_dirs
  dirs=()
  for tex_file in "${tex_files[@]}" ; do
    tex_file="${tex_file#./}"
    dir="${tex_file%/*}"
    if [[ $dir == "$tex_file" ]] ; then
      dir="."
    fi
    dir="${dir#./}"
    if [[ -z ${seen_dirs[$dir]} ]] ; then
      seen_dirs[$dir]=1
      dirs+=("$dir")
    fi
  done

  if [[ -n $FOLDERS ]] ; then
    declare -a filter_folders
    read -r -a filter_folders <<< "$FOLDERS"
    declare -A filter_map
    for f in "${filter_folders[@]}" ; do
      filter_map[$f]=1
    done
    declare -a filtered_dirs
    for d in "${dirs[@]}" ; do
      if [[ -n ${filter_map[$d]} ]] ; then
        filtered_dirs+=("$d")
      fi
    done
    dirs=("${filtered_dirs[@]}")
  fi

  outcome=success
  targets_list=()
  outputs_list=()
  dir_index=0

  for dir in "${dirs[@]}" ; do
    dir_index=$((dir_index + 1))
    aux_dir="/auxdir/run-$dir_index"
    mkdir -p "$aux_dir"
    run_log="$aux_dir/bookml-report.log"

    echo "=== Directory: ${dir:-.} ===" >> "$combined_log"
    pushd "/source/${dir:-.}" >/dev/null
    timeout "$TIMEOUT_MINUTES"m /run-bookml -k all ${FORMATS:+FORMATS="$FORMATS"} AUX_DIR="$aux_dir" 2>&1 | tee -a "$run_log" >> "$combined_log"
    run_ret="${PIPESTATUS[0]}"
    popd >/dev/null

    case "$run_ret" in
      124|137) outcome=timeout
        echo "::error title=Compiling timed out::Increase \`timeout-minutes\` to allow more time." ;;
      0) : ;;
      *) [[ $outcome != timeout ]] && outcome=failure ;;
    esac

    run_targets="$(grep '^ Targets: ' < "$run_log" | head -n 1 | sed -E -e 's/^.*:\s*|(\s| )*$//g')"
    if [[ -n $run_targets ]] ; then
      read -r -a run_targets_arr <<< "$run_targets"
      for target in "${run_targets_arr[@]}" ; do
        if [[ -n $dir && $dir != "." ]] ; then
          prefixed="$dir/$target"
        else
          prefixed="$target"
        fi
        targets_list+=("$prefixed")
        if [[ -e "/source/$prefixed" ]] ; then
          outputs_list+=("$prefixed")
        fi
      done
    fi
  done

  targets="${targets_list[*]}"
  outputs="${outputs_list[*]}"
fi

echo "outcome=$outcome" >> /github-output
echo "targets=$targets" >> /github-output
echo "outputs=$outputs" >> /github-output
EOF

echo "::$restartToken::"
echo "::remove-matcher owner=bookml-latex-errors::"
echo "::remove-matcher owner=bookml-latexml-errors::"
echo "::remove-matcher owner=bookml-latexml-warnings::"

grep -q '^outcome=success$' "$GITHUB_OUTPUT"

### end Compile with BookML image
