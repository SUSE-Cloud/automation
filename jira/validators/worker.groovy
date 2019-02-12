import org.apache.log4j.Level
import com.atlassian.jira.component.ComponentAccessor
import com.atlassian.jira.user.ApplicationUser
import com.opensymphony.workflow.WorkflowContext

log.setLevel(Level.DEBUG)
log.info("Start Worker Validation")

// Check that we have a Worker
def customFieldManager = ComponentAccessor.getCustomFieldManager()
def workerCf = customFieldManager.getCustomFieldObjectByName("Worker")
def worker = issue.getCustomFieldValue(workerCf)
if (worker && worker != "unassigned") {
    log.info("Worker is assigned (true)")
    return true
}

log.info("Worker is empty (false)")
return false
