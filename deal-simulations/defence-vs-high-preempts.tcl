# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
    if {[is_minors_2n_preempt west] || [is_minors_2n_preempt east]} { accept }
    if {[is_shapely_minor_preempt west] || [is_shapely_minor_preempt east]} { accept }
    if {[is_standard_3cd_7carder west] || [is_standard_3cd_7carder east]} { accept }
    if {[is_likely_3major_preempt west] || [is_likely_3major_preempt east]} { accept }
    if {[is_likely_4level_preempt west] || [is_likely_4level_preempt east]} { accept }
    reject
}
