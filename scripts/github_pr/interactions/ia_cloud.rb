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

  class JenkinsJobTriggerMkcloudCCTAction < JenkinsJobTriggerMkcloudAction
    CLOUDSOURCE = {
      "master" => "develcloud8",
      "cloud7" => "develcloud7",
      "cloud6" => "develcloud6",
    }

    def extra_parameters(pull, build_mode = "")
      para = super(pull, build_mode)
      para.merge!({
        cloudsource: CLOUDSOURCE[pull.base.ref]
      }) if CLOUDSOURCE.has_key?(pull.base.ref)
      para
    end
  end

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
