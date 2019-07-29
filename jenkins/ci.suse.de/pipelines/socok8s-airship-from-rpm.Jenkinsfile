pipeline {

    options {
        timestamps()
        parallelsAlwaysFailFast()
        // Note(jhesketh): Unfortunately we can't set a global timeout for the
        //                 pipeline as it would also apply to the post stages
        //                 and hence interrupt our cleanup.
    }

    agent {
        node {
            label "cloud-ccp-ci"
        }
    }

    stages {
        stage('Set up container to run socok8s from') {
            steps {
                script {
                    // NOTE(jhesketh): The Jenkins worker(s) for this pipeline
                    //                 needs to have podman installed and
                    //                 configured for the jenkins user as a
                    //                 prerequisite. For example:
                    // zypper addrepo https://download.opensuse.org/repositories/Virtualization:/containers/openSUSE_Leap_15.0/ Virtualization:containers
                    // zypper --gpg-auto-import-keys refresh
                    // zypper install -yl podman
                    // usermod --add-subuids 65536-362144 jenkins
                    // usermod --add-subgids 65536-362144 jenkins

                    // Check if podman is installed
                    sh "which podman"

                    // Pull the latest leap-15 container image
                    sh "podman pull registry.opensuse.org/opensuse/leap/15.0/images/totest/images/opensuse-leap-15.0:current"

                    // Write env information to file
                    // use lowercase SOCOK8S_ENVNAME. CaaSP Velum doesn't like it otherwise
                    // NOTE(jhesketh): ENVNAME cannot be longer than 28-chars or else it will be truncated and cause errors (build number included)
                    sh 'echo SOCOK8S_ENVNAME="cloud-socok8s-rpm-${BUILD_NUMBER}" > jenkins.env'
                    sh 'echo OS_CLOUD="engcloud-cloud-ci" >> jenkins.env'
                    sh 'echo KEYNAME="engcloud-cloud-ci" >> jenkins.env'
                    sh 'echo DELETE_ANYWAY="YES" >> jenkins.env'
                    sh 'echo SOCOK8S_DEVELOPER_MODE="False" >> jenkins.env'
                    sh 'echo SOCOK8S_USE_VIRTUALENV="False" >> jenkins.env'
                    sh 'echo DEPLOYMENT_MECHANISM="openstack" >> jenkins.env'
                    sh 'echo ANSIBLE_STDOUT_CALLBACK="yaml" >> jenkins.env'
                    sh 'echo USER="root" >> jenkins.env'

                    // Start container
                    env.CONTAINER_ID = sh(
                        returnStdout: true,
                        script: "podman run --env-file jenkins.env --rm -dt registry.opensuse.org/opensuse/leap/15.0/images/totest/images/opensuse-leap-15.0:current"
                    ).trim()
                }
            }
        }

        stage('Install socok8s package') {
            steps {
                script {
                    // FIXME(jhesketh): Add in Cloud:Rocky repo which has
                    //                  up-to-date openstacksdk as a temporary
                    //                  work-around for
                    ///                 https://bugzilla.suse.com/show_bug.cgi?id=1137590
                    //                  (Alternatively could install a newer
                    //                  openstacksdk from pip or elsewhere).
                    in_container('zypper addrepo http://download.opensuse.org/repositories/Cloud:/OpenStack:/Rocky/openSUSE_Leap_15.0/ "Cloud OpenStack Rocky"')
                    // CA is required for accessing engcloud
                    in_container('zypper addrepo http://download.suse.de/ibs/SUSE:/CA/openSUSE_Leap_15.0/ "SUSE CA"')
                    // Add socok8s repo
                    in_container('zypper addrepo https://download.opensuse.org/repositories/Cloud:/socok8s/openSUSE_Leap_15.0/ "SUSE OpenStack Cloud on Kubernetes Preview"')
                    in_container('zypper --no-gpg-checks refresh')
                    in_container('zypper --no-gpg-checks install -yl ca-certificates-suse socok8s')
                }
            }
        }

        stage('Show environment information inside container') {
            steps {
                script {
                    in_container('printenv')
                }
            }
        }

        stage('Copy in cloud config and sshkey') {
            steps {
                script {
                    in_container('mkdir -p /root/.ssh')
                    sh 'podman cp ~/.ssh/id_rsa $CONTAINER_ID:/root/.ssh/id_rsa'
                    sh 'podman cp ~/.ssh/id_rsa.pub $CONTAINER_ID:/root/.ssh/id_rsa.pub'
                    in_container('touch /root/.ssh/known_hosts')
                    in_container('mkdir -p /etc/openstack')
                    sh 'podman cp ~/.config/openstack/clouds.yaml $CONTAINER_ID:/etc/openstack/clouds.yaml'
                }
            }
        }

        stage('Create network') {
            options {
                timeout(time: 10, unit: 'MINUTES', activity: true)
            }
            steps {
                socok8s_run("deploy_network")
            }
        }

        stage('Create VMs') {
            options {
                timeout(time: 45, unit: 'MINUTES', activity: true)
            }
            parallel {
                stage('Deploy CaaSP') {
                    steps {
                        socok8s_run("deploy_caasp")
                    }
                }
                stage('Deploy SES') {
                    steps {
                        socok8s_run("deploy_ses")
                    }
                }
                stage('Deploy CCP Deployer') {
                    steps {
                        socok8s_run("deploy_ccp_deployer")
                    }
                }
            }
        }

        stage('Configure CaaSP workers') {
            options {
                timeout(time: 10, unit: 'MINUTES', activity: true)
            }
            steps {
                socok8s_run("enroll_caasp_workers")
                socok8s_run("setup_caasp_workers_for_openstack")
            }
        }

        stage('Deploy Airship') {
            options {
                timeout(time: 45, unit: 'MINUTES', activity: true)
            }
            steps {
                socok8s_run("setup_airship")
            }
        }
    }

    post {
        failure {
            script {
                if (env.hold_instance_for_debug == 'true') {
                    echo "You can reach this node by connecting to its floating IP as root user, with the default password of your image."
                    timeout(time: 3, unit: 'HOURS') {
                        input(message: "Waiting for input before deleting env ${SOCOK8S_ENVNAME}.")
                    }
                }
            }
            script {
                socok8s_run('gather_logs')
            }
            zip archive: true, dir: 'logs/', zipFile: 'logs.zip'
            archiveArtifacts artifacts: 'logs.zip'
        }
        cleanup {
            script {
                // TODO(jhesketh): ensure the container is stopped even if `teardown` fails
                socok8s_run('teardown')
                sh 'podman container stop $CONTAINER_ID'
            }
        }
    }
}

def in_container(command) {
    sh("podman container exec $CONTAINER_ID " + command)
}

def socok8s_run(part) {
    in_container('/usr/share/socok8s/run.sh ' + part)
}
