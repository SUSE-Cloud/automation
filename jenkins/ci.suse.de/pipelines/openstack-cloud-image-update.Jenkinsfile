/**
 * The openstack-cloud-image-update Jenkins Pipeline
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
      label 'cloud-ci'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {

    stage('Setup workspace') {
      steps {
        script {
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')

          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)

          currentBuild.displayName = "#${BUILD_NUMBER}: ${sles_image}"
        }
      }
    }

    stage('upload new image version') {
      steps {
        sh '''
          # Get all projects that should have access to the image (all the projects
          # to which the cloud CI user has access)
          all_projects=$(openstack --os-cloud $os_cloud --os-interface public --os-project-name $os_project_name \
                           project list -f value -c ID)
          this_project=$(openstack --os-cloud $os_cloud --os-interface public --os-project-name $os_project_name \
                           project show -f value -c id $os_project_name)

          # The cloud CI user cannot create public images or change their
          # membership; until that is resolved (e.g. by updating its privileges),
          # either use a shared image or update multiple private images.
          if [[ $image_visibility == private ]]; then
              project_list=$all_projects
          else
              project_list=$this_project
          fi

          if [[ $download_image_url == *".xz" ]]; then
              wget -qO- ${download_image_url} | xz -d > ${sles_image}.qcow2
          else
              wget -q ${download_image_url} -O ${sles_image}.qcow2
          fi

          for project_id in $project_list; do
              openstack --os-cloud $os_cloud --os-project-id $project_id image show ${sles_image}-update && \
                openstack --os-cloud $os_cloud --os-project-id $project_id image delete ${sles_image}-update
              image_uuid=$(openstack --os-cloud $os_cloud --os-project-id $project_id image create \
                                     --file ${sles_image}.qcow2 \
                                     --disk-format qcow2 \
                                     --container-format bare \
                                     --${image_visibility} \
                                     --property hw_rng_model='virtio' \
                                     --property hw_vif_multiqueue_enabled='True' \
                                     -f value -c id \
                                     ${sles_image}-update)
          done

          if [[ $image_visibility == shared ]]; then
              for project_id in $all_projects; do
                  [[ $project_id == $this_project ]] && continue

                  # Share the image will all the other projects that the default CI user has access to
                  openstack --os-cloud $os_cloud --os-interface public --os-project-id $this_project \
                      image add project ${sles_image}-update $project_id
                  openstack --os-cloud $os_cloud --os-project-id $project_id image set --accept $image_uuid
              done
          fi
        '''
      }
    }

    stage('integration test') {
      steps {
        script {
          // reserve a resource here for the integration job, to avoid
          // keeping a cloud-ci worker busy while waiting for a
          // resource to become available.
          cloud_lib.run_with_reserved_env(reserve_env.toBoolean(), cloud_env, cloud_env) {
            reserved_env ->
            cloud_lib.trigger_build(openstack_cloud_job, [
              string(name: 'cloud_env', value: reserved_env),
              string(name: 'reserve_env', value: "false"),
              string(name: 'os_cloud', value: os_cloud),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
              text(name: 'extra_params', value: "$extra_params\nsles_image=${sles_image}-update")
            ])
          }
        }
      }
    }
  }
  post {
    success {
      sh '''
          # Get all projects that should have access to the image (all the projects
          # to which the cloud CI user has access)
          all_projects=$(openstack --os-cloud $os_cloud --os-interface public --os-project-name $os_project_name \
                           project list -f value -c ID)
          this_project=$(openstack --os-cloud $os_cloud --os-interface public --os-project-name $os_project_name \
                           project show -f value -c id $os_project_name)

          # The cloud CI user cannot create public images or change their
          # membership; until that is resolved (e.g. by updating its privileges),
          # either use a shared image or update multiple private images.
          if [[ $image_visibility == private ]]; then
              project_list=$all_projects
              visible_project_list=$this_project
          else
              project_list=$this_project
              visible_project_list=$all_projects
          fi

          for project_id in $project_list; do
              openstack --os-cloud $os_cloud --os-project-id $project_id image show ${sles_image} && \
                  openstack --os-cloud $os_cloud --os-project-id $project_id image set \
                      --name ${sles_image}-$(date +%Y%m%d) \
                      --deactivate \
                      ${sles_image}

              openstack --os-cloud $os_cloud --os-project-id $project_id image set \
                  --name ${sles_image} \
                  ${sles_image}-update

              # Check if the old images are still used in any of the projects where it is visible
              # and delete those that are no longer used

              old_images=$(openstack --os-cloud $os_cloud --os-project-id $project_id \
                           image list --status deactivated -f value -c Name|grep "${sles_image}-" || :)
              for old_image in $old_images; do
                  in_use=false
                  for visible_project in $visible_project_list; do
                      servers_count=$(openstack --os-cloud $os_cloud --os-project-id $visible_project \
                                      server list -f value -c Name --image $old_image|wc -l)
                      if [[ $servers_count > 0 ]]; then
                          echo "Image $old_image is still in use by $servers_count servers in project $visible_project, skipping..."
                          in_use=true
                          break
                      fi
                  done
                  if ! $in_use; then
                      echo "Image $old_image is no longer in use, deleting..."
                      openstack --os-cloud $os_cloud --os-project-id $project_id image delete $old_image || :
                  fi
              done
          done
      '''
    }
    cleanup {
      cleanWs()
    }
  }
}
