#!/bin/bash

DEBUG="${INPUT_DEBUG}"

if [[ "$DEBUG" == "true" ]]; then
  set -x
fi

mkdir -p /root/.ssh
echo "${INPUT_DST_KEY}" > /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa

DST_TOKEN="${INPUT_DST_TOKEN}"

SRC_HUB="${INPUT_SRC}"
DST_HUB="${INPUT_DST}"

SRC_ACCOUNT_TYPE="${INPUT_SRC_ACCOUNT_TYPE}"
DST_ACCOUNT_TYPE="${INPUT_DST_ACCOUNT_TYPE}"

SRC_TYPE=`dirname $SRC_HUB`
DST_TYPE=`dirname $DST_HUB`

SRC_ACCOUNT=`basename $SRC_HUB`
DST_ACCOUNT=`basename $DST_HUB`

CLONE_STYLE="${INPUT_CLONE_STYLE}"

CACHE_PATH="${INPUT_CACHE_PATH}"

WHITE_LIST="${INPUT_WHITE_LIST}"
BLACK_LIST="${INPUT_BLACK_LIST}"
STATIC_LIST="${INPUT_STATIC_LIST}"

FORCE_UPDATE="${INPUT_FORCE_UPDATE}"

function err_exit {
  echo -e "\033[31m $1 \033[0m"
  exit 1
}

function get_repo_list
{
  PARAM_REPO_LIST_API=$1
  shift
  PARAM_FN_OUT=$1
  shift

  FN_TMP=/tmp/tmp-mirror.txt
  rm -f "${PARAM_FN_OUT}" "${FN_TMP}"

  curl $PARAM_REPO_LIST_API > "${FN_TMP}"
  cat "${FN_TMP}" | jq '.[] | .name' |  sed 's/"//g' > "${PARAM_FN_OUT}"
  cnt=`cat "${PARAM_FN_OUT}" | wc -l`
  pg=2
  while [[ $cnt > 0 ]]; do
    curl "${PARAM_REPO_LIST_API}&page=$pg" | jq '.[] | .name' |  sed 's/"//g' > "${FN_TMP}"
    cat "${FN_TMP}" >> "${PARAM_FN_OUT}"
    cnt=`cat "${FN_TMP}" | wc -l`
    pg=$((pg + 1))
  done
}

if [[ "$SRC_ACCOUNT_TYPE" == "org" ]]; then
  SRC_LIST_URL_SUFFIX=orgs/$SRC_ACCOUNT/repos?per_page=100
elif [[ "$SRC_ACCOUNT_TYPE" == "user" ]]; then
  SRC_LIST_URL_SUFFIX=users/$SRC_ACCOUNT/repos?per_page=100
else
  err_exit "Unknown account type, the `src_account_type` should be `user` or `org`"
fi
if [[ "$DST_ACCOUNT_TYPE" == "org" ]]; then
  DST_LIST_URL_SUFFIX=orgs/$DST_ACCOUNT/repos?per_page=100
  DST_CREATE_URL_SUFFIX=orgs/$DST_ACCOUNT/repos
elif [[ "$DST_ACCOUNT_TYPE" == "user" ]]; then
  DST_LIST_URL_SUFFIX=users/$DST_ACCOUNT/repos?per_page=100
  DST_CREATE_URL_SUFFIX=user/repos
else
  err_exit "Unknown account type, the `dst_account_type` should be `user` or `org`"
fi

if [[ "$SRC_TYPE" == "github" ]]; then
  SRC_REPO_LIST_API=https://api.github.com/$SRC_LIST_URL_SUFFIX
  if [[ "$CLONE_STYLE" == "ssh" ]]; then
    SRC_REPO_BASE_URL=git@github.com:
  elif [[ "$CLONE_STYLE" == "https" ]]; then
    SRC_REPO_BASE_URL=https://github.com/
  fi
elif [[ "$SRC_TYPE" == "gitee" ]]; then
  SRC_REPO_LIST_API=https://gitee.com/api/v5/$SRC_LIST_URL_SUFFIX
  if [[ "$CLONE_STYLE" == "ssh" ]]; then
    SRC_REPO_BASE_URL=git@gitee.com:
  elif [[ "$CLONE_STYLE" == "https" ]]; then
    SRC_REPO_BASE_URL=https://gitee.com/
  fi
else
  err_exit "Unknown src args, the `src` should be `[github|gittee]/account`"
fi

if [[ -z $STATIC_LIST ]]; then
  get_repo_list ${SRC_REPO_LIST_API} "/tmp/tmp-repo-list-src.txt"
  SRC_REPOS=`cat "/tmp/tmp-repo-list-src.txt"`
else
  SRC_REPOS=`echo $STATIC_LIST | tr ',' ' '`
fi

if [[ "$DST_TYPE" == "github" ]]; then
  DST_REPO_CREATE_API=https://api.github.com/$DST_CREATE_URL_SUFFIX
  DST_REPO_LIST_API=https://api.github.com/$DST_LIST_URL_SUFFIX
  if [[ "$CLONE_STYLE" == "ssh" ]]; then
    DST_REPO_BASE_URL=git@github.com:
  elif [[ "$CLONE_STYLE" == "https" ]]; then
    DST_REPO_BASE_URL=https://github.com/
  fi
elif [[ "$DST_TYPE" == "gitee" ]]; then
  DST_REPO_CREATE_API=https://gitee.com/api/v5/$DST_CREATE_URL_SUFFIX
  DST_REPO_LIST_API=https://gitee.com/api/v5/$DST_LIST_URL_SUFFIX
  if [[ "$CLONE_STYLE" == "ssh" ]]; then
    DST_REPO_BASE_URL=git@gitee.com:
  elif [[ "$CLONE_STYLE" == "https" ]]; then
    DST_REPO_BASE_URL=https://gitee.com/
  fi
else
  err_exit "Unknown dst args, the `dst` should be `[github|gittee]/account`"
fi

function clone_repo
{
  echo -e "\033[31m(0/3)\033[0m" "Downloading..."
  if [ ! -d "$1" ]; then
    git clone $SRC_REPO_BASE_URL$SRC_ACCOUNT/$1.git
  fi
  cd $1
}

function create_repo
{
  # Auto create non-existing repo
  get_repo_list ${DST_REPO_LIST_API} "/tmp/tmp-mirror-list.txt"
  has_repo=`cat "/tmp/tmp-mirror-list.txt" | grep $1 | wc -l`
  if [ $has_repo == 0 ]; then
    echo "Create non-exist repo..."
    if [[ "$DST_TYPE" == "github" ]]; then
      curl -H "Authorization: token $2" --data '{"name":"'$1'"}' $DST_REPO_CREATE_API
    elif [[ "$DST_TYPE" == "gitee" ]]; then
      curl -X POST --header 'Content-Type: application/json;charset=UTF-8' $DST_REPO_CREATE_API -d '{"name": "'$1'","access_token": "'$2'"}'
    fi
  fi
  git remote add $DST_TYPE $DST_REPO_BASE_URL$DST_ACCOUNT/$1.git
}

function update_repo
{
  echo -e "\033[31m(1/3)\033[0m" "Updating..."
  git pull -p
}

function import_repo
{
  echo -e "\033[31m(2/3)\033[0m" "Importing..."
  git remote set-head origin -d
  git remote -v
  if [[ "$FORCE_UPDATE" == "true" ]]; then
    git push -f $DST_TYPE refs/remotes/origin/*:refs/heads/* --tags --prune
  else
    git push $DST_TYPE refs/remotes/origin/*:refs/heads/* --tags --prune
  fi
}

function _check_in_list () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

function test_black_white_list
{
  WHITE_ARR=(`echo $WHITE_LIST | tr ',' ' '`)
  BLACK_ARR=(`echo $BLACK_LIST | tr ',' ' '`)
  _check_in_list $1 "${WHITE_ARR[@]}";in_white_list=$?
  _check_in_list $1 "${BLACK_ARR[@]}";in_back_list=$?
  
  if [[ $in_back_list -ne 0 ]] ; then
    if [[ -z $WHITE_LIST ]] || [[ $in_white_list -eq 0 ]] ; then
      return 0
    else
      echo "Skip, "$1" not in non-empty white list"$WHITE_LIST
      return 1
    fi
  else
    echo "Skip, "$1 "in black list: "$BLACK_LIST
    return 1
  fi
}

if [ ! -d "$CACHE_PATH" ]; then
  mkdir -p $CACHE_PATH
fi
cd $CACHE_PATH

for repo in $SRC_REPOS
{
  if test_black_white_list $repo ; then
    echo -e "\n\033[31mBackup $repo ...\033[0m"

    clone_repo $repo || echo "clone and cd failed"

    create_repo $repo $DST_TOKEN || echo "create failed"

    update_repo || echo "Update failed"

    import_repo || err_exit "Push failed"

    cd ..
  fi
}
