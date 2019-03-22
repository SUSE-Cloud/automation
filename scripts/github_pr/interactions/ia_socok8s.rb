require_relative 'ia_cloud'

module GithubPR
  class JenkinsJobTriggerSocok8sAction < JenkinsJobTriggerAction
    def extra_parameters(pull, _build_mode = "")
      {
        socok8s_repo: @metadata[:repository],
        socok8s_org: @metadata[:organization],
        socok8s_github_pr: "#{pull.number}:#{pull.head.sha}:#{pull.base.ref}",
        job_name: "#{@metadata[:org_repo]} PR #{pull.number} #{pull.head.sha[0,8]}",
      }
    end
  end
end
