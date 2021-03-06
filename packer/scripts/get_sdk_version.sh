#!/bin/bash

get_sdk_version() {
    repo_name=$1
    image_tag=$2
    submoduleFolder=$3
    commit_sha=$(echo $image_tag | cut -d"-" -f2)
    folderName=$(echo $repo_name | cut -d"/" -f2)
    git clone https://github.com/$repo_name --branch main && pushd $folderName && git checkout ${commit_sha}
    submodule_status=$(git submodule status)
    commit_msg=$(git log -1 --format=%s $submoduleFolder)
    sdk_version=$(echo $submodule_status | grep  "[0-9]*\.[0-9]*" -o || true)
    if [[ -z "$sdk_version" ]]; then
        sdk_version=$(echo $commit_msg | grep  "[0-9]*\.[0-9]*" -o || true)
    fi
    echo $sdk_version > /home/ubuntu/sdk_version.txt
    echo "copied sdk version to file" && popd
    rm -rf $folderName
}
