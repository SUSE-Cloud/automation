import org.apache.log4j.Level

log.setLevel(Level.DEBUG)
log.info("Start Sub-Tasks Validation")

if (issue.isSubTask()) {
    log.info("Issue is no Sub-Task (true)")
    return true
}

def boolean result = true
issue.subTaskObjects.each {
    if (it.getStatus().getStatusCategory().getName() != "Complete") {
        log.info("Issue has open Sub-Tasks (false)")
        result = false
    }
}

log.info("End Sub-Tasks Validation ($result)")
return result
