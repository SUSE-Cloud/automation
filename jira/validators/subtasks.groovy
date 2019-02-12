import org.apache.log4j.Level

log.setLevel(Level.DEBUG)
log.info("Start Sub-Tasks Validation")

if (issue.isSubTask()) {
    log.info("Issue is no Sub-Task (true)")
    return true
}

issue.subTaskObjects.each {
    if (it.resolution == 0) {
        log.info("Issue has open Sub-Tasks (false)")
        return false
    }
}

log.info("End Sub-Tasks Validation (true)")
return true
