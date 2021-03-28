# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
    if {![5CM_nt east 17 19] && ![is_strong_1c east]} { reject }

    if {[hcp south]>=10 && [majors_4_4 south]} { accept }
    if {[hcp south]>8 && ![flattish south]} { accept }
    if {[hcp south]>8 && [has_9_plus_majors south]} { accept }
    if {[hcp south]>5 && [two_suiter south]} { accept }

    reject
}
