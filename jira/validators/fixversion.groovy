import org.apache.log4j.Level

log.setLevel(Level.DEBUG)
log.info("Start FixVersion Validation")

// If resolution is not Fixed or Done return always true
if (!(issue.resolutionObject.name == "Fixed" || issue.resolutionObject.name == "Done")) {
    log.info("Status is not Fixed or Done (true)")
    return true
}

// Check that we have FixedVersions
if (issue.getFixVersions().isEmpty()) {
    log.info("FixedVersions is empty (false)")
    return false
}

// Check that all AffectedVersions are Fixed
if (issue.getAffectedVersions().size() <= issue.getFixVersions().size()) {
    log.info("All AffectedVersions are fixed (true)")
    return true
}

log.info("Not all AffectedVersions are Fixed (false)")
return false
