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

          openstack --os-cloud $os_cloud image show ${sles_image}-update && \
              openstack --os-cloud $os_cloud image delete ${sles_image}-update

          openstack --os-cloud $os_cloud image create \
              --file ${sles_image}.qcow2 \
              --disk-format qcow2 \
              --container-format bare \
              --${image_visibility} \
              ${sles_image}-update

          if [[ $image_visibility == shared ]]; then
              # Share the image will all the other projects that the default CI user has access to
              image_props=($(openstack --os-cloud $os_cloud image show -f value -c id -c owner ${sles_image}-update))
              image_uuid=${image_props[0]}
              image_owner=${image_props[1]}
              other_projects=$(openstack --os-cloud $os_cloud --os-interface public project list -f value -c ID | grep -v "${image_owner}")

              for project in $other_projects; do
                  openstack --os-cloud $os_cloud --os-interface public image add project ${sles_image}-update $project
                  openstack --os-cloud $os_cloud --os-project-id $project image set --accept $image_uuid
              done
          fi
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
          openstack --os-cloud $os_cloud image set \
              --name ${sles_image}-$(date +%Y%m%d) \
              --deactivate \
              ${sles_image}

          openstack --os-cloud $os_cloud image set \
              --name ${sles_image} \
              ${sles_image}-update
      '''
    }
    cleanup {
      cleanWs()
    }
  }
}
