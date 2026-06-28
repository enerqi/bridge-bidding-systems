# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
    if {([spades west] < 7) && ([spades east] < 7)} { reject }
    if {([hcp west]) + ([hcp east]) >= 15} { reject }
    # if {([hcp north] < 10) && ([hcp south] < 10)} { reject }

    if {[is_likely_3major_preempt west] || [is_likely_3major_preempt east]} { accept }
    if {[is_likely_4level_preempt west] || [is_likely_4level_preempt east]} { accept }
    reject
}
