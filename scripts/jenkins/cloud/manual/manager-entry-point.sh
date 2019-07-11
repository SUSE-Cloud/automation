#!/bin/bash -i

: ${uid:=-1}
: ${gid:=-1}
: ${user:=0}
: ${git_user_name:=Unknown User}
: ${git_user_email:=unknown@unknown.org}
: ${python:=python2}

create_user() {
    if (( ${uid} > 0 && ${gid} > 0 )); then
        user=${uid}
        groupadd --gid ${gid} ci
        useradd --uid ${uid} --gid ${gid} \
            --no-create-home \
            --home-dir /opt/automation ci
        cat <<EOF | sudo --user \#${uid} tee /opt/automation/.bashrc
if [[ \$(id --user) == 0 ]] ; then
   PS1='\[\033[01;31m\]\h\[\033[01;34m\] \w \$\[\033[00m\] '
else
   PS1='\[\033[01;32m\]\u@\h\[\033[01;34m\] \w \$\[\033[00m\] '
fi
alias ls='\ls --color=auto'
alias ll='\ls -l --human-readable --color=auto'
alias la='\ls -l --all --human-readable --color=auto'
export ANSIBLE_VENV=/opt/ansible-venv
export CLIFF_FIT_WIDTH=1
source /opt/ansible-venv/bin/activate
source ~/scripts/jenkins/cloud/manual/lib.sh
cd ~/scripts/jenkins/cloud/manual
EOF
    fi
}

configure_git() {
    sudo --user \#${user} git config --global user.name "${git_user_name}"
    sudo --user \#${user} git config --global user.email "${git_user_email}"
}

set_up_venv() {
    if [[ ! -L /opt/ansible-venv ]]; then
        ln -s "/opt/ansible-venv-${python}" /opt/ansible-venv
    fi
}

copy_clouds() {
    /opt/ansible-venv-python3/bin/python /opt/bin/manager_copy_clouds.py \
        --set cacert:/usr/share/pki/trust/anchors/SUSE_Trust_Root.crt.pem \
        /opt/openstack /etc/openstack/clouds.yaml
}

set -u -x

while (( $# > 0 )); do
    case $1 in
        "--uid")
            shift
            if ! (( uid = $1 )); then
                echo "error parsing uid $1"
                exit 1
            fi
            shift
            ;;
        "--gid")
            shift
            if ! (( gid = $1 )); then
                echo "error parsing gid $1"
                exit 1
            fi
            shift
            ;;
        "--git-user-name")
            shift
            git_user_name=$1
            shift
            ;;
        "--git-user-email")
            shift
            git_user_email=$1
            shift
            ;;
        "--python2"|"--python3")
            python=${1#--}
            shift
            ;;
        "-h"|"--help")
            shift
            cat <<EOF
Usage:

--uid UID                 Create user with UID
--gid GID                 Create user with GID
--git-user-name NAME      Set the global git username to NAME
--git-user-email EMAIL    Set the global git email address to EMAIL
--python2 | --python3     Use the Python2/Python3 virtualenv
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument $1, terminating parsing"
            break
            ;;
    esac
done

create_user
configure_git
set_up_venv
copy_clouds

set +x

sudo --user \#${user} --login bash -- "$@"
