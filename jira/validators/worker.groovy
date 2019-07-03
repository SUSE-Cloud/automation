import org.apache.log4j.Level
import com.atlassian.jira.component.ComponentAccessor
import com.atlassian.jira.user.ApplicationUser
import com.opensymphony.workflow.WorkflowContext

log.setLevel(Level.DEBUG)
log.info("Start Worker Validation")

// If resolution is Rejected or Deferred return always true
if ((issue.resolutionObject.name == "Rejected" || issue.resolutionObject.name == "Deferred")) {
    log.info("Status is Rejected or Deferred (true)")
    return true
}

// Check that we have a Worker
def customFieldManager = ComponentAccessor.getCustomFieldManager()
def workerCf = customFieldManager.getCustomFieldObjectByName("Worker")
def worker = issue.getCustomFieldValue(workerCf)
def noneuser = ComponentAccessor.getUserManager().getUserByName("None")

if (worker && worker != noneuser) {
    log.info("Worker is assigned (true)")
    return true
}

log.info("Worker is empty (false)")
return false
