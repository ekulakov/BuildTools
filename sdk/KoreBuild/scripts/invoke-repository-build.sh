#!/usr/bin/env bash

__script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# flow failures thru piped commands, disallow unrecognized variables, and exit on first failure
set -euo pipefail

source "$__script_dir/common.sh"

__usage() {
    echo ""
    echo "Usage: $0 <PATH> [--verbose] [<MSBUILD_ARG>...]"
    echo ""
    echo "       <PATH>          The folder to build"
    echo "       --verbose       Produce more diagnostics about this build"
    echo "       <MSBUILD_ARG>   Argument passed to MSBuild. Multiple arguments allowed."
}

########
# main #
########

repo_path=''
if [[ $# > 0 ]]; then
    repo_path=$1
    shift
fi

msbuild_args=""
while [[ $# > 0 ]]; do
    case $1 in
        --verbose)
            __is_verbose=true
            ;;
        *)
            msbuild_args+="\"$1\"\n"
            ;;
    esac
    shift
done

if [ "$repo_path" == "" ] || [ ! -d $repo_path ]; then
    __error "Error: <PATH> was not provided or not found."
    __usage
    exit 1
fi

repo_path="$(cd $repo_path && pwd)"
__verbose "Building $repo_path"

version_file="$__script_dir/../.version"
if [ -f "$version_file" ]; then
    echo -e "${MAGENTA}Using KoreBuild $(cat "$version_file" | tail -1)${RESET}"
fi

echo "{ \"sdk\": { \"version\": \"$(__get_dotnet_sdk_version)\" } }" > "$repo_path/global.json"

korebuild_proj="$__script_dir/../KoreBuild.proj"
msbuild_artifacts_dir="$repo_path/artifacts/msbuild"
msbuild_response_file="$msbuild_artifacts_dir/msbuild.rsp"
msbuild_log_argument=""

if [ "$__is_verbose" = true ] || [ ! -z "${KOREBUILD_ENABLE_BINARY_LOG:-}" ]; then
    __verbose "Enabling binary logging"
    ms_build_log_file="$msbuild_artifacts_dir/msbuild.binlog"
    msbuild_log_argument="/bl:$ms_build_log_file"
fi

if [ ! -f $msbuild_artifacts_dir ]; then
    mkdir -p $msbuild_artifacts_dir
fi

cat > $msbuild_response_file <<ENDMSBUILDARGS
/nologo
/m
/p:RepositoryRoot="$repo_path/"
"$msbuild_log_argument"
/clp:Summary
"$korebuild_proj"
ENDMSBUILDARGS
echo -e "$msbuild_args" >> $msbuild_response_file

__verbose "dotnet = $(which dotnet)"

task_proj="$repo_path/build/tasks/RepoTasks.csproj"

if [ -f $task_proj ]; then
    __exec dotnet restore $task_proj
    task_publish_dir="$repo_path/build/tasks/bin/publish/"
    rm -rf $task_publish_dir || :
    __exec dotnet publish $task_proj --configuration Release --output $task_publish_dir /nologo
fi

__verbose "Invoking msbuild with '$(<$msbuild_response_file)'"
__exec dotnet msbuild @"$msbuild_response_file"

