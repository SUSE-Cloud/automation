# Github_PR interactions (filter and action classes)

module GithubPR
  class JenkinsJobTriggerAction < RunCommandAction
    def logging?
      @c.has_key?("detail_logging") && @c["detail_logging"]
    end

    def action(pull)
      if logging? then
        LogPullRequestDetailsAction.new(@metadata).run([pull])
      end
      base_cmd = command("job_cmd")
      job_parameters(pull).each do |build_mode, job_paras|
        one_cmd = base_cmd + [@c["job_name"]] + parameters_to_cmd_paras(job_paras)
        system(*one_cmd) or raise
        puts "Triggering jenkins job for PR #{pull.number} in #{build_mode} mode"
      end
    end

    def parameters_to_cmd_paras(paras)
      paras.map{ |k,v| "#{k}=#{v}" }
    end

    def job_parameters(pull)
      @c["job_parameters"].map do |build_mode, build_paras|
        job_paras = build_paras
        if self.respond_to?(:extra_parameters) then
          job_paras.merge!(extra_parameters(pull, build_mode))
        end
        [ build_mode, job_paras ]
      end.to_h
    end
  end

  class JenkinsJobTriggerMkcloudAction < JenkinsJobTriggerAction
    def extra_parameters(pull, build_mode = "")
      job_base_name = "#{@metadata[:repository]} PR #{pull.number} #{pull.head.sha[0,8]}"
      github_pr_base = "#{@metadata[:org_repo]}:#{pull.number}:#{pull.head.sha}:#{pull.base.ref}"
      sub_context = build_mode == "standard" ? "":build_mode
      sub_context_suffix = sub_context.empty? ? "" : ":#{sub_context}"
      {
        "job_name" => "#{job_base_name} #{sub_context}",
        "github_pr" => "#{github_pr_base}#{sub_context_suffix}"
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
        "cloudsource" => CLOUDSOURCE[pull.base.ref]
      }) if CLOUDSOURCE.has_key?(pull.base.ref)
      para
    end
  end
end
