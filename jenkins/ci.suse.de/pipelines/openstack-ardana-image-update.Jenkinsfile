/**
 * The openstack-ardana-image-update Jenkins Pipeline
 * This job automates updating the base SLES image used by virtual cloud nodes.
 */

pipeline {
  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label 'cloud-ardana-ci'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {

    stage('Setup workspace') {
      steps {
        script {
          currentBuild.displayName = "#${BUILD_NUMBER}: ${sles_image}"
        }
      }
    }

    stage('upload new image version') {
      steps {
        sh '''
          wget -qO- ${download_image_url} | xz -d > ${sles_image}.qcow2

          # The cloud-ci user cannot create public images or change their
          # membership; until that is resolved by updating its privileges,
          # resort to doing everything twice, once for the 'cloud-ci'
          # project and a second time for the 'cloud' project
          for os_cloud in engcloud-cloud-ci-private engcloud-cloud-ci; do
              openstack --os-cloud $os_cloud image show ${sles_image}-update && \
                  openstack --os-cloud $os_cloud image delete ${sles_image}-update

              openstack --os-cloud $os_cloud image create \
                  --file ${sles_image}.qcow2 \
                  --disk-format qcow2 \
                  --container-format bare \
                  --private \
                  ${sles_image}-update
          done
        '''
      }
    }

    stage('integration test') {
      steps {
        script {
          def slaveJob = build job: openstack_ardana_job, parameters: [
              string(name: 'sles_image', value: "${sles_image}-update"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch")
          ], propagate: true, wait: true
        }
      }
    }
  }
  post {
    success {
      sh '''
          # The cloud-ci user cannot create public images or change their
          # membership; until that is resolved by updating its privileges,
          # resort to doing everything twice, once for the 'cloud-ci'
          # project and a second time for the 'cloud' project
          for os_cloud in engcloud-cloud-ci-private engcloud-cloud-ci; do
              openstack --os-cloud $os_cloud image set \
                  --name ${sles_image}-$(date +%Y%m%d) \
                  --deactivate \
                  ${sles_image}

              openstack --os-cloud $os_cloud image set \
                  --name ${sles_image} \
                  ${sles_image}-update
          done
      '''
    }
    cleanup {
      cleanWs()
    }
  }
}
