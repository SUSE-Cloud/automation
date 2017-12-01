require_relative 'ia_cloud'

module GithubPR
  class JenkinsJobTriggerCrowbarTestbuildAction < JenkinsJobTriggerAction
    def extra_parameters(pull, _build_mode = "")
      {
        crowbar_repo: @metadata[:repository],
        crowbar_github_pr: "#{pull.number}:#{pull.head.sha}:#{pull.base.ref}",
        job_name: "#{@metadata[:org_repo]} testbuild PR #{pull.number} #{pull.head.sha[0,8]}",
      }
    end
  end
end
