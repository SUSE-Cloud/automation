# Github_PR interactions (filter and action classes)

module GithubPR
  class JenkinsJobTriggerMkcloudAction < JenkinsJobTriggerAction
    def extra_parameters(pull, build_mode = "")
      job_base_name = "#{@metadata[:repository]} PR #{pull.number} #{pull.head.sha[0,8]}"
      github_pr_base = "#{@metadata[:org_repo]}:#{pull.number}:#{pull.head.sha}:#{pull.base.ref}"
      sub_context = build_mode == "standard" ? "":build_mode
      sub_context_suffix = sub_context.empty? ? "" : ":#{sub_context}"
      {
        job_name: "#{job_base_name} #{sub_context}",
        github_pr: "#{github_pr_base}#{sub_context_suffix}"
      }
    end
  end
end
